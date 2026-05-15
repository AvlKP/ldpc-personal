import os

class LdpcEncoderGoldenModel:
    """Golden algorithmic model for the 5G NR LDPC Encoder."""
    def __init__(self):
        self.col_indices = []
        self.row_ptr = []
        self.values = []
        self.values_sets = {}
        self.hooks = {}
        self._row_to_ptr_index_bg1 = {}
        self._row_to_ptr_index_bg2 = {}

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
        row_schedule_path = os.path.join(mem_dir, 'row_schedule.mem')

        if not (os.path.exists(col_indices_path) and os.path.exists(row_ptr_path) and os.path.exists(values_path)):
            raise FileNotFoundError(f"Missing CSR memory files in {mem_dir}")

        self.col_indices = self._read_hex_file(col_indices_path)
        self.row_ptr = self._read_row_ptr_file(row_ptr_path)
        self.values = self._read_hex_file(values_path)

        for i in range(8):
            val_path = os.path.join(mem_dir, f'values_{i}.mem')
            if os.path.exists(val_path):
                self.values_sets[i] = self._read_hex_file(val_path)

        self._row_to_ptr_index_bg1 = {}
        self._row_to_ptr_index_bg2 = {}

        # Load optimized schedule from .mem file
        if os.path.exists(row_schedule_path):
            # UPDATE: Use the 4-per-word unpacker since schedule now mimics row_ptr format
            sched_data = self._read_row_ptr_file(row_schedule_path)
            
            # BG1 has 46 valid rows, padded to 48.
            bg1_sched = sched_data[:46]
            for idx, actual_row in enumerate(bg1_sched):
                self._row_to_ptr_index_bg1[actual_row] = idx
                
            # BG2 has 42 valid rows, padded to 44.
            # UPDATE: Because BG1 schedule is padded to 48, BG2's schedule list starts at index 48
            bg2_ptr_offset = 48
            bg2_sched = sched_data[bg2_ptr_offset : bg2_ptr_offset + 42]
            
            for idx, actual_row in enumerate(bg2_sched):
                # We map the actual row to the chronological fetch index in the padded row_ptr array
                self._row_to_ptr_index_bg2[actual_row] = idx + bg2_ptr_offset
        else:
            print(f"Warning: {row_schedule_path} not found. Falling back to identity mapping.")


    def _get_shift_value(self, z_idx, csr_idx, Z):
        val = self.values_sets[z_idx][csr_idx]
        return val % Z

    def _get_matrix_shift(self, bg_idx, z_idx, Z, target_row, target_col):
        """Dynamically retrieves the shift value for a specific row and column from the CSR matrix."""
        if bg_idx == 1 and self._row_to_ptr_index_bg1 and target_row in self._row_to_ptr_index_bg1:
            ptr_idx = self._row_to_ptr_index_bg1[target_row]
        elif bg_idx == 2 and self._row_to_ptr_index_bg2 and target_row in self._row_to_ptr_index_bg2:
            ptr_idx = self._row_to_ptr_index_bg2[target_row]
        else:
            ptr_idx = target_row

        start_idx = self.row_ptr[ptr_idx]
        end_idx = self.row_ptr[ptr_idx+1] if (ptr_idx+1) < len(self.row_ptr) else len(self.col_indices)

        for csr_idx in range(start_idx, end_idx):
            if self.col_indices[csr_idx] == target_col:
                return self._get_shift_value(z_idx, csr_idx, Z)
        return -1 # Represents an empty/null connection

    def _circ_shift(self, vec, shift):
        if shift == 0:
            return vec
        return vec[shift:] + vec[:shift]

    def _xor_vecs(self, v1, v2):
        return [a ^ b for a, b in zip(v1, v2)]

    def encode(self, input_bits, Z, bg_idx=1, version='3gpp'):
        """
        Encodes the input bits using the 5G NR LDPC algorithm.
        
        Args:
            input_bits: List of ints (0 or 1).
            Z: Lifting size.
            bg_idx: Base graph index (1 or 2).
            version: '3gpp' for strict TS 38.212 compliance, or 'petrovic' for textbook abstract shifts.
        """
        if not self.row_ptr:
            raise RuntimeError("CSR memory arrays are empty. Call load_csr_data().")

        self.hooks = {'shifted_vectors': [], 'lambdas': [], 'p_groups': []}
        kb = 22 if bg_idx == 1 else 10
        mb = 46 if bg_idx == 1 else 42
        
        # Determine Z index based on Z
        a = Z
        while a not in [2, 3, 5, 7, 9, 11, 13, 15]:
            a //= 2
        
        z_idx_map = {2: 0, 3: 1, 5: 2, 7: 3, 9: 4, 11: 5, 13: 6, 15: 7}
        z_idx = z_idx_map[a]
        
        i_groups = [input_bits[i*Z:(i+1)*Z] for i in range(kb)]
        p_groups = [[0]*Z for _ in range(mb)]
        lambdas = [[0]*Z for _ in range(4)]
        
        # 1. Calculate lambdas (first 4 rows)
        for r in range(4):
            if bg_idx == 1 and self._row_to_ptr_index_bg1 and r in self._row_to_ptr_index_bg1:
                ptr_idx = self._row_to_ptr_index_bg1[r]
            elif bg_idx == 2 and self._row_to_ptr_index_bg2 and r in self._row_to_ptr_index_bg2:
                ptr_idx = self._row_to_ptr_index_bg2[r]
            else:
                ptr_idx = r

            start_idx = self.row_ptr[ptr_idx]
            end_idx = self.row_ptr[ptr_idx+1] if (ptr_idx+1) < len(self.row_ptr) else len(self.col_indices)

            for csr_idx in range(start_idx, end_idx):
                col = self.col_indices[csr_idx]
                if col < kb:
                    shift = self._get_shift_value(z_idx, csr_idx, Z)
                    shifted_vec = self._circ_shift(i_groups[col], shift)
                    lambdas[r] = self._xor_vecs(lambdas[r], shifted_vec)
                    
        self.hooks['lambdas'] = [l.copy() for l in lambdas]
                    
        # 2. Core parity bit calculation
        sum_lambdas = lambdas[0]
        for i in range(1, 4):
            sum_lambdas = self._xor_vecs(sum_lambdas, lambdas[i])
            
        # Determine P_A and P_B shifts based on the requested version architecture
        if version == '3gpp':
            if bg_idx == 1:
                pa_shifts = [1, 1, 1, 1, 1, 1, 0, 1] 
                pb_shifts = [0, 0, 0, 0, 0, 0, 105, 0]
            else:
                pa_shifts = [0, 0, 0, 1, 0, 0, 0, 1]
                pb_shifts = [1, 1, 1, 0, 1, 1, 1, 0]
                
            pa_shift = pa_shifts[z_idx]
            pb_shift = pb_shifts[z_idx]
            
        elif version == 'petrovic':
            # Textbook/Abstract architecture shifts (assumes standard WiMAX-like core matrices)
            pa_shift = 0
            pb_shift = 1
        else:
            raise ValueError("version must be either '3gpp' or 'petrovic'")
            
        # P_B^-1 * sum_lambdas translates to shifting left by (Z - pb_shift) 
        p_c1 = self._circ_shift(sum_lambdas, (Z - pb_shift) % Z)
        p_groups[0] = p_c1
        
        # P_A * p_c1
        pa_pc1 = self._circ_shift(p_c1, pa_shift)
        
        # Resolve p_c2, p_c3, p_c4 using algebraic relations
        p_groups[1] = self._xor_vecs(lambdas[0], pa_pc1) # p_c2
        
        if bg_idx == 1:
            p_groups[3] = self._xor_vecs(lambdas[3], pa_pc1) # p_c4
            p_groups[2] = self._xor_vecs(lambdas[2], p_groups[3]) # p_c3
        else: # BG2
            p_groups[3] = self._xor_vecs(lambdas[3], pa_pc1) # p_c4
            p_groups[2] = self._xor_vecs(lambdas[1], p_groups[1]) # p_c3

        # 3. Calculate remaining parity bits (r >= 4)
        for r in range(4, mb):
            if bg_idx == 1 and self._row_to_ptr_index_bg1 and r in self._row_to_ptr_index_bg1:
                ptr_idx = self._row_to_ptr_index_bg1[r]
            elif bg_idx == 2 and self._row_to_ptr_index_bg2 and r in self._row_to_ptr_index_bg2:
                ptr_idx = self._row_to_ptr_index_bg2[r]
            else:
                ptr_idx = r

            start_idx = self.row_ptr[ptr_idx]
            end_idx = self.row_ptr[ptr_idx+1] if (ptr_idx+1) < len(self.row_ptr) else len(self.col_indices)

            p_r = [0]*Z
            for csr_idx in range(start_idx, end_idx):
                col = self.col_indices[csr_idx]
                shift = self._get_shift_value(z_idx, csr_idx, Z)

                if col < kb:
                    shifted_vec = self._circ_shift(i_groups[col], shift)
                    p_r = self._xor_vecs(p_r, shifted_vec)
                elif col < kb + 4:
                    # Note: These columns ARE present in the CSR for rows >= 4
                    c_idx = col - kb
                    shifted_vec = self._circ_shift(p_groups[c_idx], shift)
                    p_r = self._xor_vecs(p_r, shifted_vec)
            
            p_groups[r] = p_r
            
        self.hooks['p_groups'] = [g.copy() for g in p_groups]
        
        parity_bits = []
        for g in p_groups:
            parity_bits.extend(g)
            
        return parity_bits