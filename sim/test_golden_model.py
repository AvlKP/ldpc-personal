import pytest
import numpy as np
import os
import sys

# Import your Golden Model
from golden_model import LdpcEncoderGoldenModel
# Import py3gpp
from py3gpp.nrLDPCEncode import nrLDPCEncode
from py3gpp.nrLDPCEncode import _load_basegraph, _encode_thangaraj

# --- Test Configurations ---
# Testing a subset of Z values across different sets
Z_VALUES_BG1 = [8, 14, 26, 384] 
Z_VALUES_BG2 = [10, 16, 24, 256]

# --- Helper Functions ---
def generate_test_vectors(Z, kb):
    """Generates random, all-zeros, and all-ones test vectors."""
    K = kb * Z
    vectors = {
        "random": np.random.randint(0, 2, K, dtype=np.int8),
        "all_zeros": np.zeros(K, dtype=np.int8),
        "all_ones": np.ones(K, dtype=np.int8),
        "alternating": np.array([i % 2 for i in range(K)], dtype=np.int8)
    }
    return vectors

def format_py3gpp_to_parity(py3gpp_out, Z, bg_idx):
    """
    Extracts purely the parity bits from the py3gpp output.
    py3gpp punctures the first 2*Zc systematic bits.
    """
    py3gpp_flat = py3gpp_out[:, 0].tolist()
    
    # Calculate how many systematic bits remain in the py3gpp output
    kb = 22 if bg_idx == 1 else 10
    remaining_sys_bits = (kb - 2) * Z
    
    # Slice out only the parity bits (discarding the remaining systematic bits)
    parity_only = py3gpp_flat[remaining_sys_bits:]
    return parity_only

def get_i_ls(Z):
    """Maps lifting size Z to the 3GPP lifting set index (i_ls)."""
    a = Z
    while a not in [2, 3, 5, 7, 9, 11, 13, 15]:
        a //= 2
    z_idx_map = {2: 0, 3: 1, 5: 2, 7: 3, 9: 4, 11: 5, 13: 6, 15: 7}
    return z_idx_map[a]

def generate_test_vectors(Z, kb):
    K = kb * Z
    vectors = {
        "random": np.random.randint(0, 2, K, dtype=np.int8),
        "all_zeros": np.zeros(K, dtype=np.int8),
        "all_ones": np.ones(K, dtype=np.int8),
        "alternating": np.array([i % 2 for i in range(K)], dtype=np.int8)
    }
    return vectors

# --- Pytest Fixtures ---
@pytest.fixture(scope="module")
def encoder_model():
    model = LdpcEncoderGoldenModel()
    file_dir = os.path.dirname(__file__) 
    mem_dir = os.path.join(file_dir, "mem") 
    try:
        model.load_csr_data(mem_dir)
    except FileNotFoundError as e:
        pytest.fail(f"Could not load memory files: {e}")
    return model

# --- Test Cases ---

@pytest.mark.parametrize("Z", Z_VALUES_BG1)
def test_bg1_encoding(encoder_model, Z):
    bg_idx = 1
    kb = 22
    vectors = generate_test_vectors(Z, kb)
    i_ls = get_i_ls(Z)
    
    # Load basegraph explicitly mapped to the required i_ls
    bm = _load_basegraph(i_ls, bgn=bg_idx)
    
    for pattern_name, input_bits in vectors.items():
        # 1. Run py3gpp Math Reference
        cw_full = _encode_thangaraj(bm, Z, input_bits)
        ref_parity = cw_full[kb * Z :].astype(int).tolist() # Slice pure parity
        
        # 2. Run Golden Model
        dut_parity = encoder_model.encode(input_bits.tolist(), Z, bg_idx=bg_idx)
        
        # 3. Assert
        assert len(dut_parity) == len(ref_parity), f"Length mismatch Z={Z}"
        assert dut_parity == ref_parity, f"BG1 Z={Z} [{pattern_name}]: Data mismatch."

@pytest.mark.parametrize("Z", Z_VALUES_BG2)
def test_bg2_encoding(encoder_model, Z):
    bg_idx = 2
    kb = 10
    vectors = generate_test_vectors(Z, kb)
    i_ls = get_i_ls(Z)
    
    bm = _load_basegraph(i_ls, bgn=bg_idx)
    
    for pattern_name, input_bits in vectors.items():
        # 1. Run py3gpp Math Reference
        cw_full = _encode_thangaraj(bm, Z, input_bits)
        ref_parity = cw_full[kb * Z :].astype(int).tolist()
        
        # 2. Run Golden Model
        dut_parity = encoder_model.encode(input_bits.tolist(), Z, bg_idx=bg_idx)
        
        # 3. Assert
        assert len(dut_parity) == len(ref_parity), f"Length mismatch Z={Z}"
        assert dut_parity == ref_parity, f"BG2 Z={Z} [{pattern_name}]: Data mismatch."

# @pytest.mark.parametrize("Z", Z_VALUES_BG1)
# def test_bg1_encoding(encoder_model, Z):
#     """Test Base Graph 1 with various Z sizes and data patterns."""
#     bg_idx = 1
#     kb = 22
#     vectors = generate_test_vectors(Z, kb)
    
#     for pattern_name, input_bits in vectors.items():
#         # 1. Run py3gpp Reference
#         # py3gpp expects a 2D array of shape (K, C) where C is number of code blocks
#         cbs_in = input_bits.reshape(-1, 1).copy() 
#         py3gpp_out = nrLDPCEncode(cbs_in, bgn=bg_idx, algo='thangaraj')
#         ref_parity = format_py3gpp_to_parity(py3gpp_out, Z, bg_idx)
        
#         # 2. Run Golden Model
#         input_list = input_bits.tolist()
#         dut_parity = encoder_model.encode(input_list, Z, bg_idx=bg_idx)
        
#         # 3. Assert Dimensions and Equivalence
#         assert len(dut_parity) == len(ref_parity), \
#             f"BG1 Z={Z} [{pattern_name}]: Length mismatch. Expected {len(ref_parity)}, Got {len(dut_parity)}"
        
#         assert dut_parity == ref_parity, \
#             f"BG1 Z={Z} [{pattern_name}]: Data mismatch between Golden Model and py3gpp"

# @pytest.mark.parametrize("Z", Z_VALUES_BG2)
# def test_bg2_encoding(encoder_model, Z):
#     """Test Base Graph 2 with various Z sizes and data patterns."""
#     bg_idx = 2
#     kb = 10
#     vectors = generate_test_vectors(Z, kb)
    
#     for pattern_name, input_bits in vectors.items():
#         cbs_in = input_bits.reshape(-1, 1).copy()
        
#         # py3gpp Reference
#         py3gpp_out = nrLDPCEncode(cbs_in, bgn=bg_idx, algo='thangaraj')
#         ref_parity = format_py3gpp_to_parity(py3gpp_out, Z, bg_idx)
        
#         # Golden Model
#         input_list = input_bits.tolist()
#         dut_parity = encoder_model.encode(input_list, Z, bg_idx=bg_idx)
        
#         # Assert
#         assert len(dut_parity) == len(ref_parity), \
#             f"BG2 Z={Z} [{pattern_name}]: Length mismatch. Expected {len(ref_parity)}, Got {len(dut_parity)}"
        
#         assert dut_parity == ref_parity, \
#             f"BG2 Z={Z} [{pattern_name}]: Data mismatch between Golden Model and py3gpp"