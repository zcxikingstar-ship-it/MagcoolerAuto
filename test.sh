#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h}"
build_dir="$root_dir/.test-build"
mkdir -p "$build_dir"
xcrun swiftc -parse-as-library -swift-version 5 \
  "$root_dir/Sources/AutoPolicy.swift" \
  "$root_dir/Tests/PolicyTests.swift" \
  -o "$build_dir/PolicyTests"
"$build_dir/PolicyTests"
