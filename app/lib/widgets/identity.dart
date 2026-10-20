import 'dart:math';

import 'package:flutter/material.dart';

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
  VaultIcon('home', Icons.home_outlined, 'Home'),
  VaultIcon('work', Icons.work_outline, 'Work'),
  VaultIcon('family', Icons.family_restroom, 'Family'),
  VaultIcon('money', Icons.account_balance_wallet_outlined, 'Money'),
  VaultIcon('id', Icons.badge_outlined, 'Documents'),
  VaultIcon('health', Icons.local_hospital_outlined, 'Health'),
  VaultIcon('travel', Icons.flight, 'Travel'),
  VaultIcon('car', Icons.directions_car_outlined, 'Car'),
  VaultIcon('study', Icons.menu_book_outlined, 'Study'),
  VaultIcon('star', Icons.star_outline, 'Memories'),
  VaultIcon('key', Icons.vpn_key_outlined, 'Secrets'),
  VaultIcon('gift', Icons.card_giftcard, 'Gifts'),
  VaultIcon('love', Icons.favorite_border, 'Love'),
  VaultIcon('pet', Icons.pets, 'Pets'),
  VaultIcon('music', Icons.music_note_outlined, 'Music'),
  VaultIcon('camera', Icons.photo_camera_outlined, 'Photos'),
  VaultIcon('phone', Icons.smartphone, 'Phone'),
  VaultIcon('globe', Icons.public, 'World'),
  VaultIcon('sun', Icons.wb_sunny_outlined, 'Sun'),
  VaultIcon('moon', Icons.dark_mode_outlined, 'Moon'),
  VaultIcon('flower', Icons.local_florist_outlined, 'Flower'),
  VaultIcon('tree', Icons.park_outlined, 'Tree'),
  VaultIcon('coffee', Icons.coffee_outlined, 'Coffee'),
  VaultIcon('cake', Icons.cake_outlined, 'Cake'),
  VaultIcon('baby', Icons.child_care, 'Baby'),
  VaultIcon('shield', Icons.shield_outlined, 'Shield'),
  VaultIcon('lock', Icons.lock_outline, 'Lock'),
  VaultIcon('cloud', Icons.cloud_outlined, 'Cloud'),
  VaultIcon('bolt', Icons.bolt, 'Bolt'),
  VaultIcon('anchor', Icons.anchor, 'Anchor'),
  VaultIcon('bike', Icons.pedal_bike, 'Bike'),
  VaultIcon('sport', Icons.sports_soccer, 'Sport'),
  VaultIcon('game', Icons.sports_esports_outlined, 'Games'),
  VaultIcon('shop', Icons.shopping_bag_outlined, 'Shopping'),
  VaultIcon('school', Icons.school_outlined, 'Graduation'),
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

/// The vault's identity: its icon, white, on its colour.
class VaultBadge extends StatelessWidget {
  const VaultBadge({super.key, required this.icon, required this.color, this.size = 44, this.ring = false});

  final String icon;
  final String color;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    // The one place colour stays in the black-and-white app: a vault's own icon and
    // colour, so you know at a glance which vault it is (docs/ui.md, Black and white).
    final i = iconById(icon);
    final c = colorById(color);
    return Semantics(
      label: '${i.label}, ${c.label}',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: c.color,
          borderRadius: BorderRadius.circular(size * .24),
          border: ring ? Border.all(color: const Color(0xD9FFFFFF), width: 3) : null,
          boxShadow: ring ? const [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 10))] : null,
        ),
        child: Icon(i.icon, color: Colors.white, size: size * .5),
      ),
    );
  }
}

/// All icons (or colours) in a bottom sheet, for the "⋯" tile and the vault menu.
Future<int?> showAllIcons(BuildContext context, int selected) => showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 6,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (var i = 0; i < vaultIcons.length; i++)
                Semantics(
                  button: true,
                  selected: i == selected,
                  label: vaultIcons[i].label,
                  child: Material(
                    color: i == selected ? Theme.of(context).colorScheme.primary : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Theme.of(context).colorScheme.outline),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(context, i),
                      child: Icon(vaultIcons[i].icon,
                          color: i == selected ? Theme.of(context).colorScheme.onPrimary : null),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

Future<int?> showAllColors(BuildContext context, int selected) => showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 5,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (var i = 0; i < vaultColors.length; i++)
                Semantics(
                  button: true,
                  selected: i == selected,
                  label: vaultColors[i].label,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context, i),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: vaultColors[i].color,
                        shape: BoxShape.circle,
                        border: i == selected ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 3) : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
