# App Store screenshots

## iPhone, iPad and Apple Watch

`render_store.py` builds the store images from captures in `store/`:

- iPhone (1320 × 2868), iPhone Duo outer display (1398 × 2034) and iPad 13" (2064 × 2752): six images per locale with a headline and a device frame
- Apple Watch Series 11 46mm (416 × 496): the list and detail captures, unchanged

```sh
python3 fastlane/screenshot_sources/render_store.py
```

This requires Pillow, SF Pro Display and Hiragino Sans.

### Capturing

iPhone, iPhone Duo and iPad captures come from `StoreScreenshotTests` (UI tests). Debug builds only: the app's `-store-screenshot` argument names the demo server "MacBook Pro", adds sample sessions and hides the demo banner; `-store-screenshot-input` enables direct input in the demo.

1. Create simulators for screenshots (iPhone 17 Pro Max, iPhone Duo and iPad Pro 13-inch) and turn off their hardware keyboard, e.g. `PlistBuddy -c "Add :DevicePreferences:<UDID>:ConnectHardwareKeyboard bool false" ~/Library/Preferences/com.apple.iphonesimulator.plist`, before booting them.
2. Set the status bar: `xcrun simctl status_bar <UDID> override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`.
3. Run `xcodebuild test -only-testing:ReattachUITests/StoreScreenshotTests -resultBundlePath …` and export the attachments with `xcrun xcresulttool export attachments`. Save them as `store/{iphone,duo,ipad}/<scene>-<en|ja>.png`. The iPhone Duo simulator captures its outer display; in store-screenshot mode the app always shows the helper keys, because that simulator reports a hardware keyboard.

Do not send key presses with `typeKey` in these tests: the simulator then reports a hardware keyboard and hides the helper keys.

Watch captures: build the `ReattachWatch` scheme for an Apple Watch Series 11 (46mm) simulator, launch it with `-store-screenshot` (and `-store-screenshot-detail` for the detail screen) plus `-AppleLanguages`, and save `xcrun simctl io <UDID> screenshot` as `store/watch/{1-list,2-detail}-<en|ja>.png`.

## Header and search results

`render_header.py` renders `../app_store_assets/header-<locale>.png` (5244 × 2950), one universal image for the product page header and search results. Upload and place them with `fastlane/upload_creative_assets.rb`; deliver cannot upload these yet.

## Mac

`render_mac.py` renders the Mac images in `../screenshots_mac` from the panel captures in `mac/`.
