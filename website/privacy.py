#!/usr/bin/env python3
"""Privacy policy pages: public/privacy.html (en) and public/vi/privacy.html.

Keep in sync with what the app and site actually do. If the app ever sends
anything anywhere, update this page and the Google Play Data safety form."""
import os
HERE = os.path.dirname(os.path.abspath(__file__))
UPDATED = '2026-10-19'

T = {
 'en': dict(title='Privacy policy · Cozy Safe', h1='Privacy policy', updated=f'Last updated {UPDATED}', back='Cozy Safe',
  body=[
   ('In short', ['Cozy Safe does not collect, send or sell any of your data. There is no account, no analytics, no advertising and no tracking in the app.', 'Everything you put in a vault is encrypted on your device. We cannot read it and we have no copy of it.']),
   ('What stays on your device', ['Your vaults, notes, files and photos, always encrypted with keys derived from your password and Secret Key.', 'App settings such as language and light or dark mode.']),
   ('Where your data can go, only if you choose', ['Sync and backup use a folder or device you pick (for example iCloud Drive, Google Drive, Dropbox, or another device on your network). Only encrypted data is written there; the provider you choose cannot read it.', 'If you turn on Secret Key sync, the Secret Key is stored in your platform\'s end-to-end encrypted password store (iCloud Keychain or Google Password Manager), under that provider\'s privacy terms.', 'When you share, export or open an item in another app, that app receives an unencrypted copy and handles it under its own terms.']),
   ('Permissions', ['Camera: only to take photos straight into a vault, when you open the camera. Photos are not saved to your photo library.', 'Biometrics: only if you turn on Face ID, Touch ID or fingerprint unlock. Your biometric data never leaves the device\'s secure hardware and is never available to the app.']),
   ('This website', ['safe.cozypi.com is a set of static pages served by Cloudflare. It sets no cookies and runs no analytics. Cloudflare may keep standard technical logs (such as IP address) for security, under its own privacy policy. Downloads are served by GitHub.']),
   ('Children', ['Cozy Safe is not directed at children under 13 and collects no data from anyone.']),
   ('Changes and contact', ['If this policy changes, the new version will be published on this page with a new date.', 'Questions: <a href="mailto:support@cozypi.com">support@cozypi.com</a>. Cozy Safe is made by Cozy Pi, an independent studio, and its source code is public at <a href="https://github.com/cozy-pi/cozysafe">github.com/cozy-pi/cozysafe</a>.']),
  ]),
 'vi': dict(title='Chính sách quyền riêng tư · Cozy Safe', h1='Chính sách quyền riêng tư', updated=f'Cập nhật ngày {UPDATED}', back='Cozy Safe',
  body=[
   ('Tóm tắt', ['Cozy Safe không thu thập, không gửi đi và không bán bất kỳ dữ liệu nào của bạn. App không có tài khoản, không có công cụ phân tích, không quảng cáo, không theo dõi.', 'Mọi thứ bạn cất vào két đều được mã hoá ngay trên máy. Chúng tôi không đọc được và không giữ bản sao nào.']),
   ('Những gì nằm trên máy bạn', ['Két, ghi chú, file và ảnh, luôn được mã hoá bằng khoá suy ra từ mật khẩu và Secret Key của bạn.', 'Cài đặt của app như ngôn ngữ, giao diện sáng hay tối.']),
   ('Dữ liệu chỉ đi ra ngoài khi bạn chọn', ['Đồng bộ và sao lưu dùng thư mục hoặc thiết bị do bạn chọn (ví dụ iCloud Drive, Google Drive, Dropbox, hay máy khác trong mạng nhà). Chỉ dữ liệu đã mã hoá được ghi ra đó; nhà cung cấp bạn chọn không đọc được.', 'Nếu bạn bật đồng bộ Secret Key, khoá được lưu trong kho mật khẩu mã hoá đầu-cuối của hệ điều hành (iCloud Keychain hoặc Google Password Manager), theo điều khoản riêng tư của nhà cung cấp đó.', 'Khi bạn chia sẻ, xuất hay mở một mục bằng app khác, app đó nhận bản không mã hoá và xử lý theo điều khoản của họ.']),
   ('Quyền truy cập', ['Camera: chỉ để chụp ảnh thẳng vào két, khi bạn mở camera. Ảnh không lưu vào thư viện ảnh của máy.', 'Sinh trắc học: chỉ khi bạn bật mở khoá bằng Face ID, Touch ID hoặc vân tay. Dữ liệu sinh trắc học không rời phần cứng bảo mật của máy và app không bao giờ truy cập được.']),
   ('Trang web này', ['safe.cozypi.com là các trang tĩnh do Cloudflare phục vụ, không đặt cookie, không chạy công cụ phân tích. Cloudflare có thể giữ nhật ký kỹ thuật thông thường (như địa chỉ IP) để bảo mật, theo chính sách riêng tư của họ. File tải về do GitHub phục vụ.']),
   ('Trẻ em', ['Cozy Safe không hướng tới trẻ em dưới 13 tuổi và không thu thập dữ liệu của bất kỳ ai.']),
   ('Thay đổi và liên hệ', ['Nếu chính sách thay đổi, bản mới sẽ đăng tại trang này kèm ngày cập nhật.', 'Thắc mắc: <a href="mailto:support@cozypi.com">support@cozypi.com</a>. Cozy Safe do Cozy Pi, một studio độc lập, làm ra; mã nguồn công khai tại <a href="https://github.com/cozy-pi/cozysafe">github.com/cozy-pi/cozysafe</a>.']),
  ]),
}

def page(lang):
    t = T[lang]; root = '' if lang == 'en' else '../'
    secs = ''.join(f'<h2>{h}</h2>' + ''.join(f'<p>{p}</p>' for p in ps) for h, ps in t['body'])
    return f'''<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t['title']}</title>
<link rel="alternate" hreflang="en" href="https://safe.cozypi.com/privacy.html">
<link rel="alternate" hreflang="vi" href="https://safe.cozypi.com/vi/privacy.html">
<link rel="icon" href="{root}favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{root}style.css">
<style>.doc{{max-width:720px;margin:0 auto;padding:40px 20px 80px}}.doc h1{{font-size:40px;letter-spacing:-.02em;margin:24px 0 4px}}.doc h2{{font-size:22px;margin:36px 0 8px}}.doc p{{margin:0 0 12px;color:var(--ink)}}.doc .meta{{color:var(--muted)}}.doc .home{{display:inline-flex;align-items:center;gap:8px;font-weight:700;text-decoration:none}}.doc .home img{{width:28px;height:28px;border-radius:8px}}</style>
</head>
<body>
<main class="doc">
<a class="home" href="./"><img src="{root}icon-512.png" alt="" width="28" height="28">{t['back']}</a>
<h1>{t['h1']}</h1>
<p class="meta">{t['updated']}</p>
{secs}
</main>
</body>
</html>
'''
for lang, path in [('en', 'public/privacy.html'), ('vi', 'public/vi/privacy.html')]:
    open(os.path.join(HERE, path), 'w').write(page(lang))
print('privacy ok')
