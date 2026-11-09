#!/usr/bin/env bash
# fake ssh for tests/carbon-alive.test.sh: scenario from env, args ignored.
# CA_FAKE_RC (default 0; 255 = unreachable), CA_FAKE_UM, CA_FAKE_GW, CA_FAKE_BUS, CA_FAKE_DASH (age s or na)
rc="${CA_FAKE_RC:-0}"
[ "$rc" != 0 ] && exit "$rc"
echo host_up=1
echo "user_manager=${CA_FAKE_UM:-active}"
echo "gateway=${CA_FAKE_GW:-active}"
echo "bus=${CA_FAKE_BUS:-up}"
echo "dash_age_s=${CA_FAKE_DASH:-20}"
echo "executor_age_s=${CA_FAKE_EXEC:-na}"
