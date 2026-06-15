# ==========================================
# LDPC Encoder Top-Level pyuvm Test Targets
# ==========================================

LDPC_TOP_SRCS := \
	$(PKG_SRC) \
	$(RTL_DIR)/barrel_shifter.sv \
	$(RTL_DIR)/codeword_generator.sv \
	$(RTL_DIR)/core_parity_bit_calculator.sv \
	$(RTL_DIR)/csr_decoder.sv \
	$(RTL_DIR)/direct_bit_permutation.sv \
	$(RTL_DIR)/gf2_sum.sv \
	$(RTL_DIR)/group_reordering.sv \
	$(RTL_DIR)/input_buffer.sv \
	$(RTL_DIR)/ldpc_encoder.v \
	$(RTL_DIR)/ldpc_encoder_core.sv \
	$(RTL_DIR)/lutram.sv \
	$(RTL_DIR)/lutrom.sv \
	$(RTL_DIR)/merge_sel_lambda.sv \
	$(RTL_DIR)/output_buffer.sv \
	$(RTL_DIR)/parameter_calculation.sv \
	$(RTL_DIR)/pc_rearrange.sv \
	$(RTL_DIR)/rom_dp.sv \
	$(RTL_DIR)/top_level_shifter.sv \
	$(RTL_DIR)/zc_decoder.sv

.PHONY: test_ldpc_encoder_core

test_ldpc_encoder_core:
	$(call run_test,ldpc_encoder_pyuvm,ldpc_encoder,pyuvm_tb.test,$(LDPC_TOP_SRCS),)
