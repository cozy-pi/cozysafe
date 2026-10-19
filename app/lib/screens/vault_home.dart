import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../src/rust/api/vault.dart' as rust;
import '../theme.dart';
import 'unlock.dart';

/// Inside an open vault. Locks the moment the app leaves the foreground.
class VaultHomeScreen extends StatefulWidget {
  const VaultHomeScreen({super.key, required this.libraryDir, required this.vault});

  final String libraryDir;
  final rust.VaultInfo vault;

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> with WidgetsBindingObserver {
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _lock();
    }
  }

  void _lock() {
    if (_locked) return;
    _locked = true;
    rust.lock();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => UnlockScreen(libraryDir: widget.libraryDir)),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = CsColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.vault.name),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: _lock,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: Text(l.lockVault),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.inventory_2_outlined, size: 48, color: c.muted),
                  const SizedBox(height: 16),
                  Text(
                    l.emptyVaultTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.emptyVaultBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.muted, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
