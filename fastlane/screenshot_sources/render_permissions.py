#!/usr/bin/env python3
"""Wrap unmodified app captures in the existing white App Store layout."""
import argparse
import base64
import html
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--en", type=Path, required=True)
parser.add_argument("--ja", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
for locale, capture, lines in [
    ("en-US", args.en, ["Review agent requests", "right from your iPhone"]),
    ("ja", args.ja, ["許可待ちをまとめて。", "その場で回答。"]),
]:
    image = base64.b64encode(capture.read_bytes()).decode()
    heading = "".join(f'<tspan x="642" y="{200 + i * 110}">{html.escape(line)}</tspan>' for i, line in enumerate(lines))
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1284" height="2778" viewBox="0 0 1284 2778">
<defs><clipPath id="screen"><rect x="160" y="494" width="964" height="2095.88" rx="88"/></clipPath></defs>
<rect width="1284" height="2778" fill="white"/>
<text fill="#202020" font-family="Helvetica Neue,Hiragino Sans,sans-serif" font-size="76" font-weight="700" text-anchor="middle">{heading}</text>
<rect x="134" y="468" width="1016" height="2147.88" rx="114" fill="#ddd"/>
<rect x="140" y="474" width="1004" height="2135.88" rx="108" fill="#171717"/>
<image x="160" y="494" width="964" height="2095.88" clip-path="url(#screen)" xlink:href="data:image/png;base64,{image}"/>
</svg>'''
    source = root / "screenshot_sources" / f"permission-{locale}.svg"
    source.write_text(svg)
    target = root / "screenshots" / locale / "5_APP_IPHONE_65_permissions.png"
    target.parent.mkdir(exist_ok=True)
    subprocess.run(["inkscape", str(source), "--export-type=png", "--export-png-color-mode=RGB_8", f"--export-filename={target}"], check=True)
    print(target)
