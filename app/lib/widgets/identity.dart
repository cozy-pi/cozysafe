import 'dart:math';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'vault_bar.dart' show showCard;


/// A vault is recognised by an icon and a colour, never a typed name (docs/ui.md).
/// Ids are stored (sealed) in the vault; the lists only grow, never reorder, so
/// stored ids keep meaning the same thing.
class VaultIcon {
  const VaultIcon(this.id, this.icon, this.label);
  final String id;
  final IconData icon;
  /// For screen readers only; never shown.
  final String label;
}

class VaultColor {
  const VaultColor(this.id, this.color, this.label);
  final String id;
  final Color color;
  final String label;
}

/// The first 11 are on the grid; the rest are behind "⋯".
const vaultIcons = <VaultIcon>[
  VaultIcon('home', Icons.home_rounded, 'Home'),
  VaultIcon('work', Icons.work_rounded, 'Work'),
  VaultIcon('family', Icons.family_restroom_rounded, 'Family'),
  VaultIcon('money', Icons.account_balance_wallet_rounded, 'Money'),
  VaultIcon('id', Icons.badge_rounded, 'Documents'),
  VaultIcon('health', Icons.local_hospital_rounded, 'Health'),
  VaultIcon('travel', Icons.flight_rounded, 'Travel'),
  VaultIcon('car', Icons.directions_car_rounded, 'Car'),
  VaultIcon('study', Icons.menu_book_rounded, 'Study'),
  VaultIcon('star', Icons.star_rounded, 'Memories'),
  VaultIcon('key', Icons.vpn_key_rounded, 'Secrets'),
  VaultIcon('gift', Icons.card_giftcard_rounded, 'Gifts'),
  VaultIcon('love', Icons.favorite_rounded, 'Love'),
  VaultIcon('pet', Icons.pets_rounded, 'Pets'),
  VaultIcon('music', Icons.music_note_rounded, 'Music'),
  VaultIcon('camera', Icons.photo_camera_rounded, 'Photos'),
  VaultIcon('phone', Icons.smartphone_rounded, 'Phone'),
  VaultIcon('globe', Icons.public_rounded, 'World'),
  VaultIcon('sun', Icons.wb_sunny_rounded, 'Sun'),
  VaultIcon('moon', Icons.dark_mode_rounded, 'Moon'),
  VaultIcon('flower', Icons.local_florist_rounded, 'Flower'),
  VaultIcon('tree', Icons.park_rounded, 'Tree'),
  VaultIcon('coffee', Icons.coffee_rounded, 'Coffee'),
  VaultIcon('cake', Icons.cake_rounded, 'Cake'),
  VaultIcon('baby', Icons.child_care_rounded, 'Baby'),
  VaultIcon('shield', Icons.shield_rounded, 'Shield'),
  VaultIcon('lock', Icons.lock_rounded, 'Lock'),
  VaultIcon('cloud', Icons.cloud_rounded, 'Cloud'),
  VaultIcon('bolt', Icons.bolt_rounded, 'Bolt'),
  VaultIcon('anchor', Icons.anchor_rounded, 'Anchor'),
  VaultIcon('bike', Icons.pedal_bike_rounded, 'Bike'),
  VaultIcon('sport', Icons.sports_soccer_rounded, 'Sport'),
  VaultIcon('game', Icons.sports_esports_rounded, 'Games'),
  VaultIcon('shop', Icons.shopping_bag_rounded, 'Shopping'),
  VaultIcon('school', Icons.school_rounded, 'Graduation'),
];

/// Hand-picked so no two look alike (generated hue steps did); all hold white icons.
const vaultColors = <VaultColor>[
  VaultColor('green', Color(0xFF165B4C), 'Vault green'),
  VaultColor('night', Color(0xFF1F3F6B), 'Night blue'),
  VaultColor('plum', Color(0xFF5B2D55), 'Plum'),
  VaultColor('red', Color(0xFFB3261E), 'Red'),
  VaultColor('orange', Color(0xFFC4581A), 'Orange'),
  VaultColor('amber', Color(0xFFA87A00), 'Amber'),
  VaultColor('leaf', Color(0xFF2F6B2A), 'Leaf'),
  VaultColor('teal', Color(0xFF0F6E6E), 'Teal'),
  VaultColor('violet', Color(0xFF6D3FB0), 'Violet'),
  VaultColor('pink', Color(0xFFB0336B), 'Pink'),
  VaultColor('charcoal', Color(0xFF3A4045), 'Charcoal'),
  VaultColor('blue', Color(0xFF2A5FB0), 'Blue'),
  VaultColor('indigo', Color(0xFF4338A0), 'Indigo'),
  VaultColor('brown', Color(0xFF6B4A2B), 'Brown'),
  VaultColor('moss', Color(0xFF5A7A1A), 'Moss'),
  VaultColor('sea', Color(0xFF136A8A), 'Sea'),
  VaultColor('wine', Color(0xFF7A1F2B), 'Wine'),
  VaultColor('grey', Color(0xFF6B7280), 'Grey'),
  VaultColor('black', Color(0xFF1B1D1F), 'Black'),
  VaultColor('latte', Color(0xFF8A6A4A), 'Latte'),
];

