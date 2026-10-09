#!/usr/bin/env bash
# Builds priv/static/wasm/kernel.wasm, the committed desk kernel.
#
#   native/kernel/build.sh          rebuild and replace the committed file
#   native/kernel/build.sh --check  rebuild into a scratch target and fail
#                                   unless it matches the committed bytes
#
# The build is reproducible with the pinned toolchain (rustc 1.96.1,
# wasm32-unknown-unknown): no dependencies outside the repo, paths remapped
# so the checkout's location never reaches the binary, LTO with one
# codegen unit, symbols stripped.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
native="$(cd "$here/.." && pwd)"
repo="$(cd "$native/.." && pwd)"
out="$repo/priv/static/wasm/kernel.wasm"
cargo="${CARGO:-$HOME/.cargo/bin/cargo}"
want="1.96.1"

have="$("${RUSTC:-$HOME/.cargo/bin/rustc}" --version | awk '{print $2}')"
if [[ "$have" != "$want" ]]; then
  echo "kernel.wasm is pinned to rustc $want; this is $have" >&2
  exit 1
fi

target="$here/target"
if [[ "${1:-}" == "--check" ]]; then
  target="$(mktemp -d)"
  trap 'rm -rf "$target"' EXIT
fi

sysroot="$("${RUSTC:-$HOME/.cargo/bin/rustc}" --print sysroot)"
# Later remaps win, so the most specific prefix goes last.
RUSTFLAGS="--remap-path-prefix=$HOME=/home --remap-path-prefix=$sysroot=/rust --remap-path-prefix=$native=/hireme/native -C target-cpu=mvp -C target-feature=+bulk-memory,+mutable-globals,+sign-ext,+nontrapping-fptoint" \
  CARGO_TARGET_DIR="$target" \
  "$cargo" build --quiet --release --locked --target wasm32-unknown-unknown \
  --manifest-path "$here/Cargo.toml"

built="$target/wasm32-unknown-unknown/release/kernel.wasm"
if [[ "${1:-}" == "--check" ]]; then
  if cmp -s "$built" "$out"; then
    echo "kernel.wasm reproduces ($(wc -c <"$out") bytes)"
  else
    echo "kernel.wasm does not match a fresh build; run native/kernel/build.sh" >&2
    exit 1
  fi
else
  install -m 0644 "$built" "$out"
  echo "wrote $out ($(wc -c <"$out") bytes)"
fi
