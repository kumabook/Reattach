# Releasing Reattach 2.0

## Release contents

- iOS: 2.0.0, build 43. Build 42 is already uploaded but does not include the final split-pane changes.
- Daemon: 2.0.0. Ship it before releasing the iOS app so users can obtain the matching tmux and clipboard features.
- English/Japanese App Store text: `fastlane/metadata/{en-US,ja}/`.
- TestFlight testing notes: `fastlane/changelog.txt`.
- GitHub release notes and upgrade details: `CHANGELOG.md`.
- Website: `docs/index.html` and `docs/ja/index.html`. Both currently label 2.0 as being prepared for release.

## Verification

Use Xcode 27.2 or later for the iPhone Duo release build. Check the app target's version and build in both Debug and Release configurations; test targets have separate version numbers.

```sh
cargo test --manifest-path reattachd/Cargo.toml --locked
cargo test --manifest-path reattachd/Cargo.toml --locked -- --ignored
xcodebuild -project ios/Reattach.xcodeproj -scheme Reattach \
  -destination 'platform=iOS Simulator,name=iPhone Duo,OS=27.2' test
```

The ignored Rust tests start isolated tmux servers. Verify the app on a real device before submitting: custom prefix navigation, copy-mode selection and clipboard transfer, Japanese composition, disconnect/reconnect, and returning from the background. Confirm iPad navigation and English/Japanese layouts as well.

## App Store preparation

1. Accept any updated Apple Developer agreements as the Account Holder. An outstanding agreement prevents distribution provisioning even if development archiving succeeds.
2. Archive the Release scheme for a generic iOS device and export using `app-store-connect`. Preserve build 43 (`manageAppVersionAndBuildNumber = false`). Verify the exported app's version, localizations, signing, and production push entitlement.
3. Upload the build and wait for App Store Connect processing. Add `fastlane/changelog.txt` as TestFlight testing notes, then verify the distributed build.
4. Review the 2.0.0 draft's English/Japanese description, promotional text, and release notes. Check screenshots, review access instructions, and the build selection. Existing screenshots have not been refreshed for 2.0.
5. Keep the release mode manual and submit the selected build to App Review only after final review of the release package.

Do not use `fastlane update_changelog` until build 43 is processed: that lane targets the latest available build.

## Daemon and website publication

1. Commit only the release files and intended signing configuration changes. Keep unrelated Android and Xcode Cloud work separate.
2. Push the release commit to `main`. Changes under `docs/` deploy automatically to GitHub Pages; retain the preparation wording until the app is available.
3. Create and push `v2.0.0` only when ready to publish daemon binaries. The tag workflow builds five targets, publishes a GitHub release, and updates the Homebrew tap when its token is configured.
4. Verify all daemon release assets and the Homebrew update, and use the curated 2.0.0 changelog in the GitHub release description.
5. After App Review approval and final testing, release the app manually. Remove the website's preparation wording and mark the changelog with the actual release date.

Never commit App Store Connect keys, generated API credentials, local build artifacts, or review contact details.


### Build 43 follow-up

Build 42 does not contain the final split-pane layout features. Submit build 43, which includes independent scrolling, tmux border colours, the display-mode menu, external keyboard focus fixes, and slow-response status.

Update the review server daemon to the same source revision. Older daemons retain single-pane display.

Validation before packaging: 43 iOS unit tests; display-mode menu, split selection, and rotation UI test; 36 Rust unit tests and isolated tmux border inheritance/change tests. English and Japanese strings were checked against the built app.
