SIM ?= verilator
TOPLEVEL_LANG ?= verilog

COCOTB_TOPLEVEL ?= input_buffer
TOPLEVEL ?= $(COCOTB_TOPLEVEL)

COCOTB_TEST_MODULES ?= input_buffer_tb
MODULE ?= $(COCOTB_TEST_MODULES)

SIM_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(SIM_DIR)/../rtl

VERILOG_SOURCES += $(RTL_DIR)/ldpc_pkg.sv
VERILOG_SOURCES += $(RTL_DIR)/asym_rgw_sdp_bram.sv
VERILOG_SOURCES += $(RTL_DIR)/input_buffer.sv

# Verilator options for SystemVerilog + cocotb timing behavior.
COMPILE_ARGS += --timing
COMPILE_ARGS += -Wall
COMPILE_ARGS += -Wno-fatal

EXTRA_ARGS += --trace --trace-fst --trace-structs

WAVES ?= 1

COCOTB_RESULTS_FILE ?= results.xml

.DEFAULT_GOAL := test_all

.PHONY: test_all test_progressive test_zc_edges test_reset_edges test_payload_edges test_bg1_info_sweep test_bg2_info_sweep test_bg_info_sweep_bp clean

test_all: sim

test_progressive:
	$(MAKE) sim COCOTB_TEST_FILTER=input_buffer_continuous_progressive_test

test_zc_edges:
	$(MAKE) sim COCOTB_TEST_FILTER=input_buffer_zc_boundary_edge_cases_test

test_reset_edges:
	$(MAKE) sim COCOTB_TEST_FILTER=input_buffer_midstream_reset_edge_cases_test

test_payload_edges:
	$(MAKE) sim COCOTB_TEST_FILTER=input_buffer_payload_size_edge_cases_test

test_bg1_info_sweep:
	$(MAKE) sim COCOTB_TEST_FILTER=input_buffer_bg1_full_info_group_sweep_test

test_bg2_info_sweep:
	$(MAKE) sim COCOTB_TEST_FILTER=input_buffer_bg2_full_info_group_sweep_test

test_bg_info_sweep_bp:
	$(MAKE) sim COCOTB_TEST_FILTER=input_buffer_bg_info_sweep_write_until_backpressure_test

test_b2b_write:
	$(MAKE) sim COCOTB_TEST_FILTER=input_buffer_back_to_back_without_done_test

clean::
	rm -rf sim_build __pycache__ .pytest_cache
	rm -f results.xml *.vcd *.fst

include $(shell cocotb-config --makefiles)/Makefile.sim