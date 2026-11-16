# Local iPhone installation

Run from a Mac signed in to the project's Apple Developer team in Xcode. The
phone must be paired, unlocked, and registered for provisioning. Both modes
replace Reattach (including a TestFlight installation) while retaining its data.
Neither mode uploads to App Store Connect.

```sh
# Xcode debugger support; uses development/sandbox APNs.
ios/scripts/install-device.sh DEVICE_ID development

# Latest local source, production APNs, no TestFlight processing wait.
ios/scripts/install-device.sh DEVICE_ID notification
```

`notification` archives Release and exports with Xcode's `release-testing`
method (Ad Hoc distribution). This is suitable for testing real APNs alerts and
widget pushes when sandbox registration is broken. It has distribution signing,
so a debugger cannot attach. Use `development` for debugger sessions.
The script checks signed APNs entitlements before installation; the app registers
its token with the matching environment based on its provisioning profile.

Builds and logs are retained under `$TMPDIR/reattach-ios-device` (or
`/tmp/reattach-ios-device` if TMPDIR is unset). Override with
`REATTACH_IOS_BUILD_DIR`. Export folders are unique to avoid stale IPA reuse.

## Sandbox registration incident (2026-11-14)

On kumaphone duo, the freshly returned development token was rejected by sandbox
APNs with HTTP 410 `Unregistered`, even after an app relaunch, device reboot and
explicit unregister/register. Its fingerprint matched the server's registration;
signing environment, APNs topic and team matched. Production APNs rejected that
same development token with `BadDeviceToken`, as expected. TestFlight pushes
worked according to the device owner.

The local `notification` mode is a workaround, not a repair of sandbox APNs.
Repeatedly unregistering at normal launch is not a fix and is not enabled.
Do not delete the user's app data to retry provisioning. For further sandbox
investigation, use Apple's Push Notifications Console to validate the current
development token and collect device/APNs diagnostics for Apple if it still
returns 410. Do not include raw device tokens or signing keys in source control.

Verified on the same phone: the `notification` script built, exported, installed
and launched local build 48; the app reported `sandbox: false`. A targeted alert
to the exact token fingerprint from that launch received HTTP 200 from production
APNs. Actual banner display requires device-side confirmation.

Apple Console cross-check: reinstalled and launched a fresh local Debug build,
confirmed the same development token fingerprint, then sent an Alert from Apple's
Push Notifications Console for `tokyo.kumabook.tmux.reattach` / Development.
The Device Token Validator accepted its environment/push-type combination, but
the Send operation rejected it as inactive for the topic. The console wrapper
reported `code: 400`, `message: bad-request`, request UUID
`c236e35b-7181-48bb-8f0f-14404a51f1bd`; this is distinct from the direct APNs HTTP
410 response. No delivery was accepted. The issue reproduces without reattachd
or its signing key. Restored the previously verified local production-APNs build
after the check. Sandbox registration recovery remains unresolved.

### Resolved by a clean reinstall

After backing up the app and shared containers, fully uninstalled Reattach,
installed the Debug build, and restored only the main app preferences before
launch. Verified both server configurations and the selected server matched the
backup. After the user allowed notifications, APNs issued a different development
token. A targeted sandbox alert to that new token returned HTTP 200, and the user
confirmed receipt. The phone remains on the normal development-signed Debug build
with debugger support. Previous reinstalls had only replaced the app in place.

For a recurrence, distinguish an in-place install from a complete uninstall.
Back up and verify settings before deleting; obtain user authorization for the
data removal. Do not restore old push-registration caches. A token change is
controlled by APNs, so do not assume a clean reinstall guarantees recovery in
other cases. The production-APNs notification mode remains an optional workflow,
not required for this phone now. Removing the app may also remove its Home Screen
widget; add it again if needed.
