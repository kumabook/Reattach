#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
TEST_DIR=$(mktemp -d /tmp/reattach-mac-tests.XXXXXX)
xcrun swiftc -parse-as-library -module-cache-path "$TEST_DIR/cache" \
    ios/Reattach/Models/PermissionStatus.swift ios/Reattach/Models/Session.swift \
    macos/ReattachMac/PanelLayout.swift macos/ReattachMac/Connection.swift macos/ReattachMac/InboxStore.swift \
    macos/ReattachMac/InboxView.swift macos/ReattachMac/WorkOverview.swift macos/Tests/RegressionTests.swift -o "$TEST_DIR/regression-tests"
"$TEST_DIR/regression-tests"
