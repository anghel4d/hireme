#!/usr/bin/env bash
# Cutover acceptance 4's browser half, end to end: boots a throwaway dev node
# from this checkout (temp database, free port, WebSocket carrier), runs
# acceptance4.mjs in the pinned nix Chromium through Playwright, and tears
# everything down on any exit. Prints PASS/FAIL per step and res=0|1; exits
# with it. Not part of `mix test`.
#
#   test/e2e/run.sh
#
# Environment (all optional):
#   HIREME_MCP   a built hireme-mcp; else `cargo build --release -p hireme-mcp`
#   CHROMIUM     the browser; else the BRIEF's pinned nix Chromium 155
#   OUT          screenshots and the node's log; else a fresh /tmp dir
#   SHA          the revision to print, for a checkout without .git
# Needs mix, cargo, bun, curl and setsid on PATH (BRIEF.md, 'Toolchain').
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHROMIUM=${CHROMIUM:-/nix/store/ini1ifgvcsvw48x4mxawrv9jvbdwn70p-chromium-155.0.8059.79/bin/chromium}
# Playwright is installed fresh each run into a directory only this run
# made (bun's own cache makes it quick), with a package.json of its own and
# no workspace or ancestor lookup: code is never run from a path someone
# else could have prepared.
E2E_NODE= OUT=${OUT:-} TMP= NODE_PID= ACC_PID= BG_PID=

cleanup() {
  if [ -n "$BG_PID" ]; then kill -TERM -- "-$BG_PID" 2>/dev/null || true; wait "$BG_PID" 2>/dev/null || true; fi
  if [ -n "$ACC_PID" ]; then kill -TERM -- "-$ACC_PID" 2>/dev/null || true; wait "$ACC_PID" 2>/dev/null || true; fi
  if [ -n "$NODE_PID" ]; then kill -TERM -- "-$NODE_PID" 2>/dev/null || true; wait "$NODE_PID" 2>/dev/null || true; fi
  [ -z "$TMP" ] || rm -rf "$TMP"
  [ -z "$E2E_NODE" ] || rm -rf "$E2E_NODE"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

for tool in mix cargo bun curl setsid; do
  command -v "$tool" >/dev/null || { echo "FAIL setup: $tool is not on PATH (BRIEF.md, 'Toolchain')"; echo "res=1"; exit 1; }
done
E2E_NODE=$(mktemp -d /tmp/hireme-e2e-node.XXXXXX)
TMP=$(mktemp -d /tmp/hireme-e2e-db.XXXXXX)
OUT=${OUT:-$(mktemp -d /tmp/hireme-e2e.XXXXXX)}
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd)

echo "out=$OUT sha=${SHA:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)}"

# Long steps run in their own session in the background and are waited for,
# so a signal to this script is acted on at once and teardown takes the step
# (and its children) down too.
bg() {
  setsid "$@" &
  BG_PID=$!
  local rc=0
  wait "$BG_PID" || rc=$?
  BG_PID=
  return $rc
}

if [ -z "${HIREME_MCP:-}" ]; then
  bg cargo build --quiet --release --manifest-path "$ROOT/native/Cargo.toml" -p hireme-mcp
  HIREME_MCP="${CARGO_TARGET_DIR:-$ROOT/native/target}/release/hireme-mcp"
fi
[ -x "$HIREME_MCP" ] || { echo "FAIL setup: no hireme-mcp at $HIREME_MCP"; echo "res=1"; exit 1; }
[ -x "$CHROMIUM" ] || { echo "FAIL setup: no Chromium at $CHROMIUM"; echo "res=1"; exit 1; }

printf '{"private":true}\n' >"$E2E_NODE/package.json"
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 bg bun add --cwd "$E2E_NODE" --ignore-scripts --silent playwright@1.64.1
[ -f "$E2E_NODE/node_modules/playwright/index.mjs" ] || { echo "FAIL setup: playwright did not install into $E2E_NODE"; echo "res=1"; exit 1; }

cd "$ROOT"
MIX_ENV=dev bg mix assets.build >"$OUT/build.log" 2>&1 || { echo "FAIL setup: mix assets.build (see $OUT/build.log)"; echo "res=1"; exit 1; }

# The port is picked just before the node binds it, and the node is ours
# only if it is alive and its log names that port.
PORT=$(bun -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
# Its own process group, so teardown takes Bun's watchers too.
DATABASE_PATH="$TMP/e2e.db" PORT=$PORT PHX_SERVER=true HIREME_GATE=off MIX_ENV=dev \
  setsid mix phx.server >"$OUT/node.log" 2>&1 &
NODE_PID=$!

BASE="http://localhost:$PORT"
ready=
for _ in $(seq 1 120); do
  kill -0 "$NODE_PID" 2>/dev/null || { echo "FAIL setup: the node exited (see $OUT/node.log)"; echo "res=1"; exit 1; }
  if grep -q ":$PORT" "$OUT/node.log" && curl -sf -o /dev/null "$BASE/sign-in"; then ready=1; break; fi
  sleep 0.5
done
[ -n "$ready" ] && kill -0 "$NODE_PID" 2>/dev/null || { echo "FAIL setup: the node did not answer on $BASE (see $OUT/node.log)"; echo "res=1"; exit 1; }

# A module resolves "playwright" from its own directory: run a copy beside
# it, in its own session, so a signal to this script takes Chromium and
# hireme-mcp down with it.
cp "$ROOT/test/e2e/acceptance4.mjs" "$E2E_NODE/acceptance4.mjs"
set +e
BASE=$BASE HIREME_MCP=$HIREME_MCP CHROMIUM=$CHROMIUM OUT=$OUT setsid bun "$E2E_NODE/acceptance4.mjs" &
ACC_PID=$!
wait "$ACC_PID"
res=$?
ACC_PID=
exit $res
