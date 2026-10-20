# Decisions

What was decided, when, and what is still open. Newest first. Update this page in the
same change as the decision (or right after the conversation that made it), so nothing
depends on memory. Details live in the linked docs; this page is the index.

## 2026-10-20

**Releases: each platform ships as soon as it is built, and store keys stay out of build
jobs.** Owner: Android and iOS wait for nobody; after weighing the risk (a hijacked build
package could read a key in the same job), uploads go in separate jobs. Play: a `play` job
that needs only `android`. Build jobs only read the repository; attesting and publishing
happen in the release job. Planned the same way: TestFlight upload apart from the iOS
build, macOS notarization apart from the build, Android signing apart from the build.

**Security settings ask for the owner; secrets are hidden until asked for.** Owner,
after finding loose settings: every security setting needs Face ID, fingerprint or the
passcode; passwords and the Secret Key never appear on screen by default (a person or a
camera could see them), only with a Show button. Rules and the list of settings:
`docs/security.md`. Also fixed: copying the Secret Key now wipes the clipboard after 60 s.

**Black and white look (approved for building).** Everything in ink and page colour,
except the vault's own icon, which keeps its colour (shown big after unlocking, in
Settings, when creating a vault). The delete screen uses the opposite brightness instead
of red.

**Deleting forgotten vaults: deferred** by the owner. The work (Settings → Vaults on this
device, delete with the open vault's PIN) is kept on a local branch; open question when it
returns: who may see the list (decoy vaults).

**0.1.7 released** (TestFlight, Play internal + Alpha, GitHub). After it: cackle's
config is complete and its CI job now blocks (no crate may use the network; ~20 crates
lost permissions they did not need); the core crates forbid unsafe Rust. A repo file
meant for the maintainer's tools was public and is removed from the tree; the owner
chose to leave the published history as it is (no force-push).

**Camera keeps the app frame; readable media names.** Owner feedback on 0.1.6: the
full-screen black camera looked out of place, and photo/video names were odd
("Photo.jpg", "VID_1792…", picker names). Camera: app header, rounded viewfinder, glass
Photo | Video switch (`docs/ui.md`, Camera). Names: kind + moment
(`docs/ui.md`, Names). Released in 0.1.7.

**Groups row: the all-groups button sits first.** At the end of the row it was off
screen and nobody would find it (seen in the rendered mockup). New group stays last.

**Go to push and release** everything agreed (groups, naming, supply-chain controls,
mockup tool, camera, names) — owner, 2026-10-20. Not included: black/white look and
"Vaults on this device" (proposals), pinning the PDFium checksum (not decided).

**Vaults have no name.** A vault is told apart by its icon and colour only. No screen
shows or asks for a name. `VaultMeta.name` is a leftover from the first previews: it is
never filled or shown (keep reading it; remove it with the next vault-header format).

**Groups (tags) replace folders.** Approved. One set of groups for the whole vault; an
item can be in several; a group shows its items in every section (Notes, Library, Voice,
Files). The chip row under the title stays; "New group" stays in the chip row, not in the
+ button. Opening a group keeps it while switching sections. Adding something while a group
is open puts it in that group. Old folders become groups of the same name (nested ones
flatten). Code: item records format 2 (`docs/naming.md`, History). Status: released in 0.1.7.

**Naming rules.** `docs/naming.md`: one concept, one name; units in names; ids `_id`;
no abbreviations outside a short list; stored renames read the old name forever (format
bump + alias + test). Applied together with groups.

**Mockups come from the app.** `docs/ui.md`, Mockups: change the code locally, run
`app/tool/mockup.sh`, publish the framed dark/light page. No hand-drawn screens: a
hand-drawn mockup showed a lock screen, an unlock dial and a vault name the app does not
have.

**Black and white look (first proposal, superseded below).** Main UI in black and white with
opacity only, light and dark (system setting). Unlock keeps the current effect
(`playVaultSpin`: dial grows, turns 192° back to 180°, zooms out) in black/white; then the
vault's icon shows in the middle and fades, so you know which vault opened. Next step:
build it locally and render with `mockup.sh`.

**Forgotten vaults (first proposal, deferred above).** Settings → Vaults on this device: every
vault container with created date and size (the count is already visible from storage);
the open one shows its icon; others can be deleted without their PIN after confirming with
the open vault (biometrics/PIN) and typing a word. Whether a "last opened" date can be
known without decrypting: not checked yet.

**Supply chain: no library can send data out.** Approved. Android build drops the
INTERNET permission and CI checks the APK; macOS sandbox without network entitlements;
the compiled Rust library must import no socket functions; cackle and cargo-deny; Dart
blocks HttpClient/Socket at start; allowlists of every Dart/Rust package plus a scan of
their sources (`docs/supply-chain.md`). Open: `pdfium_dart` downloads `libpdfium` at build
time with no checksum. Status: released in 0.1.7.

**Do not push without the owner's go.** Work stays local (branches, commits) until the
owner says to push or release.

**0.1.6 released:** glass layout (large title, lock + four sections at the bottom, main
action above the lock), per-section folders (superseded by groups above), camera with
video from the Library.
