# ==========================================
# CSR Decoder Test Targets
# ==========================================

CSR_DECODER_SRCS := $(PKG_SRC) $(RTL_DIR)/csr_col_ctl.sv $(RTL_DIR)/rom_dp.sv $(RTL_DIR)/rom_lutram.sv $(RTL_DIR)/csr_decoder.sv

.PHONY: test_csr_decoder test_continuous_decoding test_csr_bg1 test_csr_bg2 test_csr_arbitrary test_csr_backpressure

test_csr_decoder:
	$(call run_test,csr_decoder,csr_decoder,csr_decoder_tb,$(CSR_DECODER_SRCS),)

test_continuous_decoding:
	$(call run_test,csr_decoder_continuous_decoding,csr_decoder,csr_decoder_tb,$(CSR_DECODER_SRCS),test_continuous_decoding)

test_csr_bg1:
	$(call run_test,csr_decoder_bg1,csr_decoder,csr_decoder_tb,$(CSR_DECODER_SRCS),test_bg1_full_sweep)

test_csr_bg2:
	$(call run_test,csr_decoder_bg2,csr_decoder,csr_decoder_tb,$(CSR_DECODER_SRCS),test_bg2_full_sweep)

test_csr_arbitrary:
	$(call run_test,csr_decoder_arbitrary,csr_decoder,csr_decoder_tb,$(CSR_DECODER_SRCS),test_arbitrary_input_changes)

test_csr_backpressure:
	$(call run_test,csr_decoder_backpressure,csr_decoder,csr_decoder_tb,$(CSR_DECODER_SRCS),test_backpressure_and_delays)

test_csr_row_increment:
	$(call run_test,csr_decoder_row_increment,csr_decoder,csr_decoder_tb,$(CSR_DECODER_SRCS),test_variable_row_increments)