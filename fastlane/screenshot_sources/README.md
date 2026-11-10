# Permission card screenshots

The English and Japanese SVGs embed captures of the actual SwiftUI permission inbox, produced by `testPermissionStoreScreenshots`. The fixture is available only when the debug UI-test fixture is enabled; it does not alter the submitted Release app.

Capture on iPhone 17 with the simulator status bar set to 9:41, then export the test attachments. Generate the store images with:

```sh
python3 fastlane/screenshot_sources/render_permissions.py --en /path/to/en.png --ja /path/to/ja.png
```

This requires Inkscape. The output is 1284 × 2778. The SVGs also retain the embedded captures so the final compositions remain reproducible without temporary test artifacts.

The Japanese set retains copies of the five previously inherited English screenshots and adds the Japanese permission card image. The English set retains its existing five screenshots and adds the English permission card image.
