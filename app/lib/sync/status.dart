import 'package:flutter/foundation.dart';

import '../src/rust/api/sync.dart' as sync;

/// A sync under way, as the lock screen shows it (owner 2026-10-26: "even if the vault
/// locks, the screen must stay on and the sync must keep running"). The progress page
/// (lib/sync/progress.dart) keeps it up to date; null when no sync runs.
class SyncStatus {
  const SyncStatus({required this.drive, required this.kind, this.done = 0, this.total = 0, this.bytes = 0, this.bytesTotal = 0});

  /// Google Drive (true) or a nearby device.
  final bool drive;
  /// [sync.SyncStep.done] once it finished behind the lock.
  final sync.SyncStep kind;
  final int done;
  final int total;
  final int bytes;
  final int bytesTotal;

  bool get finished => kind == sync.SyncStep.done;

  /// How far the step under way is, 0 to 1, or null before there is a count.
  double? get fraction {
    if (finished) return 1;
    if (bytesTotal > 0) return (bytes / bytesTotal).clamp(0, 1);
    if (total > 0) return (done / total).clamp(0, 1);
    return null;
  }
}

final syncStatus = ValueNotifier<SyncStatus?>(null);
