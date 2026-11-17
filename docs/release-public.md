# Public release: the steps

Version 1.0.0, from `main`, to the App Store and Google Play production. Nothing here
is sent to a store without the owner saying so on the day. Listing text: `store/` (store/README.md).

## Where it stands (2026-11-17)

Done:
- 1.0.0 (build 1178), 1.0.1 (1180: Android save-to-file and picker fixes) and 1.0.2 (1181:
  icons-only vault bar) are on TestFlight, Play internal + alpha and GitHub releases.
- App Store: **1.0.1, build 1180, submitted 2026-11-17, Waiting for Review**, manual release.
  Free; App Privacy "Data Not Collected"; age 4+; no third-party content; review contact set.
  Availability: 174 countries, every one except France (China mainland left in on purpose
  to see what Apple does: it needs a Security Assessment and an AIGC declaration, see below).
- Google Play: closed test finished; production access applied for 2026-11-17 (Google
  answers by email, usually within 7 days).
- France: encryption declaration filed with ANSSI 2026-11-17 (docs/export-compliance.md).

To do:
- [ ] Apple's answer. Rejected over China mainland → untick it in Pricing and Availability
      and submit again. Approved → send 1.0.2 (or later) as the first update.
- [ ] Google grants production access → owner says go → `play-production.yml` with the
      newest build (1181 today).
- [ ] Both approved → step 6 (release, website `LIVE = True`).
- [ ] ANSSI answer, or one month of silence (about 2026-12-17) → France: receipt to App
      Store Connect, `ITSAppUsesNonExemptEncryption` per docs/export-compliance.md, tick France.
- [ ] China mainland for good: Security Assessment + AIGC declaration (App Compliance in
      App Store Connect), or leave it out.
- [ ] EU trader status (App Store Connect → Business; Play → App content): not checked yet.
- [ ] `cozypi.com/.well-known/assetlinks.json` is 404 (Android password managers do not
      link the app to the site).
- [ ] Dependabot: 7 alerts, all in `tools/semgrep-requirements.txt` (a CI tool, not the app).

## 0. Before the day

- [x] Google Play: the closed test has run 14 days with 12 testers (Dashboard shows the count).
- [ ] Google Play → App content: seller (trader) status declared. Shown publicly: the owner fills it in.
- [ ] Sample photos in `app/test/preview_assets/*.jpg` (free photos, not in git): the
      `library` screenshot needs them. Twelve square ones are enough, for example
      `https://picsum.photos/id/<n>/1200/1200.jpg` (Unsplash licence).
- [x] `beta` branch's CI changes merged into `main` (Cozy Safe Beta keeps working after 1.0.0).

## 1. Code, on a branch, merged to `main`

- [x] `app/pubspec.yaml`: `version: 1.0.0+1`. release.yml starts a new line at X.Y.0, so
      the next release is named 1.0.0.
- [x] `README.md`: the "Status: preview" note. The website keeps "Preview" and "invite
      only" until `LIVE = True` in `website/build.py` (step 6): both are true until then.
- [x] `.github/workflows/build.yml`, job `release`: the title "(preview)" and the notes
      "Preview build for testing".
- [x] `CHANGELOG.md`: `## 1.0.0 (date)`.
- [x] `flutter gen-l10n && flutter analyze --fatal-infos && flutter test`; `ci` green on main.

## 2. Build

    gh workflow run release.yml -R cozy-pi/cozysafe

Test sign-in (a button that opens a test vault) is off unless a run asks for it with
`-f test_login=true`. Never send such a build to production: check the run's inputs first.
The run uploads to TestFlight, Play internal and alpha, and makes GitHub release v1.0.0.
Note the build number from the run summary.

- [ ] Install that exact build from TestFlight and Play internal; go through: new vault,
      add a photo / note / password, lock and unlock, backup and restore, Wi-Fi sync, Drive sync.

