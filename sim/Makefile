# ==========================================
# Unified Master Makefile for Cocotb Testbenches
# ==========================================

# Default simulator and arguments
export SIM ?= verilator
export TOPLEVEL_LANG ?= verilog
export COMPILE_ARGS ?= --timing -Wall -Wno-fatal
export EXTRA_ARGS ?= --trace --trace-fst --trace-structs -f $(SIM_DIR)/../verilator.f
export WAVES ?= 1

# Base directories
export SIM_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
export RTL_DIR := $(SIM_DIR)/../rtl
export GOLDEN_DATA_DIR := $(SIM_DIR)/../script/data

# Default Goal
.DEFAULT_GOAL := all
.PHONY: all clean

# Common sources
PKG_SRC := $(RTL_DIR)/ldpc_pkg.sv

# ==========================================
# Testbench Engine
# ==========================================

# --- Target Template ---
# $(1): target name (used as SIM_BUILD dir suffix)
# $(2): TOPLEVEL (Verilog module)
# $(3): MODULE (Python module)
# $(4): Verilog Sources
# $(5): Optional COCOTB_TEST_FILTER
define run_test
	@echo "=========================================="
	@echo "Running Test: $(1)"
	@echo "=========================================="
	@mkdir -p sim_build/$(1)/mem
	@cp -f $(RTL_DIR)/mem/*.mem sim_build/$(1)/mem/ 2>/dev/null || true
	@cp -f $(RTL_DIR)/mem/*.mem sim_build/$(1)/ 2>/dev/null || true
	$(MAKE) -f $(SIM_DIR)/Makefile sim \
		TOPLEVEL=$(2) \
		MODULE=$(3) \
		VERILOG_SOURCES="$(4)" \
		SIM_BUILD=sim_build/$(1) \
		COCOTB_RESULTS_FILE=sim_build/$(1)/results.xml \
		$(if $(5),COCOTB_TEST_FILTER="$(5)")
endef

# ==========================================
# Include child target definitions
# ==========================================
-include $(SIM_DIR)/Makefiles/*.mk

# --- Group Targets ---
.PHONY: group_input_buffer group_csr_decoder
group_input_buffer: test_input_buffer test_progressive test_zc_edges test_reset_edges test_payload_edges test_bg1_info_sweep
group_csr_decoder: test_csr_decoder test_csr_bg1 test_csr_bg2 test_csr_arbitrary test_csr_backpressure
all: test_input_buffer test_csr_decoder

# ==========================================
# Cleanup
# ==========================================
clean::
	@echo "Cleaning simulation artifacts..."
	@rm -rf sim_build
	@rm -f results*.xml dump*.fst

# ==========================================
# Cocotb Inclusion
# ==========================================
# Only include the cocotb makefiles if we are actually running a simulation (MODULE is set)
ifdef MODULE
include $(shell cocotb-config --makefiles)/Makefile.sim
endif