const gridCount = 11;

VaultIcon iconById(String id) => vaultIcons.firstWhere((i) => i.id == id, orElse: () => vaultIcons.first);
VaultColor colorById(String id) => vaultColors.firstWhere((c) => c.id == id, orElse: () => vaultColors.first);

/// A random suggestion from the grid tiles, different from `avoid` when given.
(String, String) randomIdentity({(String, String)? avoid}) {
  final r = Random();
  while (true) {
    final pick = (vaultIcons[r.nextInt(gridCount)].id, vaultColors[r.nextInt(gridCount)].id);
    if (pick != avoid) return pick;
  }
}

/// The screen background for a vault colour: darker, so white text stays readable.
Color backdropTint(Color c) => Color.lerp(c, Colors.black, .28)!;

/// The vault's identity: its icon, white, on its colour (docs/ui.md, design language).
/// A circle with a little light from above and, when large, a soft shadow in its colour
/// (owner chose round over a squircle, 2026-10-21).
class VaultBadge extends StatelessWidget {
  const VaultBadge({super.key, required this.icon, required this.color, this.size = 44, this.ring = false});

  final String icon;
  final String color;
  final double size;
  /// Kept for callers; the badge no longer draws a ring.
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final i = iconById(icon);
    final c = colorById(color);
    final lift = size >= 64; // big badges stand out with depth; small ones stay flat
    return Semantics(
      label: '${i.label}, ${c.label}',
      child: Container(
        width: size,
        height: size,
        decoration: ShapeDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(c.color, Colors.white, .16)!, c.color, Color.lerp(c.color, Colors.black, .14)!],
          ),
          shape: const CircleBorder(),
          shadows: lift
              ? [BoxShadow(color: c.color.withValues(alpha: .38), blurRadius: size * .22, offset: Offset(0, size * .09))]
              : null,
        ),
        child: Icon(i.icon, color: Colors.white, size: size * .52),
      ),
    );
  }
}

/// All icons (or colours) in a card, for the "⋯" tile when making a vault.
Future<int?> showAllIcons(BuildContext context, int selected) => showCard<int>(
      context,
      title: AppLocalizations.of(context).pickIconHint,
      closeButton: true,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
        child: _IconGrid(selected: selected, onPick: (i) => Navigator.pop(context, i)),
      ),
    );

Future<int?> showAllColors(BuildContext context, int selected) => showCard<int>(
      context,
      title: AppLocalizations.of(context).pickColorTitle,
      closeButton: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
        child: _ColorRow(selected: selected, onPick: (i) => Navigator.pop(context, i)),
      ),
    );

/// Change a vault's icon and colour in one card: the badge on top follows the choice.
Future<(int, int)?> showIdentityCard(BuildContext context, {required int icon, required int color}) =>
    showCard<(int, int)>(
      context,
      title: AppLocalizations.of(context).changeIdentity,
      builder: (context) => _IdentityPicker(icon: icon, color: color),
    );

class _IdentityPicker extends StatefulWidget {
  const _IdentityPicker({required this.icon, required this.color});
  final int icon;
  final int color;

  @override
  State<_IdentityPicker> createState() => _IdentityPickerState();
}

class _IdentityPickerState extends State<_IdentityPicker> {
  late int _icon = widget.icon;
  late int _color = widget.color;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: VaultBadge(icon: vaultIcons[_icon].id, color: vaultColors[_color].id, size: 72)),
        const SizedBox(height: 14),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                _IconGrid(selected: _icon, onPick: (i) => setState(() => _icon = i)),
                const SizedBox(height: 16),
                _ColorRow(selected: _color, onPick: (i) => setState(() => _color = i)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: FilledButton(
            key: const ValueKey('identity-save'),
            onPressed: () => Navigator.pop(context, (_icon, _color)),
            child: Text(l.save),
          ),
        ),
      ],
    );
  }
}

class _IconGrid extends StatelessWidget {
  const _IconGrid({required this.selected, required this.onPick});
  final int selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final page = Theme.of(context).scaffoldBackgroundColor;
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      crossAxisCount: 7,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        for (var i = 0; i < vaultIcons.length; i++)
          Semantics(
            button: true,
            selected: i == selected,
            label: vaultIcons[i].label,
            child: Material(
              color: i == selected ? ink : ink.withValues(alpha: .06),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onPick(i),
                child: Icon(vaultIcons[i].icon, color: i == selected ? page : ink),
              ),
            ),
          ),
      ],
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.selected, required this.onPick});
  final int selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: [
          for (var i = 0; i < vaultColors.length; i++)
            Semantics(
              button: true,
              selected: i == selected,
              label: vaultColors[i].label,
              child: GestureDetector(
                onTap: () => onPick(i),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: vaultColors[i].color,
                    shape: BoxShape.circle,
                    border: i == selected ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3) : null,
                  ),
                ),
              ),
            ),
        ],
      );
}
