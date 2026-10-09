#!/usr/bin/env bash
# The gate on an emulated path, without root: a user and network namespace
# whose loopback carries a netem delay (half the RTT each way, both
# directions in one queue), an optional rate and queue limit, the echoing
# Session (bench/gate_echo.exs), and the gate built from this tree; then
# bench/gate.mjs measures through it.
#
#   native/gate/netem.sh RTT_MS [RATE|none] [bench/gate.mjs flags...]
#   native/gate/netem.sh 47 none --n 5 --boot 1048576 --origin http://localhost:4000
#
# Before the first run: `cargo build --release --manifest-path native/gate/Cargo.toml
# --bin hireme-gate --example probe` and `MIX_ENV=test mix compile`.
#
# Environment: GATE_INITIAL_WINDOW passes through to the gate, GATE_BIN
# picks another gate build (the release's, to include the half-RTT patch),
# LIMIT is netem's queue in packets, MIX the mix to run the BEAM with.
# NODE_PATH (holding playwright-core) and CHROME as for bench/browser.mjs
# when --origin asks for Chromium. Needs unshare(1) with unprivileged user
# namespaces, tc and the netem qdisc.
set -euo pipefail
[ "${IN_NS:-}" = 1 ] || exec unshare -rn env IN_NS=1 bash "$0" "$@"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
rtt=$1 rate=${2:-none}
shift 2 || shift $#

ip link set lo up
half=$(awk "BEGIN{print $rtt/2}")
shape=(delay "${half}ms" limit "${LIMIT:-100000}")
[ "$rate" = none ] || shape+=(rate "$rate")
tc qdisc add dev lo root netem "${shape[@]}"

run=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/gate-netem.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$run"' EXIT
(cd "$root" && GATE_SOCKET=$run/s MIX_ENV=test ${MIX:-mix} run --no-start bench/gate_echo.exs) > "$run/beam.log" 2>&1 &
for _ in $(seq 240); do [ -S "$run/s" ] && break; sleep 0.25; done
[ -S "$run/s" ] || { cat "$run/beam.log" >&2; exit 1; }
GATE_SOCKET=$run/s GATE_CERT_HASH_FILE=$run/hash GATE_LISTEN=127.0.0.1:4433 GATE_ORIGINS=http://localhost:4000 \
  "${GATE_BIN:-$here/target/release/hireme-gate}" > "$run/gate.log" 2>&1 &
for _ in $(seq 50); do [ -s "$run/hash" ] && break; sleep 0.1; done
node "$root/bench/gate.mjs" --url https://127.0.0.1:4433/wt --hash-file "$run/hash" "$@"
