# ==========================================
# Codeword Generator Test Targets
# ==========================================

CODEWORD_GENERATOR_SRCS := $(PKG_SRC) $(RTL_DIR)/codeword_generator.sv

.PHONY: test_codeword_generator

test_codeword_generator:
	$(call run_test,codeword_generator,codeword_generator,codeword_generator_tb,$(CODEWORD_GENERATOR_SRCS),)
