#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export MACOSX_DEPLOYMENT_TARGET="13.0"

APP_NAME="VKMac"
BUNDLE_ID="com.vkmac.client"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "[1/5] Building vk-core (release)..."
cargo build -p vk-core --release

DYLIB_PATH="$ROOT_DIR/target/release/libvk_core.dylib"
if [[ ! -f "$DYLIB_PATH" ]]; then
    echo "Error: $DYLIB_PATH not found" >&2
    exit 1
fi

echo "[2/5] Generating UniFFI Swift bindings..."
mkdir -p "$ROOT_DIR/VKMac/Generated/CVkCore"
mkdir -p "$ROOT_DIR/VKMac/Sources/VKMac/Generated"

cargo run -p uniffi-bindgen -- generate \
    --library "$DYLIB_PATH" \
    --language swift \
    --out-dir "$ROOT_DIR/VKMac/Generated"

cp "$ROOT_DIR/VKMac/Generated/vk_coreFFI.h" "$ROOT_DIR/VKMac/Generated/CVkCore/vk_coreFFI.h"
cp "$ROOT_DIR/VKMac/Generated/vk_coreFFI.modulemap" "$ROOT_DIR/VKMac/Generated/CVkCore/module.modulemap"
cp "$ROOT_DIR/VKMac/Generated/vk_core.swift" "$ROOT_DIR/VKMac/Sources/VKMac/Generated/vk_core.swift"

echo "[3/5] Building VKMac executable (release via swiftc, static libvk_core.a)..."
SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"
BIN_DIR="$ROOT_DIR/build/bin"
BIN_PATH="$BIN_DIR/$APP_NAME"
STATIC_LIB="$ROOT_DIR/target/release/libvk_core.a"
mkdir -p "$BIN_DIR"

if [[ ! -f "$STATIC_LIB" ]]; then
    echo "Error: $STATIC_LIB not found" >&2
    exit 1
fi

SWIFT_FILES=()
while IFS= read -r -d '' file; do
    SWIFT_FILES+=("$file")
done < <(find "$ROOT_DIR/VKMac/Sources/VKMac" -name '*.swift' -print0 | sort -z)

swiftc -O \
    -parse-as-library \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -I "$ROOT_DIR/VKMac/Generated/CVkCore" \
    "$STATIC_LIB" \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework AVKit \
    -framework MediaPlayer \
    -framework WebKit \
    -framework Security \
    -framework LocalAuthentication \
    -framework UserNotifications \
    -framework LinkPresentation \
    -framework CoreAudio \
    -framework Carbon \
    -framework SystemConfiguration \
    -framework CoreFoundation \
    -liconv \
    -lresolv \
    "${SWIFT_FILES[@]}" \
    -o "$BIN_PATH"

echo "[4/5] Packaging $APP_NAME.app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
if [[ -f "$ROOT_DIR/VKMac/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/VKMac/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [[ -f "$ROOT_DIR/VKMac/Resources/MenuBarIcon.png" ]]; then
    cp "$ROOT_DIR/VKMac/Resources/MenuBarIcon.png" "$RESOURCES_DIR/MenuBarIcon.png"
fi
chmod +w "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Zaharia Klimkovich (xanax01d). MIT License.</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VKMac использует микрофон для записи голосовых сообщений</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.vkmac.client</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>vk</string>
            </array>
        </dict>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

SIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"VKMac Local Dev"'; then
    SIGN_IDENTITY="VKMac Local Dev"
fi
echo "[5/5] Signing $APP_NAME.app with identity: $SIGN_IDENTITY..."
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Done: $APP_DIR"
