#!/usr/bin/env python3
"""Render the App Store "Header and Search Results" universal asset (5244 x 2950, 16:9).

The same permission request on Mac, iPhone and Apple Watch, under the headline.
Everything stays inside the area both crops keep: 21:9 for the header and 3:2
for search results. Upload the PNGs from ../app_store_assets by hand in App Store
Connect (Asset Library > Header and Search Results).

    python3 fastlane/screenshot_sources/render_header.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

from render_store import background, font, framed, store

root = Path(__file__).resolve().parents[1]
out = root / "app_store_assets"
SIZE = (5244, 2950)
SAFE = (round(SIZE[1] * 3 / 2), round(SIZE[0] * 9 / 21))
LOCALES = {"en-US": "en", "ja": "ja"}
HEADLINES = {"en-US": "Your tmux, wherever you are.", "ja": "いつもの tmux に、どこからでも戻れる。"}


def shadowed(image, layer, xy, blur=60, offset=30, alpha=70):
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    mask = layer.split()[3].point(lambda a: alpha if a else 0)
    shadow.paste((0, 0, 0, 255), (xy[0], xy[1] + offset), mask)
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))
    image.alpha_composite(layer, xy)


def mac_window(locale, width):
    shot = Image.open(root / "screenshot_sources" / "mac" / f"panel-{LOCALES[locale]}.png").convert("RGB")
    shot = shot.crop((0, 0, shot.width, round(shot.height * 0.62)))
    shot = shot.resize((width, round(shot.height * width / shot.width)), Image.LANCZOS)
    window = Image.new("RGBA", shot.size, (0, 0, 0, 0))
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width - 1, shot.height - 1], 40, fill=255)
    window.paste(shot, (0, 0), mask)
    return window


def render(locale):
    image = background(SIZE).convert("RGBA")
    left = (SIZE[0] - SAFE[0]) // 2
    top = (SIZE[1] - SAFE[1]) // 2
    size = 190 if locale == "en-US" else 170
    ImageDraw.Draw(image).text((SIZE[0] / 2, top + 90), HEADLINES[locale], font=font(locale, size),
                               fill=(29, 29, 31), anchor="mt")

    bottom = top + 2060
    mac = mac_window(locale, 2450)
    shadowed(image, mac, (left + 80, bottom - mac.height - 120))

    phone = Image.open(store / "iphone" / f"4-permissions-{LOCALES[locale]}.png").convert("RGB")
    phone = phone.resize((720, round(phone.height * 720 / phone.width)), Image.LANCZOS)
    phone = framed(phone, 24, 84)
    shadowed(image, phone, (left + 2330, bottom - phone.height))

    watch = Image.open(store / "watch" / f"2-detail-{LOCALES[locale]}.png").convert("RGB")
    watch = watch.resize((round(watch.width * 1.9), round(watch.height * 1.9)), Image.LANCZOS)
    watch = framed(watch, 42, 133)
    shadowed(image, watch, (left + 3250, bottom - watch.height))
    return image.convert("RGB")


def main():
    out.mkdir(exist_ok=True)
    for locale in LOCALES:
        target = out / f"header-{locale}.png"
        render(locale).save(target)
        print(target.relative_to(root))


if __name__ == "__main__":
    main()
