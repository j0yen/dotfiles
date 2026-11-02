#!/bin/bash
# wmb-slot-r7.sh <cargo args...>: ryzen7 shim giving wmb-verify-suite.sh the redbaron cargo-slot.sh calling form
# (cargo-slot.sh test …) on top of r7-cargo-slot.sh's gate (r7-cargo-slot.sh --wait-s S -- cargo …). Env (RUSTFLAGS,
# CARGO_TARGET_DIR) passes through. WMB_SLOT_WAIT_S = wait for a slot, default 9000.
exec "$HOME/.local/bin/r7-cargo-slot.sh" --wait-s "${WMB_SLOT_WAIT_S:-9000}" -- cargo "$@"
