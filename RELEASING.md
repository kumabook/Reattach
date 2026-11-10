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

## App Store preparation (Xcode Cloud)

1. Use the existing enabled `Default` Xcode Cloud workflow for the Reattach product. It watches `main` changes under `ios/` and archives the `Reattach` scheme for App Store distribution.
2. Confirm the **Xcode Cloud build number** exceeds the highest build already uploaded to App Store Connect. Cloud numbering is separate from `CURRENT_PROJECT_VERSION`; changing the project number does not fix a Cloud number collision. Avoid manual uploads during this workflow.
3. Push the release commit and wait for the Cloud archive and App Store Connect processing. Verify the source commit and select the resulting valid build for the 2.0.0 draft. Add English/Japanese TestFlight notes from the metadata directory.
4. Review the English/Japanese description, promotional text, release notes, screenshots, review contact, authentication instructions, and QR attachment. Existing screenshots have not been refreshed for 2.0.
5. Verify the public review server using the credentials already in the review notes. Use an app-style User-Agent for scripted checks: Cloudflare may reject Python's default User-Agent even when the credentials are valid.
6. Keep release mode manual. Complete any newly required App Store attributes and submit the selected build for App Review. Do not manually release the iOS app before approval and final verification.

## Daemon and website publication

1. Commit only the release files and intended signing configuration changes. Keep unrelated Android work and unverified local Xcode Cloud manifest changes separate.
2. Push the release commit to `main`. Changes under `docs/` deploy automatically to GitHub Pages; retain the preparation wording until the app is available.
3. Create and push `v2.0.0` only when ready to publish daemon binaries. The tag workflow builds five targets, publishes a GitHub release, and updates the Homebrew tap when its token is configured.
4. Verify all daemon release assets and the Homebrew update, and use the curated 2.0.0 changelog in the GitHub release description.
5. After App Review approval and final testing, release the app manually. Remove the website's preparation wording and mark the changelog with the actual release date.

Never commit App Store Connect keys, generated API credentials, local build artifacts, or review contact details.


### Build 43 follow-up

Build 42 does not contain the final split-pane layout features. Submit build 43, which includes independent scrolling, tmux border colours, the display-mode menu, external keyboard focus fixes, and slow-response status.

Update the review server daemon to the same source revision. Older daemons retain single-pane display.

Validation before packaging: 43 iOS unit tests; display-mode menu, split selection, and rotation UI test; 36 Rust unit tests and isolated tmux border inheritance/change tests. English and Japanese strings were checked against the built app.

## Submission record — 2026-11-09

- Source: `7d1f1feed09a92a57e53ba900b6b3a9ae1a2e478`.
- Daemon: `v2.0.0` published by GitHub Actions; all five builds and the Homebrew tap update succeeded. The review server now runs the published Linux musl artifact.
- Xcode Cloud build 42 collided with the previously uploaded manual build. Retrying the same release commit produced build 43, now valid in App Store Connect.
- iOS 2.0.0 (43): `WAITING_FOR_REVIEW`, manual release. Submission: `a49ad643-eb85-4bb8-b42f-3b7738d6c419`.
- Completed the newly required `socialMedia` age-rating attribute as false; other rating answers were preserved.
- Verified public registration, terminal output, pane geometry/borders, and WebSocket tmux/clipboard capabilities using the review-note Cloudflare credentials. Existing QR attachment and store screenshots are complete.

## Resubmission record — 2026-11-10

- Selected Xcode Cloud build 44, source `97a57ddfcdbcbe56e138642ec2ab3e4a4401fd3c`, for 2.0.0. Release mode remains manual.
- The rejection reports a crash after initial launch. The cause remains unknown; no crash report or device/OS details were included in the message received. The review notes explicitly state that a crash fix has not been confirmed and request those details if it recurs.
- Local Xcode 27.2 Release builds reached initial setup on a fresh iPhone 17 simulator (iOS 27.2) and on the physical iPhone Duo. The device used temporary launch defaults to display the unconfigured state without deleting user data. These checks do not establish that the App Store-distributed build is free of the reported crash.
- Reverified public registration, terminal output, and authenticated WebSocket support using the existing review credentials.
- Added English/Japanese permission card screenshots and release notes. The screenshot UI test passed for both languages. The Japanese iPhone set preserves the five previously inherited English images and adds the Japanese card image; the existing iPad set remains unchanged.
- Screenshot capture fixtures added locally after build 44 are debug-test-only and are not part of that submitted binary. See `fastlane/screenshot_sources/README.md` for reproduction.
- Resubmitted at 19:11 JST. Version and submission state are `WAITING_FOR_REVIEW`; selected build is 44 and release mode is `MANUAL`. Submission: `a49ad643-eb85-4bb8-b42f-3b7738d6c419`.
- All screenshots finished processing: six iPhone images per locale and four existing English iPad images. The review QR attachment remains complete.
