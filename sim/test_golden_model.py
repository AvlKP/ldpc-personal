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
    # Assuming rtl/mem is relative to the project root, and tests run from sim/
    mem_dir = os.path.join(os.path.dirname(__file__), '..', 'rtl', 'mem')
    model.load_csr_data(mem_dir)
    
    assert hasattr(model, 'col_indices')
    assert hasattr(model, 'row_ptr')
    assert hasattr(model, 'values')
    
    assert len(model.col_indices) > 0
    assert len(model.row_ptr) > 0
    assert len(model.values) > 0
