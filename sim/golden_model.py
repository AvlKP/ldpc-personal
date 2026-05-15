import os

class LdpcEncoderGoldenModel:
    """Golden algorithmic model for the 5G NR LDPC Encoder."""
    def __init__(self):
        self.col_indices = []
        self.row_ptr = []
        self.values = []

    def _read_hex_file(self, filepath):
        """Reads a hex memory file and returns a list of integers."""
        data = []
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('//'):
                    data.append(int(line, 16))
        return data

    def load_csr_data(self, mem_dir):
        """Loads CSR data from .mem files in the given directory."""
        col_indices_path = os.path.join(mem_dir, 'col_indices.mem')
        row_ptr_path = os.path.join(mem_dir, 'row_ptr.mem')
        values_path = os.path.join(mem_dir, 'values.mem')

        if not (os.path.exists(col_indices_path) and os.path.exists(row_ptr_path) and os.path.exists(values_path)):
            raise FileNotFoundError(f"Missing CSR memory files in {mem_dir}")

        self.col_indices = self._read_hex_file(col_indices_path)
        self.row_ptr = self._read_hex_file(row_ptr_path)
        self.values = self._read_hex_file(values_path)
