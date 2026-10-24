import 'package:google_sign_in/google_sign_in.dart';

/// Only the files Cozy Safe itself makes in the person's Drive (non-sensitive scope:
/// the app sees nothing else there).
const driveScope = 'https://www.googleapis.com/auth/drive.file';

/// The Web OAuth client of the Google Cloud project `cozy-safe`: Android's sign-in needs it
/// as `serverClientId` (iOS reads GIDClientID from Info.plist). Empty until it is made.
const _serverClientId = '';

Future<void>? _ready;

Future<void> _init() => _ready ??= GoogleSignIn.instance.initialize(
      serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
    );

/// A signed-in Google account and an access token for [driveScope].
typedef DriveSession = ({String email, String token});

/// Sign in (quietly when the person already did on this device), then get the token.
/// Null when the person cancels.
Future<DriveSession?> driveSignIn() async {
  try {
    await _init();
    final g = GoogleSignIn.instance;
    final user = await g.attemptLightweightAuthentication() ?? await g.authenticate(scopeHint: const [driveScope]);
    final auth = await user.authorizationClient.authorizationForScopes(const [driveScope]) ??
        await user.authorizationClient.authorizeScopes(const [driveScope]);
    return (email: user.email, token: auth.accessToken);
  } on GoogleSignInException catch (e) {
    if (e.code == GoogleSignInExceptionCode.canceled) return null;
    rethrow;
  }
}

/// Forget the Google account on this device (the Drive folder stays).
Future<void> driveSignOut() async {
  await _init();
  await GoogleSignIn.instance.signOut();
}
