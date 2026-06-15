# ==========================================
# Codeword Generator Test Targets
# ==========================================

CODEWORD_GENERATOR_SRCS := $(PKG_SRC) $(RTL_DIR)/codeword_generator.sv

.PHONY: test_codeword_generator

# Override EXTRA_ARGS to skip stale verilator.f (bender paths from other project).
# codeword_generator is self-contained; only needs ldpc_pkg + codeword_generator.
test_codeword_generator:
	@echo "=========================================="
	@echo "Running Test: codeword_generator"
	@echo "=========================================="
	@mkdir -p sim_build/codeword_generator/mem
	@mkdir -p $(SIM_DIR)/mem
	@cp -f $(RTL_DIR)/mem/*.mem sim_build/codeword_generator/mem/ 2>/dev/null || true
	@cp -f $(RTL_DIR)/mem/*.mem sim_build/codeword_generator/ 2>/dev/null || true
	@cp -f $(RTL_DIR)/mem/*.mem $(SIM_DIR)/mem/ 2>/dev/null || true
	EXTRA_ARGS="--trace --trace-fst --trace-structs" \
	$(MAKE) -f $(SIM_DIR)/Makefile sim \
		TOPLEVEL=codeword_generator \
		MODULE=codeword_generator_tb \
		VERILOG_SOURCES="$(CODEWORD_GENERATOR_SRCS)" \
		SIM_BUILD=sim_build/codeword_generator \
		COCOTB_RESULTS_FILE=sim_build/codeword_generator/results.xml
