import pytest
from golden_model import LdpcEncoderGoldenModel

def test_initialization():
    """Test that the golden model can be initialized."""
    model = LdpcEncoderGoldenModel()
    assert model is not None
