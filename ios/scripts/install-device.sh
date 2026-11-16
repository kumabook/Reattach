#!/bin/sh
# Install local sources with either debugger support or production APNs.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 DEVICE_ID [development|notification]" >&2
    exit 2
fi
device_id=$1
mode=${2:-development}
case "$mode" in development|notification) ;; *) echo "Unknown mode: $mode" >&2; exit 2 ;; esac
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"
build_root=${REATTACH_IOS_BUILD_DIR:-${TMPDIR:-/tmp}/reattach-ios-device}
mkdir -p "$build_root"
if [ "$mode" = development ]; then
    xcodebuild -project ios/Reattach.xcodeproj -scheme Reattach -configuration Debug \
        -destination "id=$device_id" -derivedDataPath "$build_root/DerivedData" \
        -allowProvisioningUpdates build
    app="$build_root/DerivedData/Build/Products/Debug-iphoneos/Reattach.app"
else
    # release-testing is a local Ad Hoc export, not an App Store upload.
    xcodebuild -project ios/Reattach.xcodeproj -scheme Reattach -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$build_root/DerivedData" \
        -archivePath "$build_root/Reattach.xcarchive" -allowProvisioningUpdates archive
    cat > "$build_root/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>release-testing</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
    export_root=$(mktemp -d "$build_root/export.XXXXXX")
    xcodebuild -exportArchive -archivePath "$build_root/Reattach.xcarchive" \
        -exportPath "$export_root" -exportOptionsPlist "$build_root/ExportOptions.plist" \
        -allowProvisioningUpdates
    ditto -x -k "$export_root/Reattach.ipa" "$export_root/unpacked"
    app="$export_root/unpacked/Payload/Reattach.app"
fi
# Verify the actual signed environment before replacing the installed app.
codesign -d --entitlements - --xml "$app" > "$build_root/entitlements.plist"
actual_environment=$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$build_root/entitlements.plist")
expected_environment=development
if [ "$mode" = notification ]; then expected_environment=production; fi
if [ "$actual_environment" != "$expected_environment" ]; then
    echo "Unexpected APNs environment: $actual_environment" >&2
    exit 1
fi
xcrun devicectl device install app --device "$device_id" "$app"
xcrun devicectl device process launch --device "$device_id" --terminate-existing tokyo.kumabook.tmux.reattach
echo "Installed local $mode build (APNs: $actual_environment). Build files: $build_root"
