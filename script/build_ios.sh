#!/bin/bash
set -euo pipefail

MODE="${1:-device}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! command -v xcodegen >/dev/null; then
    echo '缺少 xcodegen，请先安装 XcodeGen。' >&2
    exit 1
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1; then
    echo '找不到完整 Xcode，请设置 DEVELOPER_DIR 为 Xcode.app/Contents/Developer。' >&2
    exit 1
fi

case "$MODE" in
    device) SDK=iphoneos; CONFIGURATION=Release; DESTINATION='generic/platform=iOS' ;;
    simulator) SDK=iphonesimulator; CONFIGURATION=Debug; DESTINATION='generic/platform=iOS Simulator' ;;
    test)
        SDK=iphonesimulator
        CONFIGURATION=Debug
        if [[ -z "${SIMULATOR_ID:-}" ]]; then
            SIMULATOR_ID="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((x["udid"] for group in d["devices"].values() for x in group if x.get("isAvailable") and x["name"].startswith("iPhone")), ""))')"
        fi
        if [[ -z "$SIMULATOR_ID" ]]; then
            echo '没有可用的 iPhone 模拟器。请在 Xcode 安装 iOS Simulator runtime，或设置 SIMULATOR_ID。' >&2
            exit 1
        fi
        DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
        ;;
    *) echo 'usage: script/build_ios.sh [device|simulator|test]' >&2; exit 2 ;;
esac

"$ROOT_DIR/iOS/Native/build.sh" "$SDK"
xcodegen generate --spec "$ROOT_DIR/iOS/project.yml" --project "$ROOT_DIR/iOS"

DERIVED_DATA="$ROOT_DIR/build/ios-$SDK"
BUILD_ARGS=(
    -project "$ROOT_DIR/iOS/ChangeLocation.xcodeproj"
    -scheme ChangeLocationiOS
    -configuration "$CONFIGURATION"
    -sdk "$SDK"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO
    ARCHS=arm64
)
if [[ "$MODE" == test ]]; then
    xcodebuild "${BUILD_ARGS[@]}" test
    exit 0
fi
xcodebuild "${BUILD_ARGS[@]}" build

APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION-$SDK/ChangeLocation.app"
if [[ "$MODE" == simulator ]]; then
    echo "Simulator App: $APP_BUNDLE"
    exit 0
fi

PACKAGE_DIR="$(mktemp -d "$ROOT_DIR/build/ios-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_DIR"' EXIT
mkdir -p "$PACKAGE_DIR/Payload" "$ROOT_DIR/dist"
ditto "$APP_BUNDLE" "$PACKAGE_DIR/Payload/ChangeLocation.app"
IPA_PATH="$ROOT_DIR/dist/ChangeLocation-iPhone-unsigned.ipa"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR/Payload" "$PACKAGE_DIR/ChangeLocation.ipa"
mv "$PACKAGE_DIR/ChangeLocation.ipa" "$IPA_PATH"
echo "Unsigned IPA: $IPA_PATH"
shasum -a 256 "$IPA_PATH"
