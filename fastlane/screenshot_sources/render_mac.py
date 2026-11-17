#!/usr/bin/env python3
"""Render Mac App Store screenshots (2880x1800) from window captures in mac/.

The captures come from the Mac app connected to a local demo reattachd with
sample tmux sessions; only the panel window is captured, never the desktop.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = (2880, 1800)
BACKGROUND = ((236, 233, 245), (214, 226, 242))
TITLE_COLOR = (37, 36, 34)
SUBTITLE_COLOR = (92, 90, 100)
root = Path(__file__).resolve().parents[1]
sources = root / "screenshot_sources" / "mac"
fonts = {
    "en-US": ("/Library/Fonts/SF-Pro-Display-Semibold.otf", "/Library/Fonts/SF-Pro-Display-Regular.otf"),
    "ja": ("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc", "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"),
}
# (capture, fraction of the window height to keep, title, subtitle)
shots = {
    "en-US": [
        ("panel-en", 0.72, "Answer Agent Permission Requests",
         "Claude Code and Codex prompts from tmux, right in your menu bar"),
        ("work-en", 0.45, "See All Your Work at a Glance",
         "Pending requests, running agents and new output across sessions"),
    ],
    "ja": [
        ("panel-ja", 0.72, "エージェントの許可にすぐ回答",
         "tmuxで動くClaude CodeやCodexの確認を、メニューバーから"),
        ("work-ja", 0.45, "すべての作業をひと目で",
         "許可待ち・実行中のエージェント・新しい出力をまとめて確認"),
    ],
}


def gradient():
    image = Image.new("RGB", SIZE)
    top, bottom = BACKGROUND
    draw = ImageDraw.Draw(image)
    for y in range(SIZE[1]):
        t = y / (SIZE[1] - 1)
        draw.line([(0, y), (SIZE[0], y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return image


def render(locale, name, keep, title, subtitle):
    capture = Image.open(sources / f"{name}.png").convert("RGB")
    capture = capture.crop((0, 0, capture.width, round(capture.height * keep)))
    scale = min(2600 / capture.width, 1320 / capture.height)
    capture = capture.resize((round(capture.width * scale), round(capture.height * scale)), Image.LANCZOS)
    image = gradient()
    x = (SIZE[0] - capture.width) // 2
    y = 340 + (SIZE[1] - 340 - 60 - capture.height) // 2
    radius = 28
    shadow = Image.new("L", SIZE, 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 16, x + capture.width, y + capture.height + 16], radius, fill=110)
    image.paste((40, 40, 60), mask=shadow.filter(ImageFilter.GaussianBlur(36)))
    mask = Image.new("L", capture.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, capture.width - 1, capture.height - 1], radius, fill=255)
    image.paste(capture, (x, y), mask)
    bold, regular = fonts[locale]
    draw = ImageDraw.Draw(image)
    draw.text((SIZE[0] / 2, 175), title, font=ImageFont.truetype(bold, 104), fill=TITLE_COLOR, anchor="ms")
    draw.text((SIZE[0] / 2, 265), subtitle, font=ImageFont.truetype(regular, 54), fill=SUBTITLE_COLOR, anchor="ms")
    return image


for locale, items in shots.items():
    out = root / "screenshots_mac" / locale
    out.mkdir(parents=True, exist_ok=True)
    for index, item in enumerate(items):
        render(locale, *item).save(out / f"{index}_APP_DESKTOP_{index}.png")
        print(out / f"{index}_APP_DESKTOP_{index}.png")
