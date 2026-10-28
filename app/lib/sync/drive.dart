import 'package:google_sign_in/google_sign_in.dart';

import '../platform.dart';
import '../prefs.dart';
import 'desktop_oauth.dart';

/// The Google account Drive was last allowed with on this device (its address only).
const _accountPref = 'drive-account';

/// Only the files Cozy Safe itself makes in the person's Drive (non-sensitive scope:
/// the app sees nothing else there).
const driveScope = 'https://www.googleapis.com/auth/drive.file';

/// The Web OAuth client of the Google Cloud project `cozy-safe`: Android's sign-in needs it
/// as `serverClientId` (iOS reads GIDClientID from Info.plist). Not a secret: a client
/// id only names the app to Google; the Android clients beside it are tied to the
/// package name and the signing keys.
const _serverClientId = '521746667657-095mlmivp3aj7ot62kd7tnml25ia1mhh.apps.googleusercontent.com';

/// Whether Google sign-in can work on this device: Android needs the Web client above,
/// computers a "Desktop app" client in the build (desktop_oauth.dart).
bool get driveReady => Device.desktop ? desktopDriveConfigured : !Device.android || _serverClientId.isNotEmpty;

/// Whether this device offers Google Drive at all: phones, and computers whose build
/// carries the desktop client.
bool get driveOffered => Device.iOS || Device.android || desktopDriveConfigured;

/// A short name for why sign-in failed, shown after the sentence.
String driveErrorCode(Object e) => switch (e) {
      GoogleSignInException() => e.code.name,
      DesktopSignInException() => e.code,
      _ => e.runtimeType.toString(),
    };

/// Computers: Google's installed-app flow instead of the SDK (desktop_oauth.dart).
DesktopOAuth? _desktopOAuth;
DesktopOAuth get _desktop => _desktopOAuth ??= DesktopOAuth(clientId: desktopClientId, clientSecret: desktopClientSecret);

Future<void>? _ready;

Future<void> _init() => _ready ??= GoogleSignIn.instance.initialize(
      serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
    );

/// A signed-in Google account and an access token for [driveScope].
typedef DriveSession = ({String email, String token});

/// Sign in (quietly when the person already did on this device), then get the token.
/// Null when the person cancels.
Future<DriveSession?> driveSignIn() async {
  if (Device.desktop) return _desktopSignIn();
  try {
    await _init();
    final g = GoogleSignIn.instance;
    // Android: the "quiet" sign-in still shows Credential Manager's sheet every time
    // (owner 2026-10-25: a Google box at each sync, iPhone shows none). Once Drive was
    // allowed, ask for the token alone, which shows nothing, with the account remembered.
    final known = Prefs.read(_accountPref);
    if (Device.android && known != null && known.isNotEmpty) {
      final quiet = await g.authorizationClient.authorizationForScopes(const [driveScope]);
      if (quiet != null) return (email: known, token: quiet.accessToken);
    }
    final user = await g.attemptLightweightAuthentication() ?? await g.authenticate(scopeHint: const [driveScope]);
    final auth = await user.authorizationClient.authorizationForScopes(const [driveScope]) ??
        await user.authorizationClient.authorizeScopes(const [driveScope]);
    Prefs.write(_accountPref, user.email);
    return (email: user.email, token: auth.accessToken);
  } on GoogleSignInException catch (e) {
    if (e.code == GoogleSignInExceptionCode.canceled) return null;
    rethrow;
  }
}

/// A token without showing anything (automatic sync): null when Google would need the
/// person (signed out, access taken back, offline), and the sync waits for a tap.
Future<DriveSession?> driveSignInQuietly() async {
  final known = driveAccount;
  if (known == null) return null;
  if (Device.desktop) {
    if (!desktopDriveConfigured) return null;
    try {
      final token = await _desktop.accessToken();
      return token == null ? null : (email: known, token: token);
    } catch (_) {
      return null;
    }
  }
  try {
    await _init();
    final g = GoogleSignIn.instance;
    if (Device.android) {
      final quiet = await g.authorizationClient.authorizationForScopes(const [driveScope]);
      return quiet == null ? null : (email: known, token: quiet.accessToken);
    }
    final user = await g.attemptLightweightAuthentication();
    if (user == null) return null;
    final auth = await user.authorizationClient.authorizationForScopes(const [driveScope]);
    return auth == null ? null : (email: user.email, token: auth.accessToken);
  } catch (_) {
    return null;
  }
}

/// The Google account Drive was last allowed with here, if any (for Settings → Sync).
String? get driveAccount {
  final a = Prefs.read(_accountPref);
  return a == null || a.isEmpty ? null : a;
}

/// Forget the Google account on this device (the Drive folder stays). [revoke] also takes
/// back Cozy Safe's access at Google ("Remove account"); without it, the next sign-in
/// offers the account picker again.
Future<void> driveSignOut({bool revoke = false}) async {
  Prefs.write(_accountPref, '');
  if (Device.desktop) {
    // Always revoked on computers: the refresh token is deleted here either way.
    if (desktopDriveConfigured) await _desktop.signOut();
    return;
  }
  await _init();
  final g = GoogleSignIn.instance;
  if (revoke) {
    try {
      await g.disconnect();
      return;
    } catch (_) {} // offline: at least forget it here
  }
  await g.signOut();
}

/// Computers: a refresh when Drive was allowed before (nothing shown), else the browser.
Future<DriveSession?> _desktopSignIn() async {
  if (!desktopDriveConfigured) throw const DesktopSignInException('no-client');
  final known = driveAccount;
  if (known != null) {
    final token = await _desktop.accessToken();
    if (token != null) return (email: known, token: token);
  }
  final s = await _desktop.signIn(hint: known);
  if (s != null) Prefs.write(_accountPref, s.email);
  return s;
}
