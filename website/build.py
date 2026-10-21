#!/usr/bin/env python3
"""Build safe.cozypi.com in 15 languages, the same way as Flip Match's public pages.

English lives at / and /privacy.html; every other language at /<code>/ and
/<code>/privacy.html, so search engines can read each version. Each page lists
all versions (hreflang + x-default), the sitemap lists them with alternates,
and only the English pages redirect a visitor whose saved choice (localStorage
`cs.lang`) or browser language is another one (?lang=en stops that).

Copy is in i18n/<code>.json (en.json is the source). The build fails when a
translation misses a key or a placeholder.

The privacy page must match what the app and site actually do. If the app ever
sends anything anywhere, update it (all languages, new UPDATED date) and the
Google Play Data safety form.

Style follows the app's unlock screen (docs/ui.md, design "B2"): vault green,
blurred protected items behind, gold index. The unlock card in the hero is an
HTML illustration of the design, not a screenshot. Edit the copy in i18n/, run
`python3 website/build.py`, deploy with `npx wrangler deploy` from website/.
"""
import hashlib, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = 'https://github.com/cozy-pi/cozysafe/releases/latest/download/'
REPO = 'https://github.com/cozy-pi/cozysafe'
SITE = 'https://safe.cozypi.com'
UPDATED = '2026-10-19'  # privacy policy date

# Same list and order as Flip Match (lib/i18n.ts NGON_NGU); cozypi.com uses the same codes.
LANGS = [
    ('en', 'English'), ('es', 'Español'), ('pt', 'Português (Brasil)'), ('fr', 'Français'),
    ('de', 'Deutsch'), ('it', 'Italiano'), ('tr', 'Türkçe'), ('ja', '日本語'), ('ko', '한국어'),
    ('zh', '简体中文'), ('zh-TW', '繁體中文'), ('ru', 'Русский'),
    ('id', 'Bahasa Indonesia'), ('th', 'ไทย'), ('vi', 'Tiếng Việt'),
]
IDS = [c for c, _ in LANGS]
HTML_LANG = {'pt': 'pt-BR', 'zh': 'zh-CN'}  # hreflang / <html lang>
# Public URL of each page. Cloudflare serves privacy.html at /privacy (it 307s the .html form),
# so canonical, hreflang and the sitemap use the final address.
PAGES = {'home': '', 'privacy': 'privacy'}


def load():
    def shape(x):
        if isinstance(x, dict):
            return {k: shape(v) for k, v in x.items()}
        if isinstance(x, list):
            return [shape(v) for v in x]
        return sorted(set(re.findall(r'\{[A-Z]+\}|\{p\}|</?[a-z]+', x)))
    texts = {c: json.load(open(os.path.join(HERE, 'i18n', f'{c}.json'), encoding='utf-8')) for c in IDS}
    want = shape(texts['en'])
    for c, t in texts.items():
        if shape(t) != want:
            raise SystemExit(f'i18n/{c}.json: keys, list lengths, placeholders or tags differ from en.json')
    return texts


def path(lang, page):
    return ('/' if lang == 'en' else f'/{lang}/') + PAGES[page]


def head_common(lang, page, css):
    root = '' if lang == 'en' else '../'
    alts = ''.join(f'<link rel="alternate" hreflang="{HTML_LANG.get(c, c)}" href="{SITE}{path(c, page)}">\n' for c in IDS)
    alts += f'<link rel="alternate" hreflang="x-default" href="{SITE}{path("en", page)}">\n'
    # English pages only: send the visitor to their language before anything paints.
    redirect = '' if lang != 'en' else f'''<script>
(function () {{
  var ids = {json.dumps(IDS)}, q = new URLSearchParams(location.search).get('lang'), want = null;
  try {{ if (q && ids.indexOf(q) >= 0) localStorage.setItem('cs.lang', q); want = localStorage.getItem('cs.lang'); }} catch (e) {{}}
  if (q === 'en') return;
  if (!want || ids.indexOf(want) < 0) {{
    want = 'en';
    var ls = navigator.languages || [navigator.language || 'en'];
    for (var i = 0; i < ls.length; i++) {{
      var tag = String(ls[i]).toLowerCase();
      if (/^zh-(hant|tw|hk|mo)\\b/.test(tag)) {{ want = 'zh-TW'; break; }}
      var c = tag.split('-')[0];
      if (ids.indexOf(c) >= 0) {{ want = c; break; }}
    }}
  }}
  if (want !== 'en') location.replace('/' + want + '/{PAGES[page]}' + location.hash);
}})();
</script>
'''
    return (f'<link rel="canonical" href="{SITE}{path(lang, page)}">\n{alts}{redirect}'
            f'<link rel="icon" href="{root}favicon.svg" type="image/svg+xml">\n'
            f'<link rel="apple-touch-icon" href="{root}apple-touch-icon.png">\n'
            f'<link rel="stylesheet" href="{root}style.css?v={css}">')


