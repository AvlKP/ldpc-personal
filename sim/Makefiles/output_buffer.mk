# ==========================================
# Output Buffer Test Targets
# ==========================================
# Integration test: codeword_generator + output_buffer glued by the
# outbuff_integration harness (same wiring as ldpc_encoder_core/ldpc_encoder).

OUTPUT_BUFFER_SRCS := $(PKG_SRC) \
	$(RTL_DIR)/codeword_generator.sv \
	$(RTL_DIR)/output_buffer.sv \
	$(SIM_DIR)/sv_tb/outbuff_integration.sv

.PHONY: test_output_buffer

# EXTRA_ARGS overridden to skip verilator.f (bender paths not needed here).
test_output_buffer:
	@echo "=========================================="
	@echo "Running Test: output_buffer (integration)"
	@echo "=========================================="
	@mkdir -p sim_build/output_buffer
	EXTRA_ARGS="--trace --trace-fst --trace-structs" \
	$(MAKE) -f $(SIM_DIR)/Makefile sim \
		TOPLEVEL=outbuff_integration \
		MODULE=output_buffer_tb \
		VERILOG_SOURCES="$(OUTPUT_BUFFER_SRCS)" \
		SIM_BUILD=sim_build/output_buffer \
		COCOTB_RESULTS_FILE=sim_build/output_buffer/results.xml
