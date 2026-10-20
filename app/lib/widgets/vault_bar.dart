import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../prefs.dart';

/// The four sections of a vault, picked in the bottom capsule (docs/ui.md, vault bar;
/// docs/naming.md). A section shows items of some kinds: Library shows photos and
/// videos, the others one kind each.
enum VaultSection { note, library, audio, file }

/// The sections this device offers: voice memos need a phone's microphone.
List<VaultSection> vaultSections() => [
      VaultSection.note,
      VaultSection.library,
      if (Device.iOS || Device.android || debugVoice) VaultSection.audio,
      VaultSection.file,
    ];

/// For tests and the browser preview: offer voice memos on any platform.
bool debugVoice = false;

/// For tests and the browser preview: offer the camera in the Library's + menu.
bool debugCamera = false;

const _sectionPref = 'vault-section';

/// The section the vault opens on: the last one used (0.1.6 kept it as `vault-kind`).
VaultSection startSection() {
  final saved = Prefs.read(_sectionPref) ?? Prefs.read('vault-kind');
  return vaultSections().where((k) => k.name == saved).firstOrNull ?? VaultSection.library;
}

String sectionLabel(AppLocalizations l, VaultSection k) => switch (k) {
      VaultSection.note => l.modeNote,
      VaultSection.library => l.modeLibrary,
      VaultSection.audio => l.modeAudio,
      VaultSection.file => l.modeFile,
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
    // Neutral glass: the page colour, translucent, with a hairline of ink.
    final ink = Theme.of(context).colorScheme.onSurface;
    final page = Theme.of(context).scaffoldBackgroundColor;
    final fill = Color.alphaBlend(ink.withValues(alpha: dark ? .12 : .04), page).withValues(alpha: dark ? .78 : .72);
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: plain ? Color.alphaBlend(ink.withValues(alpha: dark ? .12 : .04), page) : fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: ink.withValues(alpha: dark ? .14 : .08)),
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

/// The bottom row: the lock on the left, then the sections in a capsule. Tapping a section
/// switches; dragging along the capsule switches as the finger passes each one.
class VaultBar extends StatelessWidget {
  const VaultBar({super.key, required this.section, required this.onSection, required this.lock});

  final VaultSection section;
  final ValueChanged<VaultSection> onSection;
  final Widget lock;

  void _pick(VaultSection s) {
    if (s == section) return;
    HapticFeedback.selectionClick();
    Prefs.write(_sectionPref, s.name);
    onSection(s);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sections = vaultSections();
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
                VaultSection at(double x) => sections[(x / (box.maxWidth / sections.length)).floor().clamp(0, sections.length - 1)];
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
                          for (final s in sections)
                            Expanded(
                              child: Semantics(
                                button: true,
                                selected: s == section,
                                label: sectionLabel(l, s),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 160),
                                  decoration: BoxDecoration(
                                    color: s == section ? primary.withValues(alpha: .14) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(21),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    sectionLabel(l, s),
                                    maxLines: 1,
                                    overflow: TextOverflow.fade,
                                    softWrap: false,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: s == section ? FontWeight.w700 : FontWeight.w600,
                                      color: s == section ? primary : ink.withValues(alpha: .75),
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
  const ActionButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.color});
  final IconData icon;
  /// Voice: the record red with a white mic (theme.dart `recordRed`); otherwise ink.
  final Color? color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
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
            child: Icon(icon, color: color != null ? Colors.white : Theme.of(context).colorScheme.onPrimary, size: 26),
          ),
        ),
      ),
    );
  }
}