def lang_menu(lang, page, label):
    opts = ''.join(f'<option value="{path(c, page)}{"?lang=en" if c == "en" else ""}" data-l="{c}"'
                   f'{" selected" if c == lang else ""}>{n}</option>' for c, n in LANGS)
    return (f'<label class="lang"><span class="sr">{label}</span><select onchange="'
            f"try{{localStorage.setItem('cs.lang',this.options[this.selectedIndex].dataset.l)}}catch(e){{}}"
            f'location.href=this.value">{opts}</select></label>')

# Stroke icons (24×24)
I = {
    'lock': '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
    'key': '<circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M17 6l3 3M15 8l2 2"/>',
    'code': '<path d="M8 8l-5 4 5 4M16 8l5 4-5 4M14 4l-4 16"/>',
    'faceid': '<path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2"/><path d="M9 9v1M15 9v1M12 9v4h-1M9 15.5a4 4 0 0 0 6 0"/>',
    'apple': '<path d="M16 3c-1.5.2-3 1.3-3.3 3 1.5.1 3-1 3.3-3zM12.5 7.5c-1 0-2-.7-3.2-.7C7 6.8 5 8.7 5 12c0 3.3 2.2 7.5 4 7.5 1 0 1.6-.6 3-.6s1.9.6 3 .6c1.6 0 3.3-3 3.9-5-1.9-.8-2.8-2.4-2.8-4.2 0-1.5.8-2.8 2-3.5-.8-1.2-2.1-1.8-3.3-1.8-1.3 0-2.2.8-3.3.8z"/>',
    'windows': '<path d="M3 5.5l7.5-1v7H3zM12.5 4.2L21 3v8.5h-8.5zM3 12.5h7.5v7L3 18.5zM12.5 12.5H21V21l-8.5-1.2z"/>',
    'linux': '<path d="M12 3c-2.5 0-3.5 2.5-3.5 5 0 1.5-1.5 3-2.5 5-1 2-1 4 .5 5s2.5 0 3.5 1c.7.6 1.3 1 2 1s1.3-.4 2-1c1-1 2-.1 3.5-1s1.5-3 .5-5-2.5-3.5-2.5-5c0-2.5-1-5-3.5-5z"/><path d="M10.5 8h.01M13.5 8h.01"/>',
    'android': '<path d="M5 10h14v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2z"/><path d="M8 10a4 4 0 0 1 8 0M8 5l1.5 2.5M16 5l-1.5 2.5M3 11v5M21 11v5"/>',
    'iphone': '<rect x="7" y="2.5" width="10" height="19" rx="2.5"/><path d="M11 18.5h2"/>',
    'offline': '<path d="M2 8.8a15 15 0 0 1 4.2-2.6M9.3 5.2A15 15 0 0 1 22 8.8M5 12.5a10 10 0 0 1 3.4-2M15.6 10.5A10 10 0 0 1 19 12.5M8.5 16a5 5 0 0 1 7 0M12 20h.01M3 3l18 18"/>',
    'eye': '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/><path d="M4 20L20 4"/>',
    'backup': '<path d="M12 3v10M8 9l4 4 4-4"/><rect x="4" y="15" width="16" height="6" rx="2"/><path d="M8 18h.01"/>',
    'download': '<path d="M12 4v11M7 10l5 5 5-5"/><path d="M5 20h14"/>',
}


def ic(name, size=24, sw=2):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="{sw}" '
            f'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{I[name]}</svg>')


DIAL = ('<svg viewBox="0 0 1024 1024" aria-hidden="true"><circle class="ring" cx="512" cy="530" r="292" fill="none" stroke-width="60"/>'
        '<circle class="core" cx="512" cy="530" r="112"/><rect x="488" y="168" width="48" height="150" rx="24" fill="#D9A53F"/></svg>')

