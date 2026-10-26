import 'package:flutter/material.dart';

import '../appearance.dart';
import '../biometric.dart';
import '../l10n/app_localizations.dart';
import '../language.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/identity.dart';
import '../widgets/pin_pad.dart';
import '../widgets/selectable_row.dart';
import '../widgets/vault_bar.dart';
import 'common.dart' show fadeRoute;
import 'new_vault.dart' show StepButton;
import 'settings.dart';

/// Which tour: right after a vault is made (every card), or after restoring one on a new
/// device (owner 2026-10-25). A restored vault came from its second copy and was opened
/// with its 24 words and password a minute ago, so "Stay safe" and "Keep a second copy"
/// would tell the person what they just did: they get the three cards about using it.
enum TourKind { created, restored }

enum _Card { add, open, safe, copy, settings }

/// A short tour of the basics, skippable at every card (owner 2026-10-25): how to add,
/// how to open and act, what keeps the vault safe, a second copy, and the settings worth
/// a look. Pops the setting to go to (Sync, auto-lock…), or null. Settings → Quick tour
/// opens it again.
Future<SettingsSpot?> showTour(BuildContext context, {TourKind kind = TourKind.created, String? icon, String? color}) =>
    Navigator.of(context).push<SettingsSpot>(fadeRoute((_) => TourScreen(kind: kind, icon: icon, color: color)));

class TourScreen extends StatefulWidget {
  const TourScreen({super.key, this.kind = TourKind.created, this.icon, this.color});

  final TourKind kind;
  /// The vault's own icon and colour, on the "Stay safe" card and in the + bar.
  final String? icon;
  final String? color;

  /// For the mockup renders: open on this card (0-based).
  static int debugStart = 0;

  @override
  State<TourScreen> createState() => _TourScreenState();
}

class _TourScreenState extends State<TourScreen> {
  late final _pages = PageController(initialPage: TourScreen.debugStart.clamp(0, _cards.length - 1));
  late int _at = TourScreen.debugStart.clamp(0, _cards.length - 1);
  BiometricKind? _bio;

  List<_Card> get _cards => widget.kind == TourKind.created
      ? _Card.values
      : const [_Card.add, _Card.open, _Card.settings];

