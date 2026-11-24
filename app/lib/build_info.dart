/// When and from which commit this build was made: CI passes them with --dart-define
/// (.github/actions/flutter-setup sets BUILD_DATE). Empty in a local build.
const buildDate = String.fromEnvironment('BUILD_DATE');
const buildCommit = String.fromEnvironment('BUILD_COMMIT');

/// "a1b2c3d", or empty.
String get buildCommitShort => buildCommit.length > 7 ? buildCommit.substring(0, 7) : buildCommit;

/// Cozy Safe Beta (com.cozypi.cozysafe.beta, release.yml beta=true): the second app that
/// installs next to Cozy Safe. It says so on its icon and with a small tag in the app
/// ([BetaTag]), so the two are never mixed up (owner 2026-11-24).
const _betaBuild = bool.fromEnvironment('BETA');

/// For tests and the mockups.
bool? debugBeta;
bool get betaBuild => debugBeta ?? _betaBuild;
