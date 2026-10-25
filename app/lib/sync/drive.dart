import 'package:google_sign_in/google_sign_in.dart';

import '../platform.dart';

/// Only the files Cozy Safe itself makes in the person's Drive (non-sensitive scope:
/// the app sees nothing else there).
const driveScope = 'https://www.googleapis.com/auth/drive.file';

/// The Web OAuth client of the Google Cloud project `cozy-safe`: Android's sign-in needs it
/// as `serverClientId` (iOS reads GIDClientID from Info.plist). Not a secret: a client
/// id only names the app to Google; the Android clients beside it are tied to the
/// package name and the signing keys.
const _serverClientId = '521746667657-095mlmivp3aj7ot62kd7tnml25ia1mhh.apps.googleusercontent.com';

/// Whether Google sign-in can work on this device: Android needs the Web client above.
bool get driveReady => !Device.android || _serverClientId.isNotEmpty;

/// A short name for why sign-in failed, shown after the sentence.
String driveErrorCode(Object e) => e is GoogleSignInException ? e.code.name : e.runtimeType.toString();

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