# Blurred collage of protected items: CSS shapes only, never real data.
COLLAGE = '<div class="collage" aria-hidden="true">' + ''.join(
    f'<i class="{k}"></i>' for k in (['ph', 'doc', 'id', 'rc', 'doc', 'ph', 'id', 'doc', 'rc'] * 5)) + '</div>'

# Screenshots (website/shots.sh renders and converts them): device, screen, display width
# in CSS px. Sizes are the device's window in points (app/test/website_shots_test.dart).
SHOTS = [
    ('iphone', 'lock', 240), ('iphone', 'library', 240), ('iphone', 'notes', 240),
    ('iphone', 'voice', 240), ('iphone', 'group', 240), ('iphone', 'settings', 240),
    ('mac', 'library', 760), ('ipad', 'notes', 360), ('android', 'voice', 200),
]
DEVICE_SIZE = {'iphone': (390, 844), 'android': (412, 915), 'ipad': (820, 1180), 'mac': (1200, 760)}


def shot(device, screen, lang, alt, width):
    """A screenshot in the page's light or dark mode, 1x and 2x."""
    lg = 'vi' if lang == 'vi' else 'en'  # the app speaks English and Vietnamese
    w, h = DEVICE_SIZE[device]
    f = lambda mode, r: f'/img/s/{device}-{screen}-{lg}-{mode}-{r}.webp'
    return (f'<picture><source media="(prefers-color-scheme: dark)" srcset="{f("dark", "1x")} 1x, {f("dark", "2x")} 2x">'
            f'<img src="{f("light", "1x")}" srcset="{f("light", "1x")} 1x, {f("light", "2x")} 2x" '
            f'width="{width}" height="{round(width * h / w)}" alt="{alt}" loading="lazy" decoding="async"></picture>')


PLATFORMS = [
    ('apple', 'macOS', 'CozySafe-macos.dmg', 'mac'),
    ('windows', 'Windows', 'CozySafe-windows-x64.zip', 'win'),
    ('linux', 'Linux', 'CozySafe-linux-x64.tar.gz', 'lin'),
    ('android', 'Android', 'CozySafe-android.apk', 'andr'),
]


