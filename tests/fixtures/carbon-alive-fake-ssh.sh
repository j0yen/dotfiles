#!/usr/bin/env bash
# fake ssh for tests/carbon-alive.test.sh: scenario from env, args ignored.
# CA_FAKE_RC (default 0; 255 = unreachable), CA_FAKE_UM, CA_FAKE_GW, CA_FAKE_BUS, CA_FAKE_DASH (age s or na),
# CA_FAKE_EXEC (heartbeat age s or na), CA_FAKE_UM_INV / CA_FAKE_UM_NR / CA_FAKE_UM_MONO (user@1000 InvocationID,
# NRestarts, ActiveEnterTimestampMonotonic), CA_FAKE_BOOT (boot_id); the last four default to stable values.
rc="${CA_FAKE_RC:-0}"
[ "$rc" != 0 ] && exit "$rc"
echo host_up=1
echo "user_manager=${CA_FAKE_UM:-active}"
echo "gateway=${CA_FAKE_GW:-active}"
echo "bus=${CA_FAKE_BUS:-up}"
echo "dash_age_s=${CA_FAKE_DASH:-20}"
echo "executor_age_s=${CA_FAKE_EXEC:-na}"
echo "um_inv=${CA_FAKE_UM_INV:-0123456789abcdef0123456789abcdef}"
echo "um_nrestarts=${CA_FAKE_UM_NR:-0}"
echo "um_enter_mono=${CA_FAKE_UM_MONO:-420858804099}"
echo "boot_id=${CA_FAKE_BOOT:-11111111-2222-3333-4444-555555555555}"
