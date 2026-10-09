#!/usr/bin/env bash
# Builds priv/static/wasm/kernel.wasm, the committed desk kernel.
#
#   native/kernel/build.sh          rebuild and replace the committed file
#   native/kernel/build.sh --check  rebuild from scratch and fail unless it
#                                   matches the committed bytes
#
# The build is reproducible with the pinned toolchain (rustc 1.96.1,
# wasm32-unknown-unknown) from any checkout: the sources (native/wire,
# native/kernel and the wire schema they read) are copied to one fixed
# directory and built there, because Cargo hashes a path package's absolute
# location into its symbols and so into the function layout, which
# --remap-path-prefix (strings only) cannot undo. No dependencies outside
# the repo, LTO with one codegen unit, symbols stripped.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
native="$(cd "$here/.." && pwd)"
repo="$(cd "$native/.." && pwd)"
out="$repo/priv/static/wasm/kernel.wasm"
cargo="${CARGO:-$HOME/.cargo/bin/cargo}"
rustc="${RUSTC:-$HOME/.cargo/bin/rustc}"
want="1.96.1"

have="$("$rustc" --version | awk '{print $2}')"
if [[ "$have" != "$want" ]]; then
  echo "kernel.wasm is pinned to rustc $want; this is $have" >&2
  exit 1
fi

# The one place every build happens. A literal path, not one from the
# environment, so two machines or two checkouts agree on it.
base=/tmp/hireme-kernel-build
mkdir -p "$base"
exec 9>"$base/lock"
flock 9

rm -rf "$base/src"
mkdir -p "$base/src/native/wire" "$base/src/native/kernel" "$base/src/priv/wire"
for crate in wire kernel; do
  cp -r "$native/$crate/src" "$native/$crate/Cargo.toml" "$native/$crate/Cargo.lock" "$base/src/native/$crate/"
  if [[ -f "$native/$crate/build.rs" ]]; then cp "$native/$crate/build.rs" "$base/src/native/$crate/"; fi
done
cp "$repo/priv/wire/schema.txt" "$base/src/priv/wire/"

target="$base/target"
if [[ "${1:-}" == "--check" ]]; then
  target="$base/check-target"
  rm -rf "$target"
fi

sysroot="$("$rustc" --print sysroot)"
# Later remaps win, so the most specific prefix goes last.
RUSTFLAGS="--remap-path-prefix=$HOME=/home --remap-path-prefix=$sysroot=/rust --remap-path-prefix=$base/src/native=/hireme/native -C target-cpu=mvp -C target-feature=+bulk-memory,+mutable-globals,+sign-ext,+nontrapping-fptoint" \
  CARGO_TARGET_DIR="$target" \
  "$cargo" build --quiet --release --locked --target wasm32-unknown-unknown \
  --manifest-path "$base/src/native/kernel/Cargo.toml"

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
