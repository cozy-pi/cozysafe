#!/usr/bin/env python3
"""Build safe.cozypi.com: public/index.html (English) and public/vi/index.html.

Style follows the app's unlock screen (docs/ui.md, design "B2"): vault green,
blurred protected items behind, gold index. The unlock card in the hero is an
HTML illustration of the design, not a screenshot. Edit the copy in TEXT, run
`python3 website/build.py`, deploy with `npx wrangler deploy` from website/.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = 'https://github.com/cozy-pi/cozysafe/releases/latest/download/'
REPO = 'https://github.com/cozy-pi/cozysafe'

TEXT = {
    'en': dict(
        title='Cozy Safe: an open-source encrypted vault',
        desc='Cozy Safe keeps your notes, documents and photos encrypted on your own device. Free and open source, for macOS, Windows, Linux and Android.',
        nav_how='How it works', nav_dl='Download', nav_src='Source code',
        h1='A private vault for your notes, documents and photos.',
        lead='Everything is encrypted on your device before it is saved or synced. Without your password, nobody can open it, including us.',
        btn='Download', btn_for='Download for {p}', btn_src='View the source',
        unlock='Unlock', unlock_bio='Unlock with Face ID',
        note='<strong>Early preview.</strong> You can create, unlock and lock vaults. Notes, files, photos and sync arrive in later releases, so don\'t keep the only copy of anything important here yet.',
        h_how='How Cozy Safe keeps you safe', p_how='Your data never leaves your device unencrypted, and the code that does it is public.',
        c1h='Encrypted on your device', c1p='Data is encrypted before it reaches the disk or a cloud folder. Sync only ever sends encrypted data.',
        c2h='Password plus Secret Key', c2p='Your password is combined with a random 128-bit key kept on your device, so someone holding a copy of your vault still cannot guess the password.',
        c3h='Open source', c3p='Anyone can read and check the code (GPL-3.0). Installers are built by GitHub, with provenance you can verify.',
        h_lim='Good to know first',
        l1h='There is no recovery', l1=['If you forget the password, nobody can open the vault again, including us.', 'Choose a password you will remember, such as a phrase of several words.'],
        l2h='What it cannot do', l2=['It cannot protect a device that already has malware.', 'Others can still see that Cozy Safe is installed.', 'Anyone who knows the password can open the vault.'],
        h_dl='Download', p_dl='Free, no account needed.',
        mac='Signed and notarized by Apple. Open the disk image and drag Cozy Safe into Applications.',
        win='Not signed yet: if SmartScreen warns you, choose More info, then Run anyway.',
        lin='Extract and run <code>./cozysafe</code>. Needs GTK 3.',
        andr='Signed with the Cozy Pi key. When Android asks, allow your browser to install apps.',
        ios='Coming soon through TestFlight, Apple\'s app for testing new apps.',
        get='Download', soon='Coming soon',
        verify=f'To check a download, compare it with <a href="{BASE}SHA256SUMS.txt">SHA256SUMS.txt</a> or run <code>gh attestation verify &lt;file&gt; -R cozy-pi/cozysafe</code>. Older versions are on the <a href="{REPO}/releases">releases page</a>.',
        f_by='Made by', f_src='Source code', f_lic='GPL-3.0', f_priv='Privacy',
    ),
    'vi': dict(
        title='Cozy Safe: két mã hoá mã nguồn mở',
        desc='Cozy Safe giữ ghi chú, giấy tờ và ảnh của bạn được mã hoá ngay trên máy. Miễn phí, mã nguồn mở, có cho macOS, Windows, Linux và Android.',
        nav_how='Cách hoạt động', nav_dl='Tải về', nav_src='Mã nguồn',
        h1='Két riêng cho ghi chú, giấy tờ và ảnh của bạn.',
        lead='Mọi thứ được mã hoá ngay trên máy trước khi lưu hay đồng bộ. Không có mật khẩu của bạn thì không ai mở được, kể cả chúng tôi.',
        btn='Tải về', btn_for='Tải cho {p}', btn_src='Xem mã nguồn',
        unlock='Mở két', unlock_bio='Mở bằng Face ID',
        note='<strong>Bản thử nghiệm sớm.</strong> Bạn đã tạo két, mở và khoá két được. Ghi chú, file, ảnh và đồng bộ sẽ có ở các bản sau, nên tạm thời đừng cất bản duy nhất của thứ gì quan trọng vào đây.',
        h_how='Cozy Safe giữ an toàn cho bạn thế nào', p_how='Dữ liệu không bao giờ rời máy ở dạng chưa mã hoá, và đoạn mã làm việc đó ai cũng đọc được.',
        c1h='Mã hoá ngay trên máy', c1p='Dữ liệu được mã hoá trước khi ghi xuống ổ đĩa hay thư mục cloud. Khi đồng bộ, thứ được gửi đi chỉ là dữ liệu đã mã hoá.',
        c2h='Mật khẩu cộng Secret Key', c2p='Mật khẩu được kết hợp với một khoá ngẫu nhiên 128 bit cất trên máy bạn, nên kẻ có bản sao két cũng không dò ra được mật khẩu.',
        c3h='Mã nguồn công khai', c3p='Ai cũng đọc và kiểm tra được mã nguồn (giấy phép GPL-3.0). Bản cài do GitHub build, có chứng thực nguồn gốc.',
        h_lim='Những điều nên biết trước',
        l1h='Không có cách khôi phục', l1=['Quên mật khẩu thì không ai mở lại được két, kể cả chúng tôi.', 'Hãy chọn mật khẩu bạn nhớ được, chẳng hạn một câu gồm vài từ.'],
        l2h='Những gì app không làm được', l2=['Không bảo vệ được máy đã nhiễm mã độc.', 'Người khác vẫn thấy máy bạn có cài Cozy Safe.', 'Ai biết mật khẩu thì mở được két.'],
        h_dl='Tải về', p_dl='Miễn phí, không cần tài khoản.',
        mac='Đã ký và được Apple kiểm duyệt. Mở file, kéo Cozy Safe vào thư mục Applications.',
        win='Chưa ký: nếu SmartScreen cảnh báo, chọn "Thông tin thêm" rồi "Vẫn chạy".',
        lin='Giải nén rồi chạy <code>./cozysafe</code>. Cần GTK 3.',
        andr='Ký bằng khoá của Cozy Pi. Khi Android hỏi, cho phép trình duyệt cài ứng dụng.',
        ios='Sắp có qua TestFlight, ứng dụng của Apple để dùng thử app mới.',
        get='Tải về', soon='Sắp có',
        verify=f'Muốn kiểm file tải về, so với <a href="{BASE}SHA256SUMS.txt">SHA256SUMS.txt</a> hoặc chạy <code>gh attestation verify &lt;file&gt; -R cozy-pi/cozysafe</code>. Các phiên bản cũ ở <a href="{REPO}/releases">trang phát hành</a>.',
        f_by='Làm bởi', f_src='Mã nguồn', f_lic='GPL-3.0', f_priv='Quyền riêng tư',
    ),
}

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

PLATFORMS = [
    ('apple', 'macOS', 'CozySafe-macos.dmg', 'mac'),
    ('windows', 'Windows', 'CozySafe-windows-x64.zip', 'win'),
    ('linux', 'Linux', 'CozySafe-linux-x64.tar.gz', 'lin'),
    ('android', 'Android', 'CozySafe-android.apk', 'andr'),
]


def page(lang):
    t = TEXT[lang]
    root, other, other_label, other_lang = ('', '/vi/', 'Tiếng Việt', 'vi') if lang == 'en' else ('../', '/', 'English', 'en')
    li = lambda items: ''.join(f'<li>{x}</li>' for x in items)
    cards = ''.join(
        f'<div class="dl"><div class="os">{ic(icon, 30)}{name}</div><p>{t[key]}</p>'
        f'<a class="get" href="{BASE}{f}">{ic("download", 18)}{t["get"]}</a><small>{f}</small></div>'
        for icon, name, f, key in PLATFORMS)
    cards += (f'<div class="dl soon"><div class="os">{ic("iphone", 30)}iPhone</div><p>{t["ios"]}</p>'
              f'<span class="get">{t["soon"]}</span></div>')
    studio = 'https://cozypi.com/' + ('' if lang == 'en' else 'vi/')
    return f'''<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t['title']}</title>
<meta name="description" content="{t['desc']}">
<meta name="theme-color" content="#0F3D33">
<link rel="canonical" href="https://safe.cozypi.com/{'' if lang == 'en' else 'vi/'}">
<link rel="alternate" hreflang="en" href="https://safe.cozypi.com/">
<link rel="alternate" hreflang="vi" href="https://safe.cozypi.com/vi/">
<link rel="icon" href="{root}favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="{root}apple-touch-icon.png">
<link rel="stylesheet" href="{root}style.css">
</head>
<body>
<header class="hero">
  {COLLAGE}
  <div class="veil"></div>
  <div class="wrap">
    <div class="top">
      <a class="brand" href="./"><img src="{root}icon-512.png" alt="" width="32" height="32">Cozy Safe</a>
      <nav><a class="hide-sm" href="#how">{t['nav_how']}</a><a href="#download">{t['nav_dl']}</a><a class="hide-sm" href="{REPO}">{t['nav_src']}</a><a href="{other}" hreflang="{other_lang}">{other_label}</a></nav>
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
  <section class="block" id="how" aria-labelledby="h-how">
    <h2 id="h-how">{t['h_how']}</h2>
    <p class="section-lead">{t['p_how']}</p>
    <div class="features">
      <div class="feat"><div class="ic">{ic('lock', 24)}</div><h3>{t['c1h']}</h3><p>{t['c1p']}</p></div>
      <div class="feat"><div class="ic">{ic('key', 24)}</div><h3>{t['c2h']}</h3><p>{t['c2p']}</p></div>
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
    <a href="privacy.html">{t['f_priv']}</a>
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
  b.querySelector('span').textContent = {t['btn_for']!r}.replace('{{p}}', p);
}})();
</script>
</body>
</html>
'''


if __name__ == '__main__':
    os.makedirs(os.path.join(HERE, 'public', 'vi'), exist_ok=True)
    with open(os.path.join(HERE, 'public', 'index.html'), 'w') as f:
        f.write(page('en'))
    with open(os.path.join(HERE, 'public', 'vi', 'index.html'), 'w') as f:
        f.write(page('vi'))
    print('built public/index.html and public/vi/index.html')
