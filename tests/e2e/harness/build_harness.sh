#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ROOT="$(cd "$E2E_DIR/../.." && pwd)"
BIN_DIR="$HARNESS_DIR/bin"

IF_AVAILABLE=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --if-available)
      IF_AVAILABLE=1
      ;;
    --require-vk-core)
      IF_AVAILABLE=0
      ;;
    --force|-f)
      FORCE=1
      ;;
    --help|-h)
      echo "Usage: build_harness.sh [--if-available | --require-vk-core] [--force]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$BIN_DIR"
TMP_OUT=""
trap 'if [[ -n "${TMP_OUT:-}" ]]; then rm -f "$TMP_OUT"; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

is_up_to_date() {
  local bin="$1"
  shift
  if [[ "$FORCE" -eq 1 ]] || [[ ! -x "$bin" ]]; then
    return 1
  fi
  local dep
  for dep in "$@"; do
    if [[ ! -e "$dep" ]] || [[ ! "$bin" -nt "$dep" ]]; then
      return 1
    fi
  done
  return 0
}

SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"

if is_up_to_date "$BIN_DIR/hls_probe" "$HARNESS_DIR/hls_probe.swift" "$HARNESS_DIR/build_harness.sh"; then
  echo "[build_harness] hls_probe is up to date ($BIN_DIR/hls_probe)"
else
  echo "[build_harness] Building hls_probe ($TARGET)..."
  TMP_OUT="$BIN_DIR/.hls_probe.tmp.$$"
  swiftc -O \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -framework Foundation \
    -framework AVFoundation \
    -framework MediaPlayer \
    -framework CoreMedia \
    -framework CoreGraphics \
    "$HARNESS_DIR/hls_probe.swift" \
    -o "$TMP_OUT"
  mv -f "$TMP_OUT" "$BIN_DIR/hls_probe"
  TMP_OUT=""
  echo "[build_harness] Built $BIN_DIR/hls_probe"
fi

CVKCORE_DIR="$ROOT/VKMac/Generated/CVkCore"
VK_CORE_SWIFT=""
for candidate in \
  "$ROOT/VKMac/Sources/VKMac/Generated/vk_core.swift" \
  "$ROOT/VKMac/Generated/VkCore/vk_core.swift" \
  "$ROOT/VKMac/Generated/vk_core.swift"; do
  if [[ -f "$candidate" ]]; then
    VK_CORE_SWIFT="$candidate"
    break
  fi
done

DYLIB_PATH=""
for candidate in \
  "$ROOT/build/VKMac.app/Contents/Frameworks/libvk_core.dylib" \
  "$ROOT/target/release/libvk_core.dylib"; do
  if [[ -f "$candidate" ]]; then
    DYLIB_PATH="$candidate"
    break
  fi
done

MISSING=()
if [[ ! -f "$CVKCORE_DIR/vk_coreFFI.h" ]]; then
  MISSING+=("$CVKCORE_DIR/vk_coreFFI.h")
fi
if [[ ! -f "$CVKCORE_DIR/module.modulemap" ]]; then
  MISSING+=("$CVKCORE_DIR/module.modulemap")
fi
if [[ -z "$VK_CORE_SWIFT" ]]; then
  MISSING+=("$ROOT/VKMac/Sources/VKMac/Generated/vk_core.swift")
fi
if [[ -z "$DYLIB_PATH" ]]; then
  MISSING+=("$ROOT/build/VKMac.app/Contents/Frameworks/libvk_core.dylib (or target/release/libvk_core.dylib)")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  if [[ "$IF_AVAILABLE" -eq 1 ]]; then
    echo "[build_harness] Pre-M3: vk-core UniFFI artifacts not yet present (${MISSING[*]})."
    echo "[build_harness] Running syntax check on main.swift (swiftc -parse -parse-as-library)..."
    swiftc -parse -parse-as-library \
      -sdk "$SDK_PATH" \
      -target "$TARGET" \
      "$HARNESS_DIR/main.swift"
    echo "[build_harness] Pre-M3: main.swift syntax check passed; skipped vk_e2e_harness link."
    exit 0
  else
    echo "[build_harness] ERROR: Missing required UniFFI/vk-core artifacts:" >&2
    for m in "${MISSING[@]}"; do
      echo "  - $m" >&2
    done
    echo "Run ./scripts/build_app.sh first to generate bindings and build libvk_core.dylib." >&2
    exit 2
  fi
fi

DYLIB_DIR="$(cd "$(dirname "$DYLIB_PATH")" && pwd)"
if is_up_to_date \
  "$BIN_DIR/vk_e2e_harness" \
  "$HARNESS_DIR/main.swift" \
  "$VK_CORE_SWIFT" \
  "$CVKCORE_DIR/vk_coreFFI.h" \
  "$CVKCORE_DIR/module.modulemap" \
  "$DYLIB_PATH" \
  "$HARNESS_DIR/build_harness.sh"; then
  echo "[build_harness] vk_e2e_harness is up to date ($BIN_DIR/vk_e2e_harness)"
else
  echo "[build_harness] Building vk_e2e_harness against $DYLIB_PATH..."
  TMP_OUT="$BIN_DIR/.vk_e2e_harness.tmp.$$"
  swiftc -O -parse-as-library \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -I "$CVKCORE_DIR" \
    -L "$DYLIB_DIR" \
    -lvk_core \
    -Xlinker -rpath -Xlinker "$DYLIB_DIR" \
    -Xlinker -rpath -Xlinker "$ROOT/build/VKMac.app/Contents/Frameworks" \
    -Xlinker -rpath -Xlinker "$ROOT/target/release" \
    "$VK_CORE_SWIFT" \
    "$HARNESS_DIR/main.swift" \
    -o "$TMP_OUT"
  mv -f "$TMP_OUT" "$BIN_DIR/vk_e2e_harness"
  TMP_OUT=""
  echo "[build_harness] Built $BIN_DIR/vk_e2e_harness"
fi
