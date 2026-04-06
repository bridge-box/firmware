#!/bin/sh
# Кросс-компиляция Rust бинарей для aarch64 (QEMU dev sandbox)
#
# Результат: test/qemu-dev/binaries/ с bb-agent, nfqdns, flowsense
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET="aarch64-unknown-linux-musl"
OUT_DIR="$SCRIPT_DIR/binaries"

mkdir -p "$OUT_DIR"

# Cross-compilation env — ring crate needs CC, linker needs to be aarch64
export CC_aarch64_unknown_linux_musl=aarch64-linux-gnu-gcc
export AR_aarch64_unknown_linux_musl=aarch64-linux-gnu-ar
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-gnu-gcc
export RUSTFLAGS="-C target-feature=+crt-static"

echo "=== Cross-compiling for $TARGET ==="

echo "Building bb-agent..."
cargo build --manifest-path "$REPO_ROOT/agent/Cargo.toml" \
    --target "$TARGET" --release --quiet
cp "$REPO_ROOT/agent/target/$TARGET/release/bb-agent" "$OUT_DIR/"

echo "Building nfqdns..."
cargo build --manifest-path "$REPO_ROOT/nfqdns/Cargo.toml" \
    --target "$TARGET" --release --quiet
cp "$REPO_ROOT/nfqdns/target/$TARGET/release/nfqdns" "$OUT_DIR/"

echo "Building flowsense..."
cargo build --manifest-path "$REPO_ROOT/flowsense/Cargo.toml" \
    --target "$TARGET" --release --quiet
cp "$REPO_ROOT/flowsense/target/$TARGET/release/flowsense" "$OUT_DIR/"

echo ""
ls -lh "$OUT_DIR/"
echo ""
echo "Done. Binaries in $OUT_DIR/"
