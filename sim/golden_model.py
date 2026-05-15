import os

class LdpcEncoderGoldenModel:
    """Golden algorithmic model for the 5G NR LDPC Encoder."""
    def __init__(self):
        self.col_indices = []
        self.row_ptr = []
        self.values = []
        self.values_sets = {}

    def _read_hex_file(self, filepath):
        """Reads a hex memory file and returns a list of integers."""
        data = []
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('//'):
                    data.append(int(line, 16))
        return data

    def _read_row_ptr_file(self, filepath):
        """Reads the row_ptr memory file which contains four 9-bit values packed into 36 bits per line."""
        data = []
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('//'):
                    val = int(line, 16)
                    # Unpack 4x 9-bit values (LSB to MSB)
                    v0 = val & 0x1FF
                    v1 = (val >> 9) & 0x1FF
                    v2 = (val >> 18) & 0x1FF
                    v3 = (val >> 27) & 0x1FF
                    data.extend([v0, v1, v2, v3])
        return data

    def load_csr_data(self, mem_dir):
        """Loads CSR data from .mem files in the given directory."""
        col_indices_path = os.path.join(mem_dir, 'col_indices.mem')
        row_ptr_path = os.path.join(mem_dir, 'row_ptr.mem')
        values_path = os.path.join(mem_dir, 'values.mem')

        if not (os.path.exists(col_indices_path) and os.path.exists(row_ptr_path) and os.path.exists(values_path)):
            raise FileNotFoundError(f"Missing CSR memory files in {mem_dir}")

        self.col_indices = self._read_hex_file(col_indices_path)
        self.row_ptr = self._read_row_ptr_file(row_ptr_path)
        self.values = self._read_hex_file(values_path)

        for i in range(8):
            val_path = os.path.join(mem_dir, f'values_{i}.mem')
            if os.path.exists(val_path):
                self.values_sets[i] = self._read_hex_file(val_path)

    def _get_shift_value(self, z_idx, csr_idx, Z):
        """Gets the shift value for a given Z index and CSR element."""
        val = self.values_sets[z_idx][csr_idx]
        return val % Z

    def _circ_shift(self, vec, shift):
        """Circularly shifts a vector to the right by `shift` places."""
        if shift == 0:
            return vec
        return vec[-shift:] + vec[:-shift]

    def _xor_vecs(self, v1, v2):
        """Element-wise XOR of two vectors."""
        return [a ^ b for a, b in zip(v1, v2)]

    def encode(self, input_bits, Z, bg_idx=1):
        """
        Encodes the input bits using the 5G NR LDPC algorithm.
        input_bits: list of ints (0 or 1)
        Z: lifting size
        bg_idx: Base graph index (1 or 2).
        Returns: The encoded parity bits as a list of ints.
        """
        kb = 22 if bg_idx == 1 else 10
        mb = 46 if bg_idx == 1 else 42
        
        # Determine Z index based on Z
        a = Z
        while a not in [2, 3, 5, 7, 9, 11, 13, 15]:
            a //= 2
        
        z_idx_map = {2: 0, 3: 1, 5: 2, 7: 3, 9: 4, 11: 5, 13: 6, 15: 7}
        z_idx = z_idx_map[a]
        
        # Group input into kb groups of size Z
        i_groups = [input_bits[i*Z:(i+1)*Z] for i in range(kb)]
        
        # Array to store parity groups (mb groups of size Z)
        p_groups = [[0]*Z for _ in range(mb)]
        
        # Calculate lambda_1 to lambda_4 (first 4 rows)
        lambdas = [[0]*Z for _ in range(4)]
        
        for r in range(4):
            start_idx = self.row_ptr[r]
            end_idx = self.row_ptr[r+1] if (r+1) < len(self.row_ptr) else len(self.col_indices)
            
            for csr_idx in range(start_idx, end_idx):
                col = self.col_indices[csr_idx]
                if col < kb: # Only consider information bits for lambdas
                    shift = self._get_shift_value(z_idx, csr_idx, Z)
                    shifted_vec = self._circ_shift(i_groups[col], shift)
                    lambdas[r] = self._xor_vecs(lambdas[r], shifted_vec)
                    
        # Core parity bit calculation
        # p_c1 = sum(lambda_1 ... lambda_4) (shifted left by 1 since it's shifted right by 1 in PCM)
        p_c1_shifted = lambdas[0]
        for i in range(1, 4):
            p_c1_shifted = self._xor_vecs(p_c1_shifted, lambdas[i])
            
        p_c1 = self._circ_shift(p_c1_shifted, Z - 1) # Shift back (left by 1 = right by Z-1)
        p_groups[0] = p_c1
        
        # p_c2, p_c3, p_c4
        p_groups[1] = self._xor_vecs(lambdas[0], p_c1)
        
        if bg_idx == 1:
            p_groups[3] = self._xor_vecs(lambdas[3], p_c1)
            p_groups[2] = self._xor_vecs(lambdas[2], p_groups[3])
        else: # BG2
            p_groups[2] = self._xor_vecs(lambdas[1], p_groups[1])
            p_groups[3] = self._xor_vecs(lambdas[3], p_c1)

        # Calculate remaining parity bits (additional parity bits)
        # For row r >= 4: p_r = sum(shifted information bits) + sum(shifted core parity bits)
        for r in range(4, mb):
            start_idx = self.row_ptr[r]
            end_idx = self.row_ptr[r+1] if (r+1) < len(self.row_ptr) else len(self.col_indices)
            
            p_r = [0]*Z
            for csr_idx in range(start_idx, end_idx):
                col = self.col_indices[csr_idx]
                shift = self._get_shift_value(z_idx, csr_idx, Z)
                
                if col < kb:
                    # Information bit
                    shifted_vec = self._circ_shift(i_groups[col], shift)
                    p_r = self._xor_vecs(p_r, shifted_vec)
                elif col < kb + 4:
                    # Core parity bit
                    c_idx = col - kb
                    shifted_vec = self._circ_shift(p_groups[c_idx], shift)
                    p_r = self._xor_vecs(p_r, shifted_vec)
                # Note: Parity bit from identity matrix part is the parity bit itself, we are solving for it.
            
            p_groups[r] = p_r
            
        # Flatten parity groups
        parity_bits = []
        for g in p_groups:
            parity_bits.extend(g)
            
        return parity_bits
