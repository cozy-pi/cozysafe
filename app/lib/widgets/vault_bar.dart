import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import 'add_dock.dart';

/// What the vault shows, picked in the bottom capsule (docs/ui.md, vault bar).
enum VaultKind { note, library, audio, file }

/// The kinds this device offers: voice memos need a phone's microphone.
List<VaultKind> vaultKinds() => [
      VaultKind.note,
      VaultKind.library,
      if (Device.iOS || Device.android || debugVoice) VaultKind.audio,
      VaultKind.file,
    ];

/// For tests and the browser preview: offer voice memos on any platform.
bool debugVoice = false;

/// For tests and the browser preview: offer the camera in the Library's + menu.
bool debugCamera = false;

const _kindPref = 'vault-kind';

/// The kind the vault opens on: the last one used.
VaultKind startKind() {
  final saved = Prefs.read(_kindPref);
  return vaultKinds().where((k) => k.name == saved).firstOrNull ?? VaultKind.library;
}

String kindLabel(AppLocalizations l, VaultKind k) => switch (k) {
      VaultKind.note => l.modeNote,
      VaultKind.library => l.modeLibrary,
      VaultKind.audio => l.modeAudio,
      VaultKind.file => l.modeFile,
    };

/// Frosted glass, as in the system's own bars: a light blur of what scrolls under it.
/// With "Reduce transparency" on (or no blur available), a plain translucent fill.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, required this.radius});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final plain = MediaQuery.highContrastOf(context);
    final fill = dark ? const Color(0xC71C2422) : const Color(0xB8FFFFFF);
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: plain ? (dark ? const Color(0xFF1C2422) : Colors.white) : fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: dark ? const Color(0x1FFFFFFF) : const Color(0xB3FFFFFF)),
        boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: child,
    );
    if (plain) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter.grouped(filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: box),
    );
  }
}

/// A round glass button (lock, search, settings).
class GlassButton extends StatelessWidget {
  const GlassButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.size = 46, this.child});
  final IconData? icon;
  final Widget? child;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: GestureDetector(
            onTap: onTap,
            child: Glass(
              radius: size / 2,
              child: SizedBox.square(
                dimension: size,
                child: Center(child: child ?? Icon(icon, size: size * .44, color: Theme.of(context).colorScheme.onSurface)),
              ),
            ),
          ),
        ),
      );
}

/// The bottom row: the lock on the left, then the kinds in a capsule. Tapping a kind
/// switches; dragging along the capsule switches as the finger passes each one.
class VaultBar extends StatelessWidget {
  const VaultBar({super.key, required this.kind, required this.onKind, required this.lock});

  final VaultKind kind;
  final ValueChanged<VaultKind> onKind;
  final Widget lock;

  void _pick(VaultKind k) {
    if (k == kind) return;
    HapticFeedback.selectionClick();
    Prefs.write(_kindPref, k.name);
    onKind(k);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final kinds = vaultKinds();
    final primary = Theme.of(context).colorScheme.primary;
    final ink = Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        lock,
        const SizedBox(width: 8),
        Expanded(
          child: Glass(
            radius: 25,
            child: LayoutBuilder(
              builder: (context, box) {
                VaultKind at(double x) => kinds[(x / (box.maxWidth / kinds.length)).floor().clamp(0, kinds.length - 1)];
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _pick(at(d.localPosition.dx)),
                  onHorizontalDragUpdate: (d) => _pick(at(d.localPosition.dx)),
                  child: SizedBox(
                    height: 50,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        children: [
                          for (final k in kinds)
                            Expanded(
                              child: Semantics(
                                button: true,
                                selected: k == kind,
                                label: kindLabel(l, k),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 160),
                                  decoration: BoxDecoration(
                                    color: k == kind ? primary.withValues(alpha: .14) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(21),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    kindLabel(l, k),
                                    maxLines: 1,
                                    overflow: TextOverflow.fade,
                                    softWrap: false,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: k == kind ? FontWeight.w700 : FontWeight.w600,
                                      color: k == kind ? primary : ink.withValues(alpha: .75),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// The main action, floating above the lock (left thumb): one tap for notes and voice,
/// a small menu for the library and files.
class ActionButton extends StatelessWidget {
  const ActionButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.red = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool red;

  @override
  Widget build(BuildContext context) {
    final c = red ? const Color(0xFFE5484D) : Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c,
        shape: const CircleBorder(),
        elevation: 4,
        shadowColor: c.withValues(alpha: .35),
        child: InkWell(
          key: const ValueKey('vault-action'),
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.mediumImpact();
            onTap();
          },
          child: SizedBox.square(
            dimension: 56,
            child: Icon(icon, color: red ? Colors.white : Theme.of(context).colorScheme.onPrimary, size: 26),
          ),
        ),
      ),
    );
  }
}
