#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$project_dir/build/ios-model-tests"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  "$project_dir/iOS/App/LocationContracts.swift" \
  "$project_dir/iOS/App/RecoveryJournal.swift" \
  "$project_dir/iOS/App/PhoneLocationModel.swift" \
  "$project_dir/Sources/ChangeLocation/Models/Coordinates.swift" \
  "$project_dir/Tests/iOS/ModelChecks.swift" \
  -o "$project_dir/build/ios-model-tests/model-checks"
"$project_dir/build/ios-model-tests/model-checks"
