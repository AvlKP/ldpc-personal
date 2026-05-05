# ==========================================
# Input Buffer Test Targets
# ==========================================

INPUT_BUFFER_SRCS := $(PKG_SRC) $(RTL_DIR)/asym_rgw_sdp_bram.sv $(RTL_DIR)/input_buffer.sv

.PHONY: test_input_buffer test_progressive test_zc_edges test_reset_edges test_payload_edges test_bg1_info_sweep

test_input_buffer:
	$(call run_test,input_buffer,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),)

test_progressive:
	$(call run_test,input_buffer_progressive,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),input_buffer_continuous_progressive_test)

test_zc_edges:
	$(call run_test,input_buffer_zc_edges,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),input_buffer_zc_boundary_edge_cases_test)

test_reset_edges:
	$(call run_test,input_buffer_reset_edges,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),input_buffer_midstream_reset_edge_cases_test)

test_payload_edges:
	$(call run_test,input_buffer_payload_edges,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),input_buffer_payload_size_edge_cases_test)

test_bg1_info_sweep:
	$(call run_test,input_buffer_bg1_info,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),input_buffer_bg1_full_info_group_sweep)
