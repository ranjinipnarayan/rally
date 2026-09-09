#!/bin/bash
set -euo pipefail

# Build the app for the simulator first. This uses that build's pinned Auth SDK.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products="${1:-/tmp/rally-extension-build}/Build/Products/Debug-iphonesimulator"
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
test_arch="$(uname -m)"
test_binary="/tmp/rally-auth-checks"

objects=()
for target in Auth Helpers Crypto ConcurrencyExtras HTTPTypes Clocks IssueReporting XCTestDynamicOverlay; do
  objects+=("$products/$target.o")
done

xcrun swiftc -sdk "$simulator_sdk" -target "$test_arch-apple-ios17.0-simulator" \
  -module-cache-path /tmp/rally-auth-module-cache -I "$products" \
  "$repo_dir/Shared/RallyLocation.swift" \
  "$repo_dir/MessagesExtension/RallyIntegration.swift" \
  "$repo_dir/RallyMessagesApp/RallyAccountAPI.swift" \
  "$repo_dir/RallyMessagesApp/RallyAuthConfiguration.swift" \
  "$repo_dir/RallyMessagesApp/RallyAccountModel.swift" \
  "$repo_dir/Tests/RallyAuthChecks.swift" \
  "${objects[@]}" -o "$test_binary"

xcrun simctl spawn "${RALLY_TEST_SIMULATOR:-booted}" "$test_binary"
