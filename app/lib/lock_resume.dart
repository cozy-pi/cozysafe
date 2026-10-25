import 'package:flutter/widgets.dart';

/// Every page opened in the vault stays under the lock screen (owner 2026-10-25: after
/// opening the vault again the person is back exactly where they were, the 24 words and
/// password pages too). Only what floats over a page closes: dialogs, sheets, cards and
/// menus, which count as Cancel. A page that holds something of its own (a password typed,
/// the words shown, a player, a sync) reacts through [VaultLockAware].
bool keptOnLock(Route<dynamic> route) => route.isFirst || route is PageRoute;

/// Whether the open vault is locked now, its pages waiting under the lock screen.
final vaultLock = VaultLockState();

class VaultLockState extends ChangeNotifier {
  bool _locked = false;
  bool get locked => _locked;

  void set(bool locked) {
    if (_locked == locked) return;
    _locked = locked;
    notifyListeners();
  }

  /// Another vault opened: the pages kept under the lock are gone, nobody to tell.
  void reset() => _locked = false;
}

/// A page kept under the lock that holds something of its own: [vaultLocking] runs as the
/// vault locks (drop typed secrets, hide shown ones, stop what needs the key) and
/// [vaultUnlocked] when the same vault opens again (pick up where it was).
mixin VaultLockAware<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    vaultLock.addListener(_vaultLockChanged);
  }

  @override
  void dispose() {
    vaultLock.removeListener(_vaultLockChanged);
    super.dispose();
  }

  void _vaultLockChanged() {
    if (!mounted) return;
    vaultLock.locked ? vaultLocking() : vaultUnlocked();
  }

  void vaultLocking() {}
  void vaultUnlocked() {}
}
