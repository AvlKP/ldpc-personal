# ==========================================
# Input Buffer Test Targets
# ==========================================

INPUT_BUFFER_SRCS := $(PKG_SRC) $(RTL_DIR)/lutram.sv $(RTL_DIR)/input_buffer.sv

.PHONY: test_input_buffer test_basic_transfer test_lifting_size_duplication test_ping_pong_backpressure test_randomized_zc_5gnr test_config_change_during_transaction test_buggy_ldpc_clear test_bg1_bg2_sweep test_ping_pong_stall_and_resume

test_input_buffer:
	$(call run_test,input_buffer,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),)

test_basic_transfer:
	$(call run_test,input_buffer_basic_transfer,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),test_basic_transfer)

test_lifting_size_duplication:
	$(call run_test,input_buffer_lifting_size,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),test_lifting_size_duplication)

test_ping_pong_backpressure:
	$(call run_test,input_buffer_ping_pong,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),test_ping_pong_backpressure)

test_randomized_zc_5gnr:
	$(call run_test,input_buffer_random_zc,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),test_randomized_zc_5gnr)

test_config_change_during_transaction:
	$(call run_test,input_buffer_config_change,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),test_config_change_during_transaction)

test_buggy_ldpc_clear:
	$(call run_test,input_buffer_buggy_clear,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),test_buggy_ldpc_clear)

test_bg1_bg2_sweep:
	$(call run_test,input_buffer_bg1_bg2_sweep,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),test_bg1_bg2_sweep)

test_ping_pong_stall_and_resume:
	$(call run_test,input_buffer_stall_resume,input_buffer,input_buffer_tb,$(INPUT_BUFFER_SRCS),test_ping_pong_stall_and_resume)