def page(lang, texts, css):
    t = {k: (v.replace('{BASE}', BASE).replace('{REPO}', REPO) if isinstance(v, str) else v)
         for k, v in texts[lang]['home'].items()}
    root = '' if lang == 'en' else '../'
    plain = lambda x: re.sub(r'<[^>]+>', '', x).replace('"', '&quot;')
    phones = ''.join(
        f'<figure class="shot"><div class="frame phone">{shot("iphone", s, lang, plain(t["s_" + s]), 240)}</div>'
        f'<figcaption>{t["s_" + s]}</figcaption></figure>'
        for d, s, _ in SHOTS if d == 'iphone')
    devices = ''.join(
        f'<figure class="dev dev-{d}"><div class="frame {d}">{"<i class=lights></i>" if d == "mac" else ""}'
        f'{shot(d, s, lang, plain(t["d_" + d]), w)}</div><figcaption>{t["d_" + d]}</figcaption></figure>'
        for d, s, w in SHOTS if d != 'iphone')
    li = lambda items: ''.join(f'<li>{x}</li>' for x in items)
    cards = ''.join(
        f'<div class="dl"><div class="os">{ic(icon, 30)}{name}</div><p>{t[key]}</p>'
        f'<a class="get" href="{BASE}{f}">{ic("download", 18)}{t["get"]}</a><small title="{f}">{f}</small></div>'
        for icon, name, f, key in PLATFORMS)
    cards += (f'<div class="dl soon"><div class="os">{ic("iphone", 30)}iPhone</div><p>{t["ios"]}</p>'
              f'<span class="get">{t["soon"]}</span><small aria-hidden="true">&nbsp;</small></div>')
    studio = 'https://cozypi.com/' + ('' if lang == 'en' else f'{lang}/')
    return f'''<!doctype html>
<html lang="{HTML_LANG.get(lang, lang)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t['title']}</title>
<meta name="description" content="{t['desc']}">
<meta name="theme-color" content="#0F3D33">
<meta property="og:title" content="{t['title']}">
<meta property="og:description" content="{t['desc']}">
<meta property="og:url" content="{SITE}{path(lang, 'home')}">
<meta property="og:image" content="{SITE}/icon-512.png">
<meta property="og:locale" content="{HTML_LANG.get(lang, lang).replace('-', '_')}">
{head_common(lang, 'home', css)}
</head>
<body>
<header class="hero">
  {COLLAGE}
  <div class="veil"></div>
  <div class="wrap">
    <div class="top">
      <a class="brand" href="./"><img src="{root}icon-512.png" alt="" width="32" height="32">Cozy Safe</a>
      <nav><a class="hide-sm" href="#how">{t['nav_how']}</a><a href="#download">{t['nav_dl']}</a><a class="hide-sm" href="{REPO}">{t['nav_src']}</a></nav>{lang_menu(lang, 'home', texts[lang]['lang_label'])}
    </div>
    <div class="hero-grid">
      <div>
        <h1>{t['h1']}</h1>
        <p class="lead">{t['lead']}</p>
        <div class="cta">
          <a class="btn btn-gold" id="primary" href="#download">{ic('download', 20)}<span>{t['btn']}</span></a>
          <a class="btn btn-ghost" href="{REPO}">{ic('code', 20)}{t['btn_src']}</a>
        </div>
        <ul class="platforms"><li>macOS</li><li>Windows</li><li>Linux</li><li>Android</li><li class="soon">iPhone</li></ul>
      </div>
      <div class="unlock" role="img" aria-label="{t['unlock']}">
        <div class="knob">{DIAL}</div>
        <strong>{t['unlock']}</strong>
        <span class="field">••••••••••••</span>
        <span class="go">{ic('lock', 18)}{t['unlock']}</span>
        <span class="bio">{ic('faceid', 20)}{t['unlock_bio']}</span>
      </div>
    </div>
  </div>
</header>
<main class="wrap">
  <section class="block"><p class="note">{t['note']}</p></section>
  <section class="block" id="tour" aria-labelledby="h-see">
    <h2 id="h-see">{t['h_see']}</h2>
    <p class="section-lead">{t['p_see']}</p>
    <div class="shots">{phones}</div>
    <h3 class="sub">{t['h_dev']}</h3>
    <div class="devices">{devices}</div>
  </section>
  <section class="block" id="how" aria-labelledby="h-how">
    <h2 id="h-how">{t['h_how']}</h2>
    <p class="section-lead">{t['p_how']}</p>
    <div class="features">
      <div class="feat"><div class="ic">{ic('lock', 24)}</div><h3>{t['c1h']}</h3><p>{t['c1p']}</p></div>
      <div class="feat"><div class="ic">{ic('key', 24)}</div><h3>{t['c2h']}</h3><p>{t['c2p']}</p></div>
      <div class="feat"><div class="ic">{ic('offline', 24)}</div><h3>{t['c4h']}</h3><p>{t['c4p']}</p></div>
      <div class="feat"><div class="ic">{ic('eye', 24)}</div><h3>{t['c5h']}</h3><p>{t['c5p']}</p></div>
      <div class="feat"><div class="ic">{ic('backup', 24)}</div><h3>{t['c6h']}</h3><p>{t['c6p']}</p></div>
      <div class="feat"><div class="ic">{ic('code', 24)}</div><h3>{t['c3h']}</h3><p>{t['c3p']}</p></div>
    </div>
  </section>
  <section class="block" aria-labelledby="h-lim">
    <h2 id="h-lim">{t['h_lim']}</h2>
    <div class="limits" style="margin-top:24px">
      <div class="limit"><h3>{t['l1h']}</h3><ul>{li(t['l1'])}</ul></div>
      <div class="limit"><h3>{t['l2h']}</h3><ul>{li(t['l2'])}</ul></div>
    </div>
  </section>
  <section class="block" id="download" aria-labelledby="h-dl">
    <h2 id="h-dl">{t['h_dl']}</h2>
    <p class="section-lead">{t['p_dl']}</p>
    <div class="downloads">{cards}</div>
    <p class="verify">{t['verify']}</p>
  </section>
</main>
<footer>
  <div class="wrap">
    <a class="brand" href="./"><img src="{root}icon-512.png" alt="" width="28" height="28">Cozy Safe</a>
    <span>{t['f_by']} <a href="{studio}">Cozy Pi</a></span>
    <a href="{REPO}">{t['f_src']}</a>
    <span>{t['f_lic']}</span>
    <a href="privacy">{t['f_priv']}</a>
    <a href="mailto:support@cozypi.com">support@cozypi.com</a>
  </div>
</footer>
<script>
// Point the main button at the file for this device; without JS it jumps to the cards.
(function () {{
  var ua = navigator.userAgent, p = null, f = null;
  if (/Android/i.test(ua)) {{ p = 'Android'; f = 'CozySafe-android.apk'; }}
  else if (/iPhone|iPad|iPod/i.test(ua)) {{ return; }}
  else if (/Mac/i.test(ua)) {{ p = 'macOS'; f = 'CozySafe-macos.dmg'; }}
  else if (/Windows/i.test(ua)) {{ p = 'Windows'; f = 'CozySafe-windows-x64.zip'; }}
  else if (/Linux/i.test(ua)) {{ p = 'Linux'; f = 'CozySafe-linux-x64.tar.gz'; }}
  if (!p) return;
  var b = document.getElementById('primary');
  b.href = '{BASE}' + f;
  b.querySelector('span').textContent = {json.dumps(t['btn_for'], ensure_ascii=False)}.replace('{{p}}', p);
}})();
</script>
</body>
</html>
'''


