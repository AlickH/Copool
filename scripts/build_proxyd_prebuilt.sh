#!/bin/sh
set -eu

ROOT="${SRCROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
MANIFEST="$ROOT/Sources/Copool/Resources/proxyd-src/proxyd/Cargo.toml"
PREBUILT_DIR="$ROOT/Sources/Copool/Resources/proxyd-prebuilt"
ARCHIVE_DIR="$ROOT/Sources/Copool/Resources/proxyd-prebuilt-archives"
TARGET_DIR="${CODEX_TOOLS_PROXY_TARGET_DIR:-$HOME/Library/Caches/Copool/proxyd-target}"
PATH="$HOME/.cargo/bin:$PATH"
CARGO_BIN=""
RUSTC_BIN=""
RUSTUP_BIN=""
ZIG_BIN=""
CROSS_BIN=""
CARGO_ZIGBUILD_BIN=""
TOOLCHAIN_BIN=""

resolve_first() {
  for candidate in "$@"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if [ ! -f "$MANIFEST" ]; then
  echo "warning: proxyd manifest not found at $MANIFEST"
  exit 0
fi

RUSTUP_BIN="$(resolve_first \
  "${HOMEBREW_PREFIX:-}/bin/rustup" \
  "/opt/homebrew/bin/rustup" \
  "/usr/local/bin/rustup" \
  "$(command -v rustup 2>/dev/null || true)")" || true
ZIG_BIN="$(resolve_first \
  "${HOMEBREW_PREFIX:-}/bin/zig" \
  "/opt/homebrew/bin/zig" \
  "/usr/local/bin/zig" \
  "$(command -v zig 2>/dev/null || true)")" || true
CROSS_BIN="$(resolve_first \
  "$HOME/.cargo/bin/cross" \
  "$(command -v cross 2>/dev/null || true)")" || true
CARGO_ZIGBUILD_BIN="$(resolve_first \
  "$HOME/.cargo/bin/cargo-zigbuild" \
  "$(command -v cargo-zigbuild 2>/dev/null || true)")" || true

if [ -x "$HOME/.cargo/bin/cargo" ]; then
  CARGO_BIN="$HOME/.cargo/bin/cargo"
elif command -v cargo >/dev/null 2>&1; then
  CARGO_BIN="$(command -v cargo)"
elif [ -n "$RUSTUP_BIN" ] && "$RUSTUP_BIN" run stable cargo --version >/dev/null 2>&1; then
  CARGO_BIN="$RUSTUP_BIN run stable cargo"
else
  echo "warning: cargo not found, skipping proxyd prebuilt rebuild"
  exit 0
fi

if [ -x "$HOME/.cargo/bin/rustc" ]; then
  RUSTC_BIN="$HOME/.cargo/bin/rustc"
elif command -v rustc >/dev/null 2>&1; then
  RUSTC_BIN="$(command -v rustc)"
elif [ -n "$RUSTUP_BIN" ] && "$RUSTUP_BIN" which rustc >/dev/null 2>&1; then
  RUSTC_BIN="$("$RUSTUP_BIN" which rustc)"
fi

if [ -n "$RUSTC_BIN" ]; then
  TOOLCHAIN_BIN="$(dirname "$RUSTC_BIN")"
  PATH="$TOOLCHAIN_BIN:$PATH"
  export PATH
fi

mkdir -p "$PREBUILT_DIR" "$ARCHIVE_DIR" "$TARGET_DIR"

SOURCE_STAMP="$(mktemp)"
find "$ROOT/Sources/Copool/Resources/proxyd-src" -type f \
  \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) \
  -print0 | xargs -0 stat -f '%m %N' | sort > "$SOURCE_STAMP"

build_target() {
  target="$1"
  output_dir="$PREBUILT_DIR/$target"
  output_bin="$output_dir/codex-tools-proxyd"
  archive_dir="$ARCHIVE_DIR/$target"
  archive_bin="$archive_dir/codex-tools-proxyd.zlib"
  stamp_file="$output_dir/.build-stamp"
  build_failed=0

  mkdir -p "$output_dir" "$archive_dir"

  if [ -f "$output_bin" ] && [ -f "$archive_bin" ] && [ -f "$stamp_file" ] && cmp -s "$SOURCE_STAMP" "$stamp_file"; then
    echo "proxyd prebuilt up to date for $target"
    return 0
  fi

  if [ -n "$CROSS_BIN" ]; then
    echo "building proxyd with cross for $target"
    if ! "$CROSS_BIN" build --manifest-path "$MANIFEST" --release --target "$target" --target-dir "$TARGET_DIR"; then
      build_failed=1
    fi
  elif [ -n "$ZIG_BIN" ] && $CARGO_BIN zigbuild --help >/dev/null 2>&1; then
    echo "building proxyd with cargo zigbuild for $target"
    if ! $CARGO_BIN zigbuild --manifest-path "$MANIFEST" --release --target "$target" --target-dir "$TARGET_DIR"; then
      build_failed=1
    fi
  elif [ -n "$CARGO_ZIGBUILD_BIN" ]; then
    echo "building proxyd with cargo-zigbuild for $target"
    if ! "$CARGO_ZIGBUILD_BIN" --manifest-path "$MANIFEST" --release --target "$target" --target-dir "$TARGET_DIR"; then
      build_failed=1
    fi
  else
    echo "warning: no cross-compilation tool available for $target, keeping existing prebuilt"
    return 0
  fi

  if [ "$build_failed" -ne 0 ]; then
    if [ -f "$output_bin" ]; then
      echo "warning: proxyd rebuild failed for $target, keeping existing prebuilt"
      return 0
    fi

    echo "error: proxyd rebuild failed for $target and no existing prebuilt is available"
    exit 1
  fi

  built_bin="$TARGET_DIR/$target/release/codex-tools-proxyd"
  if [ ! -x "$built_bin" ]; then
    echo "error: built proxyd binary missing for $target at $built_bin"
    exit 1
  fi

  cp "$built_bin" "$output_bin"
  chmod 644 "$output_bin"
  python3 - "$output_bin" "$archive_bin" <<'PY'
import pathlib
import sys
import zlib

source = pathlib.Path(sys.argv[1]).read_bytes()
pathlib.Path(sys.argv[2]).write_bytes(zlib.compress(source, level=9))
PY
  cp "$SOURCE_STAMP" "$stamp_file"
}

build_target "x86_64-unknown-linux-musl"
build_target "aarch64-unknown-linux-musl"

rm -f "$SOURCE_STAMP"
