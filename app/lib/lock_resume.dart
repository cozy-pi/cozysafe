import 'package:flutter/widgets.dart';

/// Pages kept under the lock screen (owner 2026-10-24: locking and coming back lost the
/// settings page the person was on). Only pages that show no vault content: Settings and
/// its own pages. Everything else (a photo, a note, the 24 words, menus) is closed when
/// the vault locks, so nothing decrypted stays behind the lock.
const keepOnLock = RouteSettings(name: 'keep-on-lock');

/// Pop down to this when locking: the vault's home, or a page kept under the lock.
bool keptOnLock(Route<dynamic> route) => route.isFirst || route.settings.name == keepOnLock.name;

/// Counts the vault's locks: a page kept under the lock that holds a secret of its own
/// (a password typed earlier) listens and drops it, so nothing typed waits in memory
/// while the vault is locked.
final vaultLocks = ValueNotifier<int>(0);
