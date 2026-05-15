import pytest
import os
from golden_model import LdpcEncoderGoldenModel

def test_initialization():
    """Test that the golden model can be initialized."""
    model = LdpcEncoderGoldenModel()
    assert model is not None

def test_csr_parsing():
    """Test parsing of CSR mem files."""
    model = LdpcEncoderGoldenModel()
    mem_dir = os.path.join(os.path.dirname(__file__), '..', 'rtl', 'mem')
    model.load_csr_data(mem_dir)
    
    assert hasattr(model, 'col_indices')
    assert hasattr(model, 'row_ptr')
    assert hasattr(model, 'values')
    assert hasattr(model, 'values_sets')
    
    assert len(model.col_indices) == 415
    assert len(model.values) == 415
    # 24 lines * 4 pointers/line = 96 row pointers
    assert len(model.row_ptr) == 96
    
    # First line of row_ptr.mem is 190842200 -> unpacked: 0, 17, 33, 50
    assert model.row_ptr[0] == 0
    assert model.row_ptr[1] == 17
    assert model.row_ptr[2] == 33
    assert model.row_ptr[3] == 50

    # Ensure we loaded the values_x.mem files
    assert len(model.values_sets) == 8
    for i in range(8):
        assert len(model.values_sets[i]) == 415
