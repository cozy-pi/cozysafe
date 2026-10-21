/// When and from which commit this build was made: CI passes them with --dart-define
/// (.github/actions/flutter-setup sets BUILD_DATE). Empty in a local build.
const buildDate = String.fromEnvironment('BUILD_DATE');
const buildCommit = String.fromEnvironment('BUILD_COMMIT');

/// "a1b2c3d", or empty.
String get buildCommitShort => buildCommit.length > 7 ? buildCommit.substring(0, 7) : buildCommit;
