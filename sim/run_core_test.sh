#!/usr/bin/env bash
# Run the LDPC encoder core pyuvm test. Intended to be invoked inside the
# iic-osic-tools container via a LOGIN shell so verilator + system cocotb are
# on PATH:  docker exec iic-osic-tools bash -lc "bash <thisfile>"
set -e
cd "$(dirname "$0")"
echo "=== toolchain ==="
verilator --version
cocotb-config --version
echo "=== running test ==="
make test_ldpc_encoder_core
