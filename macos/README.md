# Reattach for Mac

Native macOS 14+ menu bar companion for browsing tmux work and reviewing reattachd permission requests.
The app uses the existing iOS bundle identifier (`tokyo.kumabook.tmux.reattach`),
so its macOS build can be added to the existing App Store Connect record.
The iOS permission models, option parser and paging rules are compiled directly
into both apps. The daemon and iOS target are unchanged.

The interface supports English and Japanese, following the macOS app language.
Translations live in `ReattachMac/Localizable.xcstrings` and
`ReattachMac/InfoPlist.xcstrings`, including menus, errors and accessibility labels.

## Build

Open `ReattachMac.xcodeproj`, select `ReattachMac`, and run on My Mac.

```sh
xcodebuild -project macos/ReattachMac.xcodeproj -scheme ReattachMac \
  -configuration Debug -derivedDataPath /tmp/reattach-mac-build build
macos/Tests/run.sh
```

For App Store distribution, archive the Release configuration with the existing
Apple team. App Store Connect platform setup, screenshots and submission are
separate release steps. Mac-specific metadata and export options live in `AppStore/`;
review notes there are a draft until the review server and screenshots are verified.
`PrivacyInfo.xcprivacy` declares local preferences and elapsed-time measurements.

## Connect

The default is `http://127.0.0.1:8787`. Start the existing daemon separately.
Open Settings from the menu bar to change address, port, or credentials and use
“保存して接続テスト”. Credentials are saved in Keychain per server URL; changing
servers never carries the old server's credential over automatically.

If devices have already been registered, a bearer token is required even on
localhost. Generate a setup URL with `reattachd setup --url <server-url>`, copy
its `setup_token` query parameter into Settings, and select “登録して保存”.
Alternatively enter an existing device token. Do not paste tokens into source
files or logs. Tailscale-only listeners need their HTTPS hostname instead of
localhost. Remote servers should use HTTPS. For a server behind Cloudflare
Access, enter the service token's Client ID and Client Secret in Settings; they
are sent with every request and stored in Keychain per server URL. Browser
sign-in to Cloudflare Access is not supported.

## Controls

The first panel opening shows a short, skippable introduction. It starts with
connection setup unless a successful connection has already been established.
The guide stays in a separate window while the hotkey exercise hides and reopens
the actual panel before advancing; opening
from the menu bar does not count as completing that exercise. A separate practice
card lets number keys select and Return confirm without any server request.
The panel’s lower-right “?” button opens a shortcut reference and can replay the guide.
Cards separate session names from pane targets and show up to 40 recent output lines
in a bounded preview; Expand shows the full output. Successful replies briefly show
confirmation before automatic closing is allowed; failed sends do not show success.

Settings are grouped into General (hotkey, automatic display, terminal, login),
Appearance (background, screen, position and size), and Connection (server and registration).

Left-click the menu bar icon to toggle the permission panel directly. Right-click
(or Control-click) for Settings and Quit; the icon continues to show the pending count.

Appearance settings independently control background tint transparency and the
“ぼかしの強さ” slider (0–100%). This controls material blending, not blur radius.
Blur strength is independent of transparency; 0% removes the blur layer.
Existing blur on/off preferences initialize the slider at 100%/0% respectively.
The macOS material retains its own tint; text and controls remain opaque. Settings
apply immediately and persist. Reduce Transparency overrides both with an opaque background.

- Default global hotkey: Control–Shift–Space. Settings offer modifier combinations
  and A/R/P/Space; registration conflicts are reported. The menu bar remains usable.
- The permission panel defaults to 94% of the visible width and height of the display
  containing the pointer, recalculated each time it opens. Settings → 位置・サイズ can follow the pointer or pin a display using its UUID.
  If the pinned display disconnects, the panel falls back to an available screen
  and returns when the display reconnects. It also offers independent width/height (1–100%) and
  horizontal/vertical placement (0–100%) sliders and numeric fields in 1% steps.
  Position spans the available travel, with 50% centered. Minimum size is
  460 × 520 points where the screen allows it; all frames stay inside the work area.
  Standard window buttons are replaced by the panel’s own close button. Drag the empty header area to move the window, or its edges/corners
  to resize it. Mouse movement/resizing saves the resulting relative layout. Reopening restores
  it on the automatically selected or pinned display; moving does not change that
  display preference.
  Long requests can still scroll.
