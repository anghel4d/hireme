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
#   E2E_NODE     where playwright@1.64.1 is installed (it must be the caller's
#                own directory); else a fresh mktemp dir, removed on exit
#   OUT          screenshots and the node's log; else a fresh /tmp dir
#   SHA          the revision to print, for a checkout without .git
# Needs mix, cargo, node 24 and npm on PATH (BRIEF.md, 'Toolchain').
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHROMIUM=${CHROMIUM:-/nix/store/ini1ifgvcsvw48x4mxawrv9jvbdwn70p-chromium-155.0.8059.79/bin/chromium}
E2E_OWN=
if [ -z "${E2E_NODE:-}" ]; then E2E_NODE=$(mktemp -d /tmp/hireme-e2e-node.XXXXXX); E2E_OWN=1; fi
OUT=${OUT:-$(mktemp -d /tmp/hireme-e2e.XXXXXX)}
TMP=$(mktemp -d /tmp/hireme-e2e-db.XXXXXX)
NODE_PID=

cleanup() {
  if [ -n "$NODE_PID" ]; then kill -TERM -- "-$NODE_PID" 2>/dev/null || true; wait "$NODE_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
  if [ -n "$E2E_OWN" ]; then rm -rf "$E2E_NODE"; fi
}
trap cleanup EXIT

echo "out=$OUT sha=${SHA:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)}"

if [ -z "${HIREME_MCP:-}" ]; then
  cargo build --quiet --release --manifest-path "$ROOT/native/Cargo.toml" -p hireme-mcp
  HIREME_MCP="$ROOT/native/target/release/hireme-mcp"
fi
[ -x "$HIREME_MCP" ] || { echo "FAIL setup: no hireme-mcp at $HIREME_MCP"; echo "res=1"; exit 1; }
[ -x "$CHROMIUM" ] || { echo "FAIL setup: no Chromium at $CHROMIUM"; echo "res=1"; exit 1; }

# Code runs from E2E_NODE: it must be ours, and no one else may write it.
[ -e "$E2E_NODE" ] || mkdir -m 700 -p "$E2E_NODE"
if [ ! -O "$E2E_NODE" ] || [ -n "$(find "$E2E_NODE" -maxdepth 0 -perm /022)" ]; then
  echo "FAIL setup: $E2E_NODE is not the caller's own directory, or others may write it"; echo "res=1"; exit 1
fi
if [ ! -d "$E2E_NODE/node_modules/playwright" ]; then
  mkdir -p "$E2E_NODE"
  (cd "$E2E_NODE" && npm init -y >/dev/null && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --silent playwright@1.64.1)
fi

PORT=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')

cd "$ROOT"
MIX_ENV=dev mix assets.build >"$OUT/build.log" 2>&1 || { echo "FAIL setup: mix assets.build (see $OUT/build.log)"; echo "res=1"; exit 1; }

# Its own process group, so teardown takes esbuild's watchers too.
DATABASE_PATH="$TMP/e2e.db" PORT=$PORT PHX_SERVER=true HIREME_GATE=off MIX_ENV=dev \
  setsid mix phx.server >"$OUT/node.log" 2>&1 &
NODE_PID=$!

BASE="http://localhost:$PORT"
for _ in $(seq 1 120); do
  curl -sf -o /dev/null "$BASE/sign-in" && break
  kill -0 "$NODE_PID" 2>/dev/null || { echo "FAIL setup: the node exited (see $OUT/node.log)"; echo "res=1"; exit 1; }
  sleep 0.5
done
curl -sf -o /dev/null "$BASE/sign-in" || { echo "FAIL setup: the node did not answer on $BASE (see $OUT/node.log)"; echo "res=1"; exit 1; }

# A module resolves "playwright" from its own directory: run a copy beside it.
cp "$ROOT/test/e2e/acceptance4.mjs" "$E2E_NODE/acceptance4.mjs"
set +e
BASE=$BASE HIREME_MCP=$HIREME_MCP CHROMIUM=$CHROMIUM OUT=$OUT node "$E2E_NODE/acceptance4.mjs"
res=$?
exit $res