  @override
  void initState() {
    super.initState();
    BiometricUnlock.available().then((k) {
      if (mounted) setState(() => _bio = k);
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (_at >= _cards.length - 1) return Navigator.of(context).pop();
    _pages.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final cards = _cards;
    final card = cards[_at];
    final last = _at == cards.length - 1;
    Widget primary(Key key, String label, VoidCallback onTap) => FilledButton(
          key: key,
          style: FilledButton.styleFrom(minimumSize: const Size(140, 52), shape: const StadiumBorder()),
          onPressed: onTap,
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                key: const ValueKey('tour-pages'),
                controller: _pages,
                onPageChanged: (i) => setState(() => _at = i),
                children: [for (final c in cards) _page(context, l, c)],
              ),
            ),
            // Where we are: a dot per card, the current one long.
            Semantics(
              label: l.tourStep(_at + 1, cards.length),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < cards.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _at ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _at ? ink : ink.withValues(alpha: .22),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
            ),
            // Every button at the bottom, under the thumbs (owner 2026-10-25), as on the
            // new-vault steps: Skip on the left, the way on at the right.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (card == _Card.copy) ...[
                    primary(const ValueKey('tour-sync'), l.tourCopyNow,
                        () => Navigator.of(context).pop(SettingsSpot.sync)),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      if (!last)
                        StepButton(
                          key: const ValueKey('tour-skip'),
                          label: l.tourSkip,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      const Spacer(),
                      // On the second-copy card the main button is "Set up sync now"; the
                      // way on is then a quiet "Later".
                      if (card == _Card.copy)
                        StepButton(key: const ValueKey('tour-next'), label: l.tourLater, onTap: _next)
                      else
                        primary(const ValueKey('tour-next'), last ? l.tourDone : l.tourNext, _next),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One card: a picture made of the app's own pieces, the title, a line or two.
  Widget _page(BuildContext context, AppLocalizations l, _Card card) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final (title, body, picture) = switch (card) {
      _Card.add => (l.tourAddTitle, l.tourAddBody, _addPicture(context, l)),
      _Card.open => (l.tourOpenTitle, l.tourOpenBody, _openPicture(context, l)),
      _Card.safe => (l.tourSafeTitle, null, _safePicture(context, l)),
      _Card.copy => (l.tourCopyTitle, l.tourCopyBody, _copyPicture(context, l)),
      _Card.settings => (l.tourSettingsTitle, l.tourSettingsBody, _settingsPicture(context, l)),
    };
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        key: ValueKey('tour-${card.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                // The picture first: it says most of it (owner: pictures over words).
                children: [
                  const SizedBox(height: 16),
                  picture,
                  const SizedBox(height: 28),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ink, fontSize: 26, fontWeight: FontWeight.w800, height: 1.2)),
                  if (body != null) ...[
                    const SizedBox(height: 8),
                    Text(body,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: ink.withValues(alpha: .78), fontSize: 16, height: 1.4)),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _icon => widget.icon ?? 'home';
  String get _color => widget.color ?? 'green';

  /// The real + bar and the row of ways it opens (vault_bar.dart), not touchable here.
  Widget _addPicture(BuildContext context, AppLocalizations l) {
    final camera = Device.iOS || Device.android || debugCamera;
    final voice = vaultSections().contains(VaultSection.audio);
    final ways = addRowWays(l, VaultSection.home, camera: camera, voice: voice);
    final ink = Theme.of(context).colorScheme.onSurface;
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, box) {
        final each = (box.maxWidth / ways.length).clamp(AddRow.minWidth, AddRow.width);
        return Column(
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              runSpacing: 12,
              children: [
                for (final (what, icon, label) in ways)
                  addWayButton(context, what, icon, label, hovered: false, onTap: () {}, width: each),
              ],
            ),
            const SizedBox(height: 14),
            Icon(Icons.arrow_upward_rounded, color: ink.withValues(alpha: .5), size: 28),
            const SizedBox(height: 10),
            VaultBar(
              section: VaultSection.home,
              sections: const [VaultSection.home, VaultSection.library, VaultSection.file, VaultSection.note],
              onSection: (_) {},
              home: VaultBadge(icon: _icon, color: _color, size: 32),
              centre: ActionButton(icon: Icons.add, tooltip: l.addToVault, onTap: () {}, solid: true, size: centrePlusSize),
            ),
          ],
        );
      }),
    );
  }

  /// A card of the three gestures, each with a small copy of what it opens.
  Widget _openPicture(BuildContext context, AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final red = recordRed(context);
    Widget thumb(Color c, {double size = 54, bool? selected}) => Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [c, Color.lerp(c, Colors.black, .25)!],
                ),
              ),
              child: Icon(Icons.landscape_rounded, color: Colors.white.withValues(alpha: .85), size: size * .5),
            ),
            if (selected != null)
              Positioned(
                right: 3,
                bottom: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, shape: BoxShape.circle),
                  child: SelectCircle(selected: selected),
                ),
              ),
          ],
        );
    // The preview's glass bar (quick_look.dart): close, full screen, send, delete.
    final bar = Glass(
      radius: 22,
      child: SizedBox(
        height: 44,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (icon, color) in [
            (Icons.close_rounded, ink),
            (Icons.fullscreen_rounded, ink),
            (Icons.ios_share, ink),
            (Icons.delete_outline, red),
          ])
            Padding(padding: const EdgeInsets.symmetric(horizontal: 9), child: Icon(icon, size: 21, color: color)),
        ]),
      ),
    );
    // The item menu (item_menu.dart), its first lines.
    final page = Theme.of(context).scaffoldBackgroundColor;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final menu = Container(
      width: 150,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(ink.withValues(alpha: dark ? .10 : .05), page),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ink.withValues(alpha: .10)),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final (icon, label) in [
          (Icons.open_in_new_rounded, l.openItem),
          (Icons.edit_outlined, l.rename),
          (Icons.ios_share, l.sendOut),
        ])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              Icon(icon, size: 17, color: ink),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5)),
              ),
            ]),
          ),
      ]),
    );
    // The Select pill and the circles every item then shows.
    final select = Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(color: ink.withValues(alpha: .1), borderRadius: BorderRadius.circular(18)),
        child: Text(l.select, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
      ),
      const SizedBox(width: 10),
      thumb(const Color(0xFF7FA79A), size: 44, selected: true),
      const SizedBox(width: 6),
      thumb(const Color(0xFFD9A07A), size: 44, selected: true),
      const SizedBox(width: 6),
      thumb(const Color(0xFF9CC4DE), size: 44, selected: false),
    ]);
    return IgnorePointer(
      child: Column(children: [
        _gesture(context, Icons.touch_app_outlined, l.tourOpenTap,
            Row(mainAxisSize: MainAxisSize.min, children: [
              thumb(const Color(0xFF7FA79A)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Icon(Icons.arrow_forward_rounded, size: 20, color: ink.withValues(alpha: .5)),
              ),
              bar,
            ])),
        const SizedBox(height: 10),
        _gesture(context, Icons.back_hand_outlined, l.tourOpenHold,
            Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              thumb(const Color(0xFFD9A07A)),
              const SizedBox(width: 12),
              menu,
            ])),
        const SizedBox(height: 10),
        _gesture(context, Icons.check_circle_outline, l.tourOpenSelect, select),
      ]),
    );
  }

  /// One gesture: its symbol and word, and under it what it does.
  Widget _gesture(BuildContext context, IconData icon, String label, Widget shows) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(color: ink.withValues(alpha: .06), borderRadius: BorderRadius.circular(Ui.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 22, color: ink),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 10),
        Center(child: FittedBox(fit: BoxFit.scaleDown, child: shows)),
      ]),
    );
  }

  /// A row with a round symbol, as on the first new-vault step.
  Widget _row(BuildContext context, Widget symbol, String text, {Key? key}) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Container(
      key: key,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: ink.withValues(alpha: .06), borderRadius: BorderRadius.circular(Ui.radius)),
      child: Row(children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: ink.withValues(alpha: .1), shape: BoxShape.circle),
          child: Center(child: symbol),
        ),
        const SizedBox(width: 14),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.35))),
      ]),
    );
  }

  Widget _safePicture(BuildContext context, AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final bio = _bio;
    return Column(children: [
      // The vault with a lock on it.
      Stack(clipBehavior: Clip.none, children: [
        VaultBadge(icon: _icon, color: _color, size: 84),
        Positioned(
          right: -6,
          bottom: -6,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              shape: BoxShape.circle,
              border: Border.all(color: ink.withValues(alpha: .15)),
            ),
            child: Icon(Icons.lock_rounded, size: 20, color: ink),
          ),
        ),
      ]),
      const SizedBox(height: 24),
      _row(context, Icon(Icons.lock_clock_outlined, color: ink, size: 24), l.tourSafeLock),
      const SizedBox(height: 10),
      _row(
        context,
        bio != null
            ? BiometricGlyph(kind: bio, size: 26, color: ink)
            : SizedBox(width: 30, child: FittedBox(child: PinDots(filled: 4, color: ink))),
        switch (bio) {
          BiometricKind.face => l.tourSafeFace,
          BiometricKind.fingerprint => l.tourSafeFinger,
          null => l.tourSafePin,
        },
      ),
      const SizedBox(height: 10),
      _row(context, Icon(Icons.key_rounded, color: ink, size: 24), l.tourSafeKeys, key: const ValueKey('tour-keys')),
    ]);
  }

  Widget _copyPicture(BuildContext context, AppLocalizations l) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final c = CsColors.of(context);
    // The three digits the other device shows (sync/host_page.dart).
    final digits = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: ink.withValues(alpha: .08), borderRadius: BorderRadius.circular(10)),
      child: const Text('472',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 4, fontFeatures: [FontFeature.tabularFigures()])),
    );
    Widget way(IconData icon, Color color, String title, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
          child: Row(children: [
            SettingTile(icon: icon, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15.5))),
            ?trailing,
          ]),
        );
    return IgnorePointer(
      child: Column(children: [
        // This phone and the other one, the vault on both.
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.phone_iphone_rounded, size: 64, color: ink),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Icon(Icons.sync_alt_rounded, size: 30, color: ink.withValues(alpha: .6)),
          ),
          Icon(Icons.devices_rounded, size: 64, color: ink),
        ]),
        const SizedBox(height: 24),
        Material(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            way(Icons.wifi_rounded, const Color(0xFF007AFF), l.tourCopyWifi, trailing: digits),
            Divider(height: 1, thickness: 1, indent: 56, color: c.border.withValues(alpha: .6)),
            way(Icons.cloud_sync_outlined, const Color(0xFF34A853), l.tourCopyDrive),
            Divider(height: 1, thickness: 1, indent: 56, color: c.border.withValues(alpha: .6)),
            way(Icons.cloud_upload_outlined, const Color(0xFF007AFF), l.tourCopyFile),
          ]),
        ),
      ]),
    );
  }

  /// The settings worth a look, as their rows in Settings: tap one to go there.
  Widget _settingsPicture(BuildContext context, AppLocalizations l) {
    final c = CsColors.of(context);
    final theme = Appearance.mode.value;
    final rows = [
      (SettingsSpot.autoLock, l.autoLock, l.afterMinutes(Settings.autoLockMinutes)),
      (SettingsSpot.blurThumbs, l.blurThumbs, null),
      (SettingsSpot.hideNoteText, l.hideNoteText, null),
      (
        SettingsSpot.appearance,
        l.appearance,
        switch (theme) {
          ThemeMode.light => l.appearanceLight,
          ThemeMode.dark => l.appearanceDark,
          ThemeMode.system => l.appearanceAuto,
        }
      ),
      (
        SettingsSpot.language,
        l.language,
        AppLanguage.chosen == null ? l.languageSystem : languages.firstWhere((x) => x.code == AppLanguage.chosen).name,
      ),
    ];
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (final (i, (spot, title, value)) in rows.indexed) ...[
          if (i > 0) Divider(height: 1, thickness: 1, indent: 56, color: c.border.withValues(alpha: .6)),
          InkWell(
            key: ValueKey('tour-${spot.name}'),
            onTap: () => Navigator.of(context).pop(spot),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
                child: Row(children: [
                  SettingTile(icon: spot.icon, color: spot.color),
                  const SizedBox(width: 12),
                  Expanded(child: Text(title, style: const TextStyle(fontSize: 15.5))),
                  if (value != null) ...[
                    const SizedBox(width: 8),
                    Text(value, style: TextStyle(color: c.muted, fontSize: 14)),
                  ],
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, color: c.muted, size: 20),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}
