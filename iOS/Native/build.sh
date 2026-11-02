#!/bin/bash
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET=27.0
build_sdk="${1:-all}"
case "$build_sdk" in
  iphoneos) build_targets="aarch64-apple-ios" ;;
  iphonesimulator) build_targets="aarch64-apple-ios-sim" ;;
  all) build_targets="aarch64-apple-ios aarch64-apple-ios-sim" ;;
  *) echo 'Usage: build.sh [iphoneos|iphonesimulator|all]' >&2; exit 2 ;;
esac
for build_target in $build_targets; do
  rustup target add "$build_target"
  if [ "$build_target" = aarch64-apple-ios ]; then build_platform=iphoneos; else build_platform=iphonesimulator; fi
  export SDKROOT="$(xcrun --sdk "$build_platform" --show-sdk-path)"
  cargo build --locked --release --manifest-path "$native_dir/Cargo.toml" --target "$build_target"
  mkdir -p "$native_dir/lib/$build_platform"
  cp "$native_dir/target/$build_target/release/libchangelocation.a" "$native_dir/lib/$build_platform/libchangelocation.a"
done
