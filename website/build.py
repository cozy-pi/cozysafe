#!/usr/bin/env python3
"""Build safe.cozypi.com: public/index.html (English) and public/vi/index.html.

Edit the copy in TEXT below, then run `python3 website/build.py` and deploy with
`npx wrangler deploy` from website/. Screenshots live in public/img/ and are
produced by the app's screenshot test on CI (see app/test/screenshots_test.dart).
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = 'https://github.com/itlboy/cozysafe/releases/latest/download/'
REPO = 'https://github.com/itlboy/cozysafe'

TEXT = {
    'en': dict(
        title='Cozy Safe: an open-source encrypted vault',
        desc='Cozy Safe keeps your notes, documents and photos encrypted on your own device. Free and open source, for macOS, Windows, Linux and Android.',
        nav_dl='Download', nav_src='Source code',
        h1='A private vault for your notes, documents and photos.',
        lead='Everything is encrypted on your device before it is saved or synced. Without your password, nobody can open it, including us.',
        btn='Download', btn_for='Download for {p}',
        also='Free and open source. For macOS, Windows, Linux and Android; iPhone is coming soon.',
        note='<strong>This is an early preview.</strong> You can create, unlock and lock vaults. Notes, files, photos and sync arrive in later releases, so don\'t keep the only copy of anything important here yet.',
        hero_alt='The Cozy Safe unlock screen on a phone',
        h_shots='On your phone and your computer',
        p_shots='The same app on every device, in light or dark to match your system.',
        cap_phone='Creating a vault: the password must be strong before you can continue.',
        cap_desk='The desktop app in dark mode.',
        cap_desk2='On a computer: one password field, no list of vaults.',
        h_how='How Cozy Safe keeps you safe',
        c1h='Encrypted on your device', c1p='Data is encrypted before it reaches the disk or a cloud folder. Sync only ever sends encrypted data.',
        c2h='Password plus Secret Key', c2p='Your password is combined with a random 128-bit key kept on your device, so someone holding a copy of your vault still cannot guess the password.',
        c3h='Open source', c3p='Anyone can read and check the code (GPL-3.0). Installers are built by GitHub, with provenance you can verify.',
        h_lim='Good to know first',
        l1h='There is no recovery', l1=['If you forget the password, nobody can open the vault again, including us.', 'Choose a password you will remember, such as a phrase of several words.'],
        l2h='What it cannot do', l2=['It cannot protect a device that already has malware.', 'Others can still see that Cozy Safe is installed.', 'Anyone who knows the password can open the vault.'],
        h_dl='Download', th_p='Platform', th_f='File', th_h='How to install',
        mac_h='Signed and notarized by Apple. Open the disk image and drag Cozy Safe into Applications.',
        win_h='Not signed yet. Unzip it and run <code>cozysafe.exe</code>. If SmartScreen warns you, choose More info, then Run anyway.',
        lin_h='Extract it and run <code>./cozysafe</code>. Needs GTK 3.',
        and_h='Signed with the Cozy Pi release key. When Android asks, allow your browser to install apps.',
        ios_f='Coming soon', ios_h='Through TestFlight, Apple\'s app for testing new apps.',
        verify=f'To check a download, compare it with <a href="{BASE}SHA256SUMS.txt">SHA256SUMS.txt</a> or run <code>gh attestation verify &lt;file&gt; -R itlboy/cozysafe</code>. Older versions are on the <a href="{REPO}/releases">releases page</a>.',
        f_by='Made by', f_src='Source code', f_lic='GPL-3.0',
    ),
    'vi': dict(
        title='Cozy Safe: két mã hoá mã nguồn mở',
        desc='Cozy Safe giữ ghi chú, giấy tờ và ảnh của bạn được mã hoá ngay trên máy. Miễn phí, mã nguồn mở, có cho macOS, Windows, Linux và Android.',
        nav_dl='Tải về', nav_src='Mã nguồn',
        h1='Két riêng cho ghi chú, giấy tờ và ảnh của bạn.',
        lead='Mọi thứ được mã hoá ngay trên máy trước khi lưu hay đồng bộ. Không có mật khẩu của bạn thì không ai mở được, kể cả chúng tôi.',
        btn='Tải về', btn_for='Tải cho {p}',
        also='Miễn phí và mã nguồn mở. Có cho macOS, Windows, Linux và Android; iPhone sắp ra mắt.',
        note='<strong>Đây là bản thử nghiệm sớm.</strong> Bạn đã tạo két, mở và khoá két được. Ghi chú, file, ảnh và đồng bộ sẽ có ở các bản sau, nên tạm thời đừng cất bản duy nhất của thứ gì quan trọng vào đây.',
        hero_alt='Màn mở khoá của Cozy Safe trên điện thoại',
        h_shots='Trên điện thoại và máy tính',
        p_shots='Cùng một app trên mọi thiết bị, sáng hay tối theo máy của bạn.',
        cap_phone='Tạo két: mật khẩu phải đủ mạnh thì mới đi tiếp được.',
        cap_desk='Bản máy tính ở giao diện tối.',
        cap_desk2='Trên máy tính: một ô mật khẩu, không có danh sách két.',
        h_how='Cozy Safe giữ an toàn cho bạn thế nào',
        c1h='Mã hoá ngay trên máy', c1p='Dữ liệu được mã hoá trước khi ghi xuống ổ đĩa hay thư mục cloud. Khi đồng bộ, thứ được gửi đi chỉ là dữ liệu đã mã hoá.',
        c2h='Mật khẩu cộng Secret Key', c2p='Mật khẩu được kết hợp với một khoá ngẫu nhiên 128 bit cất trên máy bạn, nên kẻ có bản sao két cũng không dò ra được mật khẩu.',
        c3h='Mã nguồn công khai', c3p='Ai cũng đọc và kiểm tra được mã nguồn (giấy phép GPL-3.0). Bản cài do GitHub build, có chứng thực nguồn gốc.',
        h_lim='Những điều nên biết trước',
        l1h='Không có cách khôi phục', l1=['Quên mật khẩu thì không ai mở lại được két, kể cả chúng tôi.', 'Hãy chọn mật khẩu bạn nhớ được, chẳng hạn một câu gồm vài từ.'],
        l2h='Những gì app không làm được', l2=['Không bảo vệ được máy đã nhiễm mã độc.', 'Người khác vẫn thấy máy bạn có cài Cozy Safe.', 'Ai biết mật khẩu thì mở được két.'],
        h_dl='Tải về', th_p='Nền tảng', th_f='File', th_h='Cách cài',
        mac_h='Đã ký và được Apple kiểm duyệt. Mở file, kéo Cozy Safe vào thư mục Applications.',
        win_h='Chưa ký. Giải nén rồi chạy <code>cozysafe.exe</code>. Nếu SmartScreen cảnh báo, chọn "Thông tin thêm" rồi "Vẫn chạy".',
        lin_h='Giải nén rồi chạy <code>./cozysafe</code>. Cần GTK 3.',
        and_h='Ký bằng khoá phát hành của Cozy Pi. Khi Android hỏi, cho phép trình duyệt cài ứng dụng.',
        ios_f='Sắp có', ios_h='Qua TestFlight, ứng dụng của Apple để dùng thử app mới.',
        verify=f'Muốn kiểm file tải về, so với <a href="{BASE}SHA256SUMS.txt">SHA256SUMS.txt</a> hoặc chạy <code>gh attestation verify &lt;file&gt; -R itlboy/cozysafe</code>. Các phiên bản cũ ở <a href="{REPO}/releases">trang phát hành</a>.',
        f_by='Làm bởi', f_src='Mã nguồn', f_lic='GPL-3.0',
    ),
}

FILES = [('macOS', 'CozySafe-macos.dmg', 'mac_h'), ('Windows', 'CozySafe-windows-x64.zip', 'win_h'),
         ('Linux', 'CozySafe-linux-x64.tar.gz', 'lin_h'), ('Android', 'CozySafe-android.apk', 'and_h')]

LOGO = ('<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
        'stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.2"/>'
        '<path d="M12 3v3.2"/></svg>')


def dial():
    ticks = []
    for i in range(60):
        a = math.radians(i * 6)
        r1, r2 = (140 if i % 5 == 0 else 150), 160
        ticks.append(f'<line x1="{170 + r1 * math.sin(a):.1f}" y1="{170 - r1 * math.cos(a):.1f}" '
                     f'x2="{170 + r2 * math.sin(a):.1f}" y2="{170 - r2 * math.cos(a):.1f}" '
                     f'stroke-width="{2.5 if i % 5 == 0 else 1.2}"/>')
    return ('<svg class="dial" viewBox="0 0 340 340" fill="none" stroke="currentColor" stroke-linecap="round" aria-hidden="true">'
            + ''.join(ticks) + '<circle cx="170" cy="170" r="122" stroke-width="1.5"/>'
            '<path class="mark" d="M170 4v22" stroke-width="5"/>'
            '<circle class="face" cx="170" cy="170" r="94" stroke-width="1.5"/>'
            '<g class="lock" stroke-width="7" stroke-linejoin="round"><rect x="138" y="166" width="64" height="48" rx="9"/>'
            '<path d="M152 166v-14a18 18 0 0 1 36 0v14"/><path d="M170 182v14"/></g></svg>')


BAR = '<div class="bar" aria-hidden="true"><i></i><i></i><i></i></div>'


def img(root, lang, key, w, h, alt, cls='', eager=False):
    """A screenshot rendered by app/test/screenshots_test.dart, 1x and 2x."""
    base = f'{root}img/{lang}-{key}'
    lazy = '' if eager else ' loading="lazy"'
    return (f'<img class="{cls}" src="{base}-1x.webp" srcset="{base}-1x.webp 1x, {base}-2x.webp 2x" '
            f'width="{w}" height="{h}" alt="{alt}"{lazy}>')


def shots(t, lang, root):
    return f'''<section class="shots" aria-labelledby="shots">
  <h2 id="shots">{t['h_shots']}</h2>
  <p class="section-lead">{t['p_shots']}</p>
  <div class="shots-row">
    <figure class="phone-fig">{img(root, lang, 'create', 260, 563, t['cap_phone'], 'phone')}<figcaption>{t['cap_phone']}</figcaption></figure>
    <figure class="desk-fig"><div class="window light">{BAR}{img(root, lang, 'desktop-unlock', 720, 450, t['cap_desk2'])}</div><figcaption>{t['cap_desk2']}</figcaption></figure>
  </div>
</section>
'''


def page(lang):
    t = TEXT[lang]
    root, other, other_label, other_lang = ('', '/vi/', 'Tiếng Việt', 'vi') if lang == 'en' else ('../', '/', 'English', 'en')
    rows = ''.join(f'<tr><td>{p}</td><td><a class="get" href="{BASE}{f}">{f}</a></td><td class="how">{t[h]}</td></tr>'
                   for p, f, h in FILES)
    rows += f'<tr><td>iPhone</td><td>{t["ios_f"]}</td><td class="how">{t["ios_h"]}</td></tr>'
    li = lambda items: ''.join(f'<li>{x}</li>' for x in items)
    studio = 'https://cozypi.com/' + ('' if lang == 'en' else 'vi/')
    return f'''<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t['title']}</title>
<meta name="description" content="{t['desc']}">
<link rel="canonical" href="https://safe.cozypi.com/{'' if lang == 'en' else 'vi/'}">
<link rel="alternate" hreflang="en" href="https://safe.cozypi.com/">
<link rel="alternate" hreflang="vi" href="https://safe.cozypi.com/vi/">
<link rel="icon" href="{root}favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}style.css">
</head>
<body>
<div class="wrap">
<header class="top">
  <a class="brand" href="./">{LOGO}Cozy Safe</a>
  <nav><a href="#download">{t['nav_dl']}</a><a href="{REPO}">{t['nav_src']}</a><a href="{other}" hreflang="{other_lang}">{other_label}</a></nav>
</header>
<main>
<div class="hero">
  <div>
    <h1>{t['h1']}</h1>
    <p class="lead">{t['lead']}</p>
    <a class="btn" id="primary" href="#download">{t['btn']}</a>
    <p class="also">{t['also']}</p>
    <ul class="platforms" aria-label="{t['nav_dl']}"><li>macOS</li><li>Windows</li><li>Linux</li><li>Android</li><li class="soon">iPhone</li></ul>
  </div>
  <div class="hero-art">
    <div class="window">{BAR}{img(root, lang, 'desktop-create-dark', 720, 450, t['cap_desk'], eager=True)}</div>
    {img(root, lang, 'unlock', 260, 563, t['hero_alt'], 'phone', eager=True)}
  </div>
</div>
<p class="note">{t['note']}</p>
{shots(t, lang, root)}<section aria-labelledby="how"><h2 id="how">{t['h_how']}</h2>
<div class="cols">
  <div><h3>{t['c1h']}</h3><p>{t['c1p']}</p></div>
  <div><h3>{t['c2h']}</h3><p>{t['c2p']}</p></div>
  <div><h3>{t['c3h']}</h3><p>{t['c3p']}</p></div>
</div></section>
<section aria-labelledby="limits"><h2 id="limits">{t['h_lim']}</h2>
<div class="limits">
  <div><h3>{t['l1h']}</h3><ul>{li(t['l1'])}</ul></div>
  <div><h3>{t['l2h']}</h3><ul>{li(t['l2'])}</ul></div>
</div></section>
<section id="download" aria-labelledby="dl"><h2 id="dl">{t['h_dl']}</h2>
<table class="dl"><thead><tr><th>{t['th_p']}</th><th>{t['th_f']}</th><th>{t['th_h']}</th></tr></thead>
<tbody>{rows}</tbody></table>
<p class="verify">{t['verify']}</p>
</section>
</main>
<footer><span>{t['f_by']} <a href="{studio}">Cozy Pi</a></span><a href="{REPO}">{t['f_src']}</a><span>{t['f_lic']}</span><a href="mailto:support@cozypi.com">support@cozypi.com</a></footer>
</div>
<script>
// Point the main button at the file for this device; without JS it jumps to the table.
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
  b.textContent = {t['btn_for']!r}.replace('{{p}}', p);
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
