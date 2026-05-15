import pytest
import os
import numpy as np
from golden_model import LdpcEncoderGoldenModel

def test_core_encode():
    model = LdpcEncoderGoldenModel()
    mem_dir = os.path.join(os.path.dirname(__file__), '..', 'rtl', 'mem')
    model.load_csr_data(mem_dir)
    
    # We need to add the encode method to LdpcEncoderGoldenModel first
    # So this test will initially fail.
    
    # Let's say Z=4, BG=1
    Z = 4
    bg_idx = 1
    
    # Generate some dummy data
    kb = 22 if bg_idx == 1 else 10
    input_data = np.random.randint(0, 2, kb * Z).tolist()
    
    encoded_data = model.encode(input_data, Z, bg_idx)
    
    assert encoded_data is not None
