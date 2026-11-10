#!/usr/bin/env python3
"""Render the generated iPhone App Store screenshots.

The English images 0, 1, 2 and 4 are the original store artwork and serve as
bases. This writes the permission card for both locales in the same device
frame, and the Japanese versions of the other images with Japanese headlines.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SCREEN = (146, 816, 1142)
SCREEN_RADIUS = 124
ISLAND = (511, 851, 781, 923)
TITLE_AREA = (150, 700)
TITLE_BASELINE = 352
TITLE_LINE_HEIGHT = 152
TITLE_COLOR = (37, 36, 34)
SCALE = 4

root = Path(__file__).resolve().parents[1]
sources = root / "screenshot_sources"
shots = root / "screenshots"
fonts = {
    "en-US": ImageFont.truetype("/Library/Fonts/SF-Pro-Display-Semibold.otf", 108),
    "ja": ImageFont.truetype("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc", 92),
}
ja_titles = {
    0: ["iPhoneから", "tmuxセッションを管理"],
    1: ["席を離れても", "進捗確認・返信"],
    2: ["入力が必要になったら", "プッシュ通知でお知らせ"],
    4: ["QRを読み取るだけで", "安全にすぐ接続"],
}
permission_titles = {
    "en-US": ["Review Agent Requests", "Right from Your iPhone"],
    "ja": ["許可待ちをまとめて確認", "その場で回答"],
}


def base(index):
    return Image.open(shots / "en-US" / f"{index}_APP_IPHONE_65_{index}.png").convert("RGB")


def rounded_mask(size, box, radius):
    mask = Image.new("L", (size[0] * SCALE, size[1] * SCALE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([v * SCALE for v in box], radius * SCALE, fill=255)
    return mask.resize(size, Image.LANCZOS)


def retitle(image, lines, font):
    draw = ImageDraw.Draw(image)
    for y in range(*TITLE_AREA):
        draw.line([(0, y), (image.width, y)], fill=image.getpixel((3, y)))
    for i, line in enumerate(lines):
        draw.text((image.width / 2, TITLE_BASELINE + i * TITLE_LINE_HEIGHT), line,
                  font=font, fill=TITLE_COLOR, anchor="ms")
    return image


def permission_card(locale):
    template = base(0)
    image = template.copy()
    left, top, right = SCREEN
    shot = Image.open(sources / f"permission-capture-{locale}.png").convert("RGB")
    shot = shot.resize((right - left, round(shot.height * (right - left) / shot.width)), Image.LANCZOS)
    box = (left, top, right, top + shot.height)
    image.paste(shot, (left, top), rounded_mask(image.size, box, SCREEN_RADIUS).crop(box))
    image.paste(template, (0, 0), rounded_mask(image.size, ISLAND, (ISLAND[3] - ISLAND[1]) / 2))
    return retitle(image, permission_titles[locale], fonts[locale])


outputs = {shots / locale / "3_APP_IPHONE_65_permissions.png": permission_card(locale) for locale in fonts}
for index, lines in ja_titles.items():
    outputs[shots / "ja" / f"{index}_APP_IPHONE_65_{index}.png"] = retitle(base(index), lines, fonts["ja"])
for target, image in outputs.items():
    image.save(target)
    print(target.relative_to(root))
