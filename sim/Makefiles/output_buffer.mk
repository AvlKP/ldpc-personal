# ==========================================
# Output Buffer Test Targets
# ==========================================

OUTPUT_BUFFER_SRCS := $(PKG_SRC) $(RTL_DIR)/output_buffer.sv

.PHONY: test_output_buffer

test_output_buffer:
	$(call run_test,output_buffer,output_buffer,output_buffer_tb,$(OUTPUT_BUFFER_SRCS),)
