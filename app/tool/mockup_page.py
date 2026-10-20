"""Build the mockup page from the preview harness output (see tool/mockup.sh).

Reads <dir>/manifest.json (written by test/preview_test.dart, in screen order) and
writes <dir>/index.html: one row per screen, dark then light, with its caption. Images
are referenced as preview/<name>-<dark|light>.png, the paths they are published under.
"""
import html
import json
import os
import struct
import subprocess
import sys
import zlib


def top_is_dark(path, rows=(10, 110)):
    """Mean luminance of the status bar band of a PNG (8-bit RGB/RGBA), so the status
    bar ink can follow the screen as iOS does: white on a dark top, black on a light one."""
    data = open(path, "rb").read()
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, _, depth, ctype = struct.unpack(">IIBB", body[:10])
            bpp = {2: 3, 6: 4}[ctype]
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride = zlib.decompress(idat), w * bpp
    prev, total, count = bytearray(stride), 0, 0
    for y in range(rows[1]):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p_ = a + b - c
                pa, pb, pc = abs(p_ - a), abs(p_ - b), abs(p_ - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        if y >= rows[0]:
            for x in range(0, stride, bpp * 8):
                total += 0.2126 * line[x] + 0.7152 * line[x + 1] + 0.0722 * line[x + 2]
                count += 1
        prev = line
    return total / count < 140

d, title = sys.argv[1], sys.argv[2]
screens = json.load(open(os.path.join(d, "manifest.json"), encoding="utf-8"))
try:
    rev = subprocess.run(["git", "log", "-1", "--format=%h %cs"], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain", "--", "lib"], capture_output=True, text=True).stdout.strip()
except OSError:
    rev, dirty = "", ""
source = f"{rev}{' + local changes' if dirty else ''}"

# The frame: iPhone 15 Pro Max, 430×932 pt, shown at W px wide. Status bar ink follows
# the screen (white on dark, black on light), like iOS does.
W = 232
k = W / 430


def px(v):
    return f"{v * k:.1f}px"


BAR = (
    '<svg class="sig" viewBox="0 0 18 12"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/>'
    '<rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></svg>'
    '<svg class="wifi" viewBox="0 0 16 12"><path d="M8 11.5l2.6-3.2a4.2 4.2 0 0 0-5.2 0z"/><path d="M8 4.3c2 0 3.8.7 5.2 1.9l1.5-1.8A10.3 10.3 0 0 0 8 1.9 10.3 10.3 0 0 0 1.3 4.4l1.5 1.8A8 8 0 0 1 8 4.3z"/></svg>'
    '<span class="bat"><i></i></span>'
)


def phone(name, b, cap):
    ink = "on-dark" if top_is_dark(os.path.join(d, f"{name}-{b}.png")) else "on-light"
    return (
        f'<div class="phone {ink}"><img src="preview/{name}-{b}.png" alt="{cap}, {b}" loading="lazy">'
        f'<span class="island"></span><span class="time">9:41</span><span class="icons">{BAR}</span>'
        f'<span class="home"></span></div>'
    )


rows = []
for s in screens:
    name, cap = s["name"], html.escape(s["caption"])
    imgs = "".join(phone(name, b, cap) for b in ("dark", "light") if os.path.exists(os.path.join(d, f"{name}-{b}.png")))
    rows.append(f'<section><h2>{cap}</h2><div class="pair">{imgs}</div></section>')

page = f"""<title>{html.escape(title)}</title>
<style>
:root {{ --bg:#ececec; --fg:#111; --muted:#5b5b5b; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bg:#141414; --fg:#eee; --muted:#a3a3a3; color-scheme:dark; }} }}
:root[data-theme="dark"] {{ --bg:#141414; --fg:#eee; --muted:#a3a3a3; color-scheme:dark; }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,"Segoe UI",Roboto,sans-serif;
  padding-left:max(16px,env(safe-area-inset-left,0px)); padding-right:max(16px,env(safe-area-inset-right,0px)); padding-block:24px 48px; }}
main {{ max-width:1500px; margin:0 auto; display:grid; gap:28px; }}
h1 {{ margin:0; font-size:24px; }} .meta {{ margin:0; color:var(--muted); }}
.grid {{ display:flex; flex-wrap:wrap; gap:28px 36px; }}
section {{ display:grid; gap:8px; }} h2 {{ margin:0; font-size:15px; }}
.pair {{ display:flex; gap:12px; flex-wrap:wrap; }}
.phone {{ position:relative; width:{W}px; aspect-ratio:430/932; padding:{px(9)}; box-sizing:content-box; border-radius:{px(64)};
  background:#1b1b1d; box-shadow:inset 0 0 0 {px(2.5)} #4a4a4f, 0 10px 28px rgba(0,0,0,.28); }}
.phone img {{ display:block; width:100%; height:100%; border-radius:{px(55)}; }}
.island {{ position:absolute; left:50%; top:{px(9 + 11)}; width:{px(126)}; height:{px(37)}; translate:-50% 0; border-radius:{px(19)}; background:#000; }}
.time {{ position:absolute; top:{px(9 + 17)}; left:{px(9 + 52)}; font:600 {px(17)}/1 -apple-system,"SF Pro Text","Segoe UI",sans-serif; letter-spacing:-.01em; }}
.icons {{ position:absolute; top:{px(9 + 20)}; right:{px(9 + 34)}; display:flex; align-items:center; gap:{px(6)}; }}
.icons svg {{ height:{px(12)}; fill:currentColor; }} .sig {{ width:{px(18)}; }} .wifi {{ width:{px(16)}; }}
.bat {{ width:{px(25)}; height:{px(12)}; border:{px(1.2)} solid currentColor; border-radius:{px(4)}; opacity:.95; padding:{px(1.5)}; box-sizing:border-box; display:flex; }}
.bat i {{ flex:0 0 82%; background:currentColor; border-radius:{px(2)}; }}
.home {{ position:absolute; left:50%; bottom:{px(9 + 8)}; width:{px(140)}; height:{px(5)}; translate:-50% 0; border-radius:{px(3)}; }}
.phone.on-dark .time, .phone.on-dark .icons {{ color:#fff; }} .phone.on-dark .home {{ background:#fff; }}
.phone.on-light .time, .phone.on-light .icons {{ color:#000; }} .phone.on-light .home {{ background:#000; }}
</style>
<main><header><h1>{html.escape(title)}</h1>
<p class="meta">Rendered from the app's code ({html.escape(source)}), 430×932 (iPhone 15 Pro Max, safe areas 59/34 pt). Each screen: dark, then light.</p></header>
<div class="grid">{''.join(rows)}</div></main>
"""
open(os.path.join(d, "index.html"), "w", encoding="utf-8").write(page)
