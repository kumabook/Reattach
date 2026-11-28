#!/usr/bin/env python3
"""Render the 2.1 App Store screenshots for iPhone, iPad and Apple Watch.

Captures live in screenshot_sources/store/{iphone,ipad,watch}. iPhone and iPad
captures come from StoreScreenshotTests on simulators with the hardware keyboard
disconnected and the status bar at 9:41. Watch captures come from the Watch app
launched with -store-screenshot (and -store-screenshot-detail) on Apple Watch
Series 11 (46mm). Requires Pillow, SF Pro Display and Hiragino Sans.

    python3 fastlane/screenshot_sources/render_store.py
"""
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
store = root / "screenshot_sources" / "store"
out = root / "screenshots"
LOCALES = {"en-US": "en", "ja": "ja"}
SCALE = 3

TITLES = {
    "pane": {"en-US": ["Your tmux,", "wherever you are"], "ja": ["いつもの tmux に、", "どこからでも戻れる"]},
    "sessions": {"en-US": ["Your tmux,", "wherever you are"], "ja": ["いつもの tmux に、", "どこからでも戻れる"]},
    "layout": {"en-US": ["Your panes,", "laid out as in tmux"], "ja": ["tmux の配置", "そのままで"]},
    "keys": {"en-US": ["Type with", "your own keys"], "ja": ["自分のキー操作で", "入力できる"]},
    "permissions": {"en-US": ["Answer your agents", "on the spot"], "ja": ["許可待ちに、", "その場で応答"]},
    "watch": {"en-US": ["Reply from", "your wrist"], "ja": ["Apple Watch からも", "応答できる"]},
    "setup": {"en-US": ["Set up", "in two steps"], "ja": ["2 ステップで", "始められる"]},
}

DEVICES = {
    # canvas, title top, title size (en, ja), shot width, shot top, bezel, screen radius
    "iphone": dict(canvas=(1320, 2868), title_top=250, sizes=(128, 112), width=1040, top=700, bezel=30, radius=120,
                   scenes=["sessions", "layout", "keys", "permissions", "watch", "setup"], prefix="APP_IPHONE_69"),
    "ipad": dict(canvas=(2064, 2752), title_top=230, sizes=(132, 116), width=1600, top=600, bezel=34, radius=60,
                 scenes=["pane", "layout", "keys", "permissions", "watch", "setup"], prefix="APP_IPAD_PRO_13"),
}
CAPTURE = {"sessions": "1-sessions", "pane": "0-pane", "layout": "2-layout", "keys": "3-keys",
           "permissions": "4-permissions", "setup": "6-setup"}


def font(locale, size):
    if locale == "ja":
        return ImageFont.truetype("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc", size)
    return ImageFont.truetype("/Library/Fonts/SF-Pro-Display-Bold.otf", size)


def background(size):
    top, bottom = (226, 236, 252), (246, 248, 252)
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(size[1]):
        t = y / size[1]
        draw.line([(0, y), (size[0], y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return image


def rounded(image, radius):
    mask = Image.new("L", (image.width * SCALE, image.height * SCALE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, mask.width - 1, mask.height - 1], radius * SCALE, fill=255)
    return mask.resize(image.size, Image.LANCZOS)


def framed(shot, bezel, radius):
    frame = Image.new("RGBA", (shot.width + bezel * 2, shot.height + bezel * 2), (0, 0, 0, 0))
    body = Image.new("RGBA", frame.size, (29, 29, 31, 255))
    frame.paste(body, (0, 0), rounded(body, radius + bezel))
    frame.paste(shot, (bezel, bezel), rounded(shot, radius))
    return frame


def title(image, lines, locale, top, size):
    draw = ImageDraw.Draw(image)
    f = font(locale, size)
    for i, line in enumerate(lines):
        draw.text((image.width / 2, top + i * size * 1.22), line, font=f, fill=(29, 29, 31), anchor="mt")


def device_scene(device, scene, locale, spec):
    image = background(spec["canvas"])
    title(image, TITLES[scene][locale], locale, spec["title_top"], spec["sizes"][locale == "ja"])
    if scene == "watch":
        watches(image, locale, spec)
        return image
    shot = Image.open(store / device / f"{CAPTURE[scene]}-{LOCALES[locale]}.png").convert("RGB")
    shot = shot.resize((spec["width"], round(shot.height * spec["width"] / shot.width)), Image.LANCZOS)
    device_image = framed(shot, spec["bezel"], spec["radius"])
    image.paste(device_image, ((image.width - device_image.width) // 2, spec["top"]), device_image)
    return image


def watches(image, locale, spec):
    names = ["1-list", "2-detail"] if image.width > 1500 else ["2-detail"]
    scale = 1.9 if len(names) == 2 else 2.3
    shots = [Image.open(store / "watch" / f"{n}-{LOCALES[locale]}.png").convert("RGB") for n in names]
    shots = [s.resize((round(s.width * scale), round(s.height * scale)), Image.LANCZOS) for s in shots]
    framed_shots = [framed(s, round(44 * scale / 2), round(70 * scale)) for s in shots]
    gap = 120
    total = sum(w.width for w in framed_shots) + gap * (len(framed_shots) - 1)
    x = (image.width - total) // 2
    y = spec["top"] + 240
    for w in framed_shots:
        image.paste(w, (x, y), w)
        x += w.width + gap


def main():
    for locale in LOCALES:
        folder = out / locale
        for old in folder.glob("*.png"):
            old.unlink()
        for device, spec in DEVICES.items():
            for i, scene in enumerate(spec["scenes"], 1):
                target = folder / f"{i}_{spec['prefix']}_{scene}.png"
                device_scene(device, scene, locale, spec).save(target)
                print(target.relative_to(root))
        for i, name in enumerate(["1-list", "2-detail"], 1):
            target = folder / f"{i}_APP_WATCH_46_{name[2:]}.png"
            shutil.copy(store / "watch" / f"{name}-{LOCALES[locale]}.png", target)
            print(target.relative_to(root))


if __name__ == "__main__":
    main()