## 3. Screenshots

    tools/store-shots

Output `app/test/store/<device>-<screen>-<en|vi>-<light|dark>.png`: `iphone` 1206x2622
(App Store 6.3", the size App Store Connect asks for first), `ipad` 2064x2752 (App Store 13"), `play` 1080x1920 (Google Play phone).
Order and which screens: `store/README.md`. Look at every picture before uploading.
The store pictures show the lock with the vault password and the library with clear
thumbnails and no first-time tip.

    tools/store-feature-graphic

Output `store/feature-graphic-<en|vi>.png` (Google Play, 1024x500).

## 4. Google Play

- [x] Dashboard → Apply for production access (sent 2026-11-17): answers in `docs/play-production-answers.txt`
      (not in git). Google answers by email, usually within a week.
- [x] Main store listing, 15 languages: title, short and full description from `store/text/`,
      icon `branding/icon-1024.png` (512 px), feature graphic, phone screenshots.
- [ ] Store settings: category Productivity, contact email, privacy policy URL.
- [ ] Countries / regions for production.
- [ ] After access is granted and the owner says go:

      gh workflow run play-production.yml -R cozy-pi/cozysafe -f build=<N> -f confirm=production

      Then "Send for review" in Publishing overview if Play asks.

## 5. App Store

- [x] Version: must equal the build's version (1.0.1 for build 1180).
- [x] Text in 15 languages: `gh workflow run store-text.yml -R cozy-pi/cozysafe -f write=true`.
      By hand: copyright, screenshots (iPhone 6.3", iPad 13").
- [x] App Information: category, age rating, content rights. App Privacy: Data Not Collected.
      Pricing: free, every country EXCEPT France (docs/export-compliance.md: the
      "no export documents" answer holds only while France is left out). Business → trader status for the EU.
- [x] App Review Information: contact, notes from `store/README.md`, "Sign-in required" off.
- [x] Build: pick the build (1180). Release: manually, so both stores can go out together.
- [x] Owner says go → Add for Review → Submit. Apple usually answers in 1 to 2 days.
      Add for Review is refused while China mainland is ticked without its two documents
      (Security Assessment, AIGC declaration); ticking it again after submitting is allowed.

## 6. After both are approved

- [ ] Release on the App Store (manual release) and check the Play production rollout.
- [ ] `website`: `LIVE = True` in `website/build.py`, `python3 website/build.py`, then
      `npx wrangler deploy` from `website/`: the iPhone card links to the App Store,
      Android to Google Play, and the "Preview" note goes.
- [ ] Cozy Safe Beta: rebase `beta` on `main`; new work is tried there first.

## Learned in the trial run (2026-11-16)

- App Store Connect's first iPhone slot is 6.1"/6.3" (1206x2622 or 1179x2556); it turned
  1290x2796 down. Screenshots with an alpha channel are refused: `tools/store-shots` removes it.
- App Store Connect and the Play Console both take several files in one upload, but Play
  shows them in its own order: put them in the listing's order with the arrow on each picture.
- Google Play already has an icon and a feature graphic from the closed test; phone
  screenshots are replaced by deleting the old ones (bin on hover) and uploading new ones.
  "Save as draft" keeps the change out of review until it is sent.
- Filled in as drafts that day, English only: App Store version 1.0.0 (text, URLs, review
  notes, manual release, iPhone and iPad screenshots), App Information (name, subtitle,
  categories), Play default listing (title, descriptions, phone screenshots).
- All 15 languages are on both stores as drafts: App Store through the store-text
  workflow (it also set the privacy policy URL), Google Play by hand in the Console
  (Manage languages, then title, short and full description per language, Save as draft;
  the service account has no right to edit the listing). Screenshots are English only:
  a language without its own shows the English ones.
- Still by hand: Vietnamese screenshots, App Privacy answers, age rating, content rights,
  review contact, the EU trader status, Play seller status, France unticked in availability.
