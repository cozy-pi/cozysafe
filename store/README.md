# Store listing

The text of both stores' pages lives in `store/text/<lang>.json`, one file per language of
the app: `name` (30), `subtitle` (App Store, 30), `promo` (App Store promotional text, 170),
`keywords` (App Store, 100), `short` (Google Play short description, 80), `description`
(4000) and `whats_new`. English is the source; every claim in it is checked against
README.md ("What works today"). Change the app, change the English, then the others.

    tools/check-store-text        every language there, inside the limits, same layout
    gh workflow run store-text.yml -R cozy-pi/cozysafe [-f write=true]    to App Store Connect

Both stores carry the same name and the same description.

## Shared

- Category: Productivity (secondary on the App Store: Utilities)
- Price: free, no in-app purchases, no ads
- Privacy policy: https://safe.cozypi.com/privacy
- Support URL: https://safe.cozypi.com/feedback
- Marketing URL: https://safe.cozypi.com
- Contact email: support@cozypi.com
- Copyright: `2026 Cozy Pi`

## Screenshots, in this order (app/test/store, see docs/release-public.md)

1. `notes` · 2. `files` · 3. `voice` · 4. `library` · 5. `lock` · 6. `settings`
(`group` is not used: groups are hidden in this version.)

## App Review notes (App Store)

```
Cozy Safe needs no account and no sign-in: open the app, choose "Private", and follow the steps to make a vault (the app shows 24 words, then asks for a vault password). Everything is stored encrypted on the device.

Optional features that use the network, both off until the user turns them on:
- Sync with another device on the same Wi-Fi (local network permission).
- Sync through the user's own Google Drive (Google sign-in, drive.file scope). This is optional and can be tried with any Google account; the app has no server of its own.

Camera, microphone and photo library are used only when the user adds a photo, a video, a voice memo or scans a two-factor QR code. The app is open source: https://github.com/cozy-pi/cozysafe
```

## Privacy answers

- App Store "App Privacy": Data Not Collected.
- Google Play "Data safety": no data collected, no data shared. Data is encrypted in
  transit (sync). Files a user syncs go to the user's own Google Drive, not to the developer.
- Encryption (export compliance): docs/export-compliance.md.
