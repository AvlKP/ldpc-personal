#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$SCRIPT_DIR/sim"
VENV_DIR="$SCRIPT_DIR/venv"
TARGET="${1:?Usage: $0 <make-target>  e.g. group_ldpc_core}"

# 1. Resolve Bender dependencies and regenerate verilator.f
echo "==> bender update"
cd "$SCRIPT_DIR"
bender update

echo "==> Generating verilator.f"
bender script verilator -t synthesis -t verilator > verilator.f

# 2. Create venv if needed and install Python dependencies
echo "==> Setting up Python venv"
[ -d "$VENV_DIR" ] || python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet py3gpp pyuvm

# 3. Expose venv packages to the system Python embedded in the simulation binary
#    (the binary is hardwired to /usr/bin/python3, not the venv interpreter)
export PYTHONPATH
PYTHONPATH=$("$VENV_DIR/bin/python3" -c "import site; print(site.getsitepackages()[0])")

# 4. Run simulation
echo "==> make $TARGET"
cd "$SIM_DIR"
make "$TARGET"

# 5. Select wave state based on target
FST="$SIM_DIR/dump.fst"
if [ ! -f "$FST" ]; then
    echo "Warning: no waveform found at $FST"
    exit 0
fi

case "$TARGET" in
    *ldpc_core*|*ldpc_encoder*)
        STATE="$SIM_DIR/wave_state/core.surf.ron" ;;
    *csr*)
        STATE="$SIM_DIR/wave_state/csr_decoder_new.surf.ron" ;;
    *input_buffer*|*progressive*|*zc_edges*|*reset_edges*|*payload_edges*|*bg1_info*)
        STATE="$SIM_DIR/wave_state/input_buffer.surf.ron" ;;
    *)
        STATE="" ;;
esac

# 6. Open waveform (force X11 — container has no Wayland compositor)
echo "==> Opening surfer"
if [ -n "${STATE:-}" ]; then
    WAYLAND_DISPLAY= surfer "$FST" --state "$STATE"
else
    WAYLAND_DISPLAY= surfer "$FST"
fi
