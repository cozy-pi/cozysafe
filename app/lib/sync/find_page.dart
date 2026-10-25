import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/sync.dart' as sync;
import '../platform.dart';
import '../theme.dart';
import '../widgets/vault_bar.dart' show pushPage;
import 'join_page.dart';

/// What to do with the code of the device found (the person already allowed it).
typedef OnFound = Future<void> Function(BuildContext context, String code);

/// The other device shows six digits: look for it on this Wi-Fi (the person allowed it,
/// naming [address]) and take the digits. Only a device holding the same vault (or, when
/// restoring, taking the same 24 words) is found, and only the one showing the digits
/// matches; nothing is sent to anyone until then. The QR stays as a way round networks
/// where looking does not get through.
class FindDevicePage extends StatefulWidget {
  const FindDevicePage({super.key, required this.address, required this.onFound, required this.onScanned, this.words, this.lead});
  final String address;
  final OnFound onFound;
  /// A QR read instead: it may point anywhere, so this asks the person first.
  final OnCode onScanned;
  /// Restoring: the 24 words to look with (no vault here yet).
  final String? words;
  /// A sentence above the digits (the restore says what happens next).
  final String? lead;

  /// For the mockup renders: how many devices the look finds, without looking.
  static int? debugFound;

  @override
  State<FindDevicePage> createState() => _FindDevicePageState();
}

enum _Look { first, found, none }

class _FindDevicePageState extends State<FindDevicePage> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  _Look _look = _Look.first;
  int _found = 0;
  bool _wrong = false;
  bool _failed = false;
  bool _going = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    final debug = FindDevicePage.debugFound;
    if (debug != null) {
      _found = debug;
      _look = debug > 0 ? _Look.found : _Look.none;
    } else {
      _loop();
    }
  }

  @override
  void dispose() {
    _closed = true;
    if (FindDevicePage.debugFound == null) sync.p2PLookDone();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Look again every few seconds while the page is open: the other device may only now
  /// be showing its code.
  Future<void> _loop() async {
    while (!_closed && !_going) {
      try {
        final words = widget.words;
        final n = words == null
            ? await sync.p2PScan(ip: widget.address)
            : await sync.p2PScanRestore(ip: widget.address, words: words);
        if (_closed) return;
        setState(() {
          _found = n;
          _look = n > 0 ? _Look.found : _Look.none;
        });
        if (_text.text.length == 6) _try();
      } catch (_) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void _changed(String v) {
    if (_wrong) setState(() => _wrong = false);
    if (v.length == 6) _try();
    setState(() {});
  }

  Future<void> _try() async {
    if (_going) return;
    final code = FindDevicePage.debugFound == null ? sync.p2PFind(digits: _text.text) : null;
    if (code == null) {
      // Nothing seen yet: the next look tries again. Seen, but not with these digits.
      if (_look == _Look.found) {
        HapticFeedback.heavyImpact();
        setState(() => _wrong = true);
      }
      return;
    }
    _going = true;
    HapticFeedback.mediumImpact();
    _focus.unfocus();
    await widget.onFound(context, code);
    // Back from the session (done, or stopped): back to where it began; a new code next.
    if (mounted && !_closed) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final full = _text.text.length == 6;
    final (IconData icon, String status) = switch (_look) {
      _ when _failed => (Icons.error_outline_rounded, l.syncFailed),
      _Look.first => (Icons.wifi_find_rounded, l.syncFindSearching),
      _Look.found => (Icons.devices_rounded, l.syncFindFound(_found)),
      _Look.none => (Icons.wifi_off_rounded, l.syncFindNone),
    };
    // Nothing found: the two likely reasons a person can fix (words typed wrong when
    // restoring; iPhone's Local Network access refused).
    final hints = _look == _Look.none && !_failed
        ? [
            if (widget.words != null) l.syncFindNoneRestore,
            if (Device.iOS) l.syncFindLocalNetwork,
          ]
        : const <String>[];
    final String? note = _wrong
        ? l.syncFindWrong
        : (full && _look != _Look.found && !_failed)
            ? l.syncFindWaiting
            : null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        if (widget.lead != null) ...[
          Text(widget.lead!, textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 15, height: 1.4)),
          const SizedBox(height: 16),
        ],
        // Where the look is: one line that changes, so the person knows what is going on.
        Container(
          key: const ValueKey('sync-find-status'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(children: [
            if (_look == _Look.first && !_failed)
              const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
            else
              Icon(icon, size: 22, color: _look == _Look.found ? const Color(0xFF34C759) : c.muted),
            const SizedBox(width: 12),
            Expanded(child: Text(status, style: const TextStyle(fontSize: 15, height: 1.3, fontWeight: FontWeight.w600))),
          ]),
        ),
        for (final h in hints)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(h, style: TextStyle(color: c.muted, fontSize: 14, height: 1.35)),
          ),
        const SizedBox(height: 28),
        Text(l.syncFindLabel, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        _DigitBoxes(controller: _text, focus: _focus, wrong: _wrong, ink: ink, onChanged: _changed),
        const SizedBox(height: 12),
        SizedBox(
          height: 40,
          child: note == null
              ? null
              : Text(note,
                  key: const ValueKey('sync-find-note'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _wrong ? Theme.of(context).colorScheme.error : c.muted, fontSize: 14, height: 1.3)),
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          key: const ValueKey('sync-find-qr'),
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: Text(l.syncFindQr),
          onPressed: () => pushPage<void>(
            context,
            title: l.syncScanCode,
            builder: (_) => ScanCodePage(onSynced: () {}, onCode: widget.onScanned),
          ),
        ),
      ],
    );
  }
}

/// Six boxes over one hidden field: typing, paste and the number keyboard all work, and
/// the boxes show where the next digit goes.
class _DigitBoxes extends StatelessWidget {
  const _DigitBoxes({required this.controller, required this.focus, required this.wrong, required this.ink, required this.onChanged});
  final TextEditingController controller;
  final FocusNode focus;
  final bool wrong;
  final Color ink;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = CsColors.of(context);
    final error = Theme.of(context).colorScheme.error;
    final v = controller.text;
    return Stack(
      alignment: Alignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 6; i++) ...[
              if (i == 3) const SizedBox(width: 14),
              Container(
                width: 44,
                height: 56,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    width: 2,
                    color: wrong
                        ? error
                        : i == v.length && focus.hasFocus
                            ? ink
                            : c.border,
                  ),
                ),
                child: Text(i < v.length ? v[i] : '',
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ],
          ],
        ),
        // The field itself, invisible over the boxes: a tap anywhere on them types.
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              key: const ValueKey('sync-digits-field'),
              controller: controller,
              focusNode: focus,
              autofocus: true,
              keyboardType: TextInputType.number,
              autocorrect: false,
              enableSuggestions: false,
              showCursor: false,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