- Two-finger horizontal trackpad swipes move cards with the fingers and reveal
  the neighboring card. Releasing settles to the next card or springs back;
  vertical gestures scroll normally and momentum never advances extra cards.
- Left/Right or Control–B/F: previous/next card. Up/Down or Control–P/N: choose an option. Return: send the
  explicitly selected option. Number keys select an option directly; Return sends it.
  Multi-digit numbers can be typed within 0.8 seconds. Numbers in the reply field
  remain normal text input. Shortcuts defer to Japanese IME marked-text handling,
  and keyboard-selected options scroll into view. A newly displayed card has no selected option.
- Tab: focus the reply field. Command–Return: send text. Arrow keys in the reply
  field retain their normal text editing behavior, as do Control–N/P/F/B.
- Command–R reloads the displayed card, including while typing a reply.
- “tmuxで確認” (Command–O) selects the current request’s tmux window and pane,
  then closes the panel. Settings → tmuxで確認 can select an installed Ghostty,
  iTerm2, or Terminal to bring forward; the default returns to the previous app.
  A configured terminal must already be running. A failure keeps the panel open.
  This does not send input, identify a particular terminal window, or switch a
  client to a different session.
- Escape: close the expanded preview, or hide the panel and restore the previous
  application. Sending Escape to the terminal is a separate menu action.
- An optional setting hides the panel when focus moves to another app (off by default).
  Settings and attached sheets keep it open; hiding does not reactivate the previous app.
- Drafts and the selected card survive hiding/showing the panel. Completed or
  replaced requests discard their drafts. Polling runs every two seconds.
- Replies recheck request identity and terminal output before sending. Failed
  sends are never retried automatically; explicitly reload the preview first.
- Showing/hiding the panel fades over 200/150 ms; repeated hotkeys reverse the
  fade from its current opacity. Reduce Motion disables the transition.
- Settings offer three mutually exclusive new-request modes: no action (default),
  local notification, or automatic panel display. Existing automatic-display preferences
  are preserved. Notifications require system permission and the app to be running;
  clicking one opens the request without sending a reply. Repeated polls and connection
  recovery do not repeat notifications. Completed requests have their notifications removed.
  Automatic closing when the last request disappears is an independent setting. Manual dismissal suppresses reopening for
  the same requests. Failed polls never trigger closure. Automation waits while
  Settings or the context sheet is open, or a request operation is in progress.
- Login launch uses macOS Login Items; the system may require approval.

## Work overview

Open All Work from the permission panel header or the menu bar icon's right-click menu.
It shares the permission panel and global shortcut: pending requests open directly,
and without requests the panel shows All Work. Command–Shift–A opens All Work from
the permission view. Cards show recent output and a blue dot for new output.
Search matches work titles, pane targets and working directories.
Press Space for a larger read-only preview. Arrow keys or Control–N/P/F/B move
selection; Return explicitly selects the pane in tmux and activates the configured
terminal (or the previous app). This does not switch a terminal client to another session.
Control–Tab and Control–Shift–Tab cycle forwards/backwards, wrapping at the ends.
Pending-request cards link back to the permission view. Command–F focuses search,
Command–R refreshes, and Escape dismisses search focus, the inspector, then the window.
Only visible/selected panes are captured, with at most four concurrent reads;
refresh runs every three seconds and stops when the window closes.
Previews remain cached in memory across panel openings and are cleared on connection
changes. Optional on-device summaries use Apple Foundation Models on macOS 26+ when
available, default off. The default prompt follows the output language; Settings
allows a custom prompt and restoring the default. Applying a changed prompt invalidates
cached summaries. No external AI service is used, and original output remains available.

Permission previews briefly retry empty menus (150/300/600 ms) to accommodate hooks
that arrive before terminal rendering. This retries reads only, never submissions.

## Manual verification before release

Use a signed build to verify Keychain access and sandbox networking, then check
hotkey conflict reporting, activation from another app and full-screen Spaces,
Japanese IME composition, keyboard focus and VoiceOver, login launch, and
registration against an actual daemon. Confirm that closing/reopening preserves
drafts and that expired requests cannot be submitted. No live agent replies are
sent by the regression tests.
