# iPhone store screenshots

The iPhone set has five images per locale: sessions, progress and replies, push notifications, the permission card, and QR setup.

The English images 0, 1, 2 and 4 are the original store artwork. `render_iphone.py` generates the rest from them:

- `3_APP_IPHONE_65_permissions.png` for both locales, placing `permission-capture-<locale>.png` in the device frame of image 0
- the Japanese images 0, 1, 2 and 4, replacing the English headlines with Japanese ones

```sh
python3 fastlane/screenshot_sources/render_iphone.py
```

This requires Pillow, SF Pro Display and Hiragino Sans. The output is 1284 × 2778.

The permission captures come from `testPermissionStoreScreenshots`, which relies on a fixture that exists only in debug UI-test builds; the submitted Release app is unaffected. Capture on iPhone 17 with the simulator status bar set to 9:41 and replace the capture PNGs with the exported test attachments.
