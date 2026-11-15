import 'l10n/app_localizations.dart';

/// What to say after an action on several items, when some of them could not be done:
/// the truth with both counts, never a plain "done" (2026-11-15 review: failures were
/// swallowed and the message always reported success).

/// After moving to Recently deleted: [moved] went, [failed] did not.
String trashedText(AppLocalizations l, {required int moved, required int failed}) => failed > 0
    ? l.movedToTrashSome(moved, failed)
    : moved == 1
        ? l.movedToTrash
        : l.movedToTrashCount(moved);

/// After Restore (or Undo): null when all came back, which the list shows by itself.
String? restoredText(AppLocalizations l, {required int restored, required int failed}) =>
    failed > 0 ? l.restoredSome(restored, failed) : null;

/// After Delete for good: null when all are gone.
String? deletedForGoodText(AppLocalizations l, {required int deleted, required int failed}) =>
    failed > 0 ? l.deletedForGoodSome(deleted, failed) : null;
