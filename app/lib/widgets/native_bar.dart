import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../platform.dart';
import '../prefs.dart';
import '../theme.dart';
import 'vault_bar.dart';

/// The bottom bar drawn by iOS itself on iOS 26 and later, so it is Apple's own Liquid
/// Glass (owner 2026-10-21: "the real one is the standard"). A UIKit tab bar and a glass
/// lock button in a platform view (AppDelegate.swift, `TabBarView`); everywhere else, and
/// when turned off in Debug, the app's own [VaultBar].
abstract final class NativeBar {
  static const _privacy = MethodChannel('cozysafe/privacy');

  /// iOS 26 or later (asked once at start).
  static bool available = false;

  static Future<void> probe() async {
    if (!Device.iOS) return;
    try {
      available = await _privacy.invokeMethod<bool>('liquidGlass') ?? false;
    } catch (_) {
      available = false;
    }
  }
}

/// Debug → "iPhone's own bottom bar": off unless turned on (owner 2026-10-22: the app's
/// own bar by default, the system's one to try).
const nativeBarPref = 'native-tab-bar';
bool nativeBarOn() => NativeBar.available && Prefs.read(nativeBarPref) == '1';

/// SF Symbols for the sections, the closest to the app's own icons.
String _symbol(VaultSection s) => switch (s) {
      VaultSection.home => 'house',
      VaultSection.note => 'note.text',
      VaultSection.library => 'photo.on.rectangle',
      VaultSection.audio => 'waveform',
      VaultSection.file => 'doc',
    };

class NativeVaultBar extends StatefulWidget {
  const NativeVaultBar({
    super.key,
    required this.section,
    required this.sections,
    required this.onSection,
    required this.onLock,
    required this.showLock,
    this.onHoldHome,
  });

  final VaultSection section;
  final List<VaultSection> sections;
  final ValueChanged<VaultSection> onSection;
  final VoidCallback onLock;
  /// Off with "hold + to lock": the tab bar runs the full width.
  final bool showLock;
  /// Holding the home tab locks.
  final VoidCallback? onHoldHome;

  /// Room the native side leaves around the bar for the glass bubble (AppDelegate
  /// `margin`): the view is this much taller and runs the full width.
  static const double marginBottom = 10, marginTop = 14;

  /// The platform view's height until the system bar says what it needs ("height").
  static const double height = Ui.bar + 8 + marginTop + marginBottom;

  @override
  State<NativeVaultBar> createState() => _NativeVaultBarState();
}

class _NativeVaultBarState extends State<NativeVaultBar> {
  MethodChannel? _channel;
  double _height = NativeVaultBar.height;

  Map<String, Object?> _params(BuildContext context) {
    final l = AppLocalizations.of(context);
    final shown = widget.sections.length < 2 ? const <VaultSection>[] : widget.sections;
    return {
      'items': [
        for (final s in shown) {'title': sectionLabel(l, s), 'symbol': _symbol(s)},
      ],
      'selected': shown.indexOf(widget.section),
      'lock': widget.showLock,
      'holdHome': widget.onHoldHome != null && shown.isNotEmpty && shown.first == VaultSection.home,
      'lockLabel': l.lockVault,
      'dark': Theme.of(context).brightness == Brightness.dark,
    };
  }

  void _created(int id) {
    final channel = MethodChannel('cozysafe/tabbar/$id');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'select') {
        final shown = widget.sections;
        final i = call.arguments as int;
        if (i >= 0 && i < shown.length && shown[i] != widget.section) {
          HapticFeedback.selectionClick();
          widget.onSection(shown[i]);
        }
      } else if (call.method == 'lock') {
        widget.onLock();
      } else if (call.method == 'holdHome') {
        HapticFeedback.heavyImpact();
        widget.onHoldHome?.call();
      } else if (call.method == 'height') {
        final h = (call.arguments as num).toDouble();
        if (mounted && (h - _height).abs() > .5 && h >= Ui.bar && h <= 160) setState(() => _height = h);
      }
    });
    _channel = channel;
    if (mounted) channel.invokeMethod('update', _params(context));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _channel?.invokeMethod('update', _params(context));
  }

  @override
  void didUpdateWidget(NativeVaultBar old) {
    super.didUpdateWidget(old);
    _channel?.invokeMethod('update', _params(context));
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: _height,
        child: UiKitView(
          viewType: 'cozysafe/tabbar',
          creationParams: _params(context),
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: _created,
          // The bar takes every touch on it: taps and the system's drag between tabs.
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
          },
        ),
      );
}