def privacy(lang, texts, css):
    t = texts[lang]['privacy']
    root = '' if lang == 'en' else '../'
    secs = ''.join(f'<h2>{h}</h2>' + ''.join(f'<p>{p}</p>' for p in ps) for h, ps in t['body'])
    return f'''<!doctype html>
<html lang="{HTML_LANG.get(lang, lang)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t['title']}</title>
{head_common(lang, 'privacy', css)}
<style>.doc{{max-width:720px;margin:0 auto;padding:40px 20px 80px}}.doc h1{{font-size:40px;letter-spacing:-.02em;margin:24px 0 4px;hyphens:auto;overflow-wrap:break-word}}.doc h2{{font-size:22px;margin:36px 0 8px}}.doc p{{margin:0 0 12px;color:var(--ink)}}.doc .meta{{color:var(--muted)}}.doc .bar{{display:flex;align-items:center;gap:12px}}.doc .home{{display:inline-flex;align-items:center;gap:8px;font-weight:700;text-decoration:none}}.doc .home img{{width:28px;height:28px;border-radius:8px}}</style>
</head>
<body>
<main class="doc">
<div class="bar"><a class="home" href="./"><img src="{root}icon-512.png" alt="" width="28" height="28">{t['back']}</a>{lang_menu(lang, 'privacy', texts[lang]['lang_label'])}</div>
<h1>{t['h1']}</h1>
<p class="meta">{t['updated'].replace('{DATE}', UPDATED)}</p>
{secs}
</main>
</body>
</html>
'''


def sitemap():
    urls = ''
    for pg in PAGES:
        alts = ''.join(f'<xhtml:link rel="alternate" hreflang="{HTML_LANG.get(c, c)}" href="{SITE}{path(c, pg)}"/>' for c in IDS)
        alts += f'<xhtml:link rel="alternate" hreflang="x-default" href="{SITE}{path("en", pg)}"/>'
        urls += ''.join(f'<url><loc>{SITE}{path(c, pg)}</loc>{alts}</url>\n' for c in IDS)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
            f'xmlns:xhtml="http://www.w3.org/1999/xhtml">\n{urls}</urlset>\n')


if __name__ == '__main__':
    texts = load()
    pub = os.path.join(HERE, 'public')
    # Content hash in the CSS URL: cozypi.com makes browsers keep static files for hours.
    css = hashlib.sha256(open(os.path.join(pub, 'style.css'), 'rb').read()).hexdigest()[:8]
    for c in IDS:
        d = pub if c == 'en' else os.path.join(pub, c)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, 'index.html'), 'w', encoding='utf-8').write(page(c, texts, css))
        open(os.path.join(d, 'privacy.html'), 'w', encoding='utf-8').write(privacy(c, texts, css))
    open(os.path.join(pub, 'sitemap.xml'), 'w').write(sitemap())
    print(f'built {len(IDS)} languages x {len(PAGES)} pages + sitemap.xml')
