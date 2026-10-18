#!/usr/bin/env bash
# bench/wire.exs over a lossy link, in a network namespace of its own: the
# node and its clients share the namespace's lo, BENCH_NETEM (netem's
# arguments, default 25 ms each way and 1% loss) is put on that lo for the
# round trip and the carrier only, and the namespace is deleted on exit.
# Nothing outside it sees the delay. Needs sudo.
#
#   DATABASE_PATH=/tmp/hireme-bench.db PHX_SERVER=true PORT=4100 GATE_SOCKET=/tmp/g.sock \
#     BENCH_PROBE=native/target/release/examples/probe bench/netns.sh mix run bench/wire.exs
set -euo pipefail

ns=hireme-bench-$$
netem=${BENCH_NETEM:-delay 25ms loss 1%}

sudo ip netns add "$ns"
trap 'sudo ip netns del "$ns"' EXIT
sudo ip -n "$ns" link set lo up

sudo --preserve-env ip netns exec "$ns" \
  setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
  env PATH="$PATH" HOME="$HOME" BENCH_NETEM="$netem" "$@"
