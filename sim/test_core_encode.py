import pytest
import os
import numpy as np
from golden_model import LdpcEncoderGoldenModel

def test_core_encode():
    model = LdpcEncoderGoldenModel()
    mem_dir = os.path.join(os.path.dirname(__file__), '..', 'rtl', 'mem')
    model.load_csr_data(mem_dir)
    
    # Let's say Z=4, BG=1
    Z = 4
    bg_idx = 1
    
    # Generate some dummy data
    kb = 22 if bg_idx == 1 else 10
    input_data = np.random.randint(0, 2, kb * Z).tolist()
    
    encoded_data = model.encode(input_data, Z, bg_idx)
    
    assert encoded_data is not None
    assert len(encoded_data) == (46 if bg_idx == 1 else 42) * Z

def test_hooks():
    """Test that intermediate data hooks are populated during encoding."""
    model = LdpcEncoderGoldenModel()
    mem_dir = os.path.join(os.path.dirname(__file__), '..', 'rtl', 'mem')
    model.load_csr_data(mem_dir)
    
    Z = 4
    bg_idx = 1
    kb = 22
    input_data = [1] * (kb * Z)
    
    model.encode(input_data, Z, bg_idx)
    
    assert 'shifted_vectors' in model.hooks
    assert 'lambdas' in model.hooks
    assert 'p_groups' in model.hooks
    
    assert len(model.hooks['shifted_vectors']) > 0
    assert len(model.hooks['lambdas']) == 4
    assert len(model.hooks['p_groups']) == 46
