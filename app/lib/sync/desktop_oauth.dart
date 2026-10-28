import 'dart:convert';
import 'dart:io' show Process;
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lock_guard.dart';
import '../platform.dart';
import '../src/rust/api/google.dart' as rust;

/// Google sign-in for Drive on computers (macOS, Windows, Linux), where Google's sign-in
/// SDKs do not run: the "installed app" flow (RFC 8252) with an OAuth client of type
/// "Desktop app" (docs/adr/0003-sync.md, "Google Cloud setup"). drive.dart calls it on
/// computers; phones keep `google_sign_in`.
///
/// 1. A loopback listener on 127.0.0.1 at a free port (in Rust, cs-net: Dart keeps no
///    network code, `offline.dart`).
/// 2. The system browser opens Google's sign-in page with PKCE (S256) and a random
///    state; scopes `drive.file` plus `openid email` (to name the account).
/// 3. Google sends the browser back to `http://127.0.0.1:<port>/?state=…&code=…`; the
///    state is compared in constant time, the code exchanged for tokens with the
///    verifier.
/// 4. The refresh token is kept in the system's secure store; a quiet sign-in is a
///    refresh. Removing the account revokes it at Google and deletes it here.
///
/// Neither codes nor tokens are logged. The client secret of a desktop client is not
/// a secret (Google says so for installed apps); PKCE is what protects the code.

/// The OAuth client of type "Desktop app", from the build
/// (`--dart-define=DRIVE_DESKTOP_CLIENT_ID=… --dart-define=DRIVE_DESKTOP_CLIENT_SECRET=…`,
/// release.yml). Empty: computers do not offer Google Drive.
const desktopClientId = String.fromEnvironment('DRIVE_DESKTOP_CLIENT_ID');
const desktopClientSecret = String.fromEnvironment('DRIVE_DESKTOP_CLIENT_SECRET');

/// Whether this build can sign in to Google on this computer.
bool get desktopDriveConfigured => Device.desktop && desktopClientId.isNotEmpty && desktopClientSecret.isNotEmpty;

const _authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
const desktopScopes = 'openid email https://www.googleapis.com/auth/drive.file';

/// How long the browser has to come back.
const signInWait = Duration(minutes: 5);

/// A sign-in that failed, with a short code for the error log and the toast
/// (`network`, `token-400`, `state-mismatch`, `no-browser`, …).
class DesktopSignInException implements Exception {
  const DesktopSignInException(this.code);
  final String code;
  @override
  String toString() => 'DesktopSignInException($code)';
}

/// URL-safe base64 without padding (RFC 7636, appendix A).
String base64UrlNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// A PKCE pair: the verifier stays here, the challenge goes in the sign-in address.
typedef Pkce = ({String verifier, String challenge});

/// The S256 challenge of [verifier].
String pkceChallenge(String verifier) => base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

/// A new verifier of 64 characters (48 random bytes) and its challenge.
Pkce newPkce(Random random) {
  final verifier = base64UrlNoPad(List.generate(48, (_) => random.nextInt(256)));
  return (verifier: verifier, challenge: pkceChallenge(verifier));
}

/// A new state: 32 random bytes.
String newState(Random random) => base64UrlNoPad(List.generate(32, (_) => random.nextInt(256)));

/// Equal strings, compared in a time that does not depend on where they differ.
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}

String redirectUri(int port) => 'http://127.0.0.1:$port/';

/// Google's sign-in page for this sign-in.
Uri signInUrl({required String clientId, required int port, required String state, required String challenge, String? hint}) =>
    Uri.parse(_authEndpoint).replace(queryParameters: {
      'client_id': clientId,
      'redirect_uri': redirectUri(port),
      'response_type': 'code',
      'scope': desktopScopes,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      // A refresh token every time (Google gives one only with consent), and a choice of
      // account after "Remove account".
      'prompt': 'select_account consent',
      if (hint != null && hint.isNotEmpty) 'login_hint': hint,
    });

/// The code from the redirect's query. Null when the person declined; throws when the
/// state is not this sign-in's, or Google sent an error or nothing.
String? codeFromRedirect(String query, String state) {
  final Map<String, String> q;
  try {
    q = Uri.splitQueryString(query);
  } catch (_) {
    throw const DesktopSignInException('bad-redirect');
  }
  if (!constantTimeEquals(q['state'] ?? '', state)) throw const DesktopSignInException('state-mismatch');
  final error = q['error'];
  if (error == 'access_denied') return null;
  if (error != null) throw DesktopSignInException('google-${_word(error)}');
  final code = q['code'];
  if (code == null || code.isEmpty) throw const DesktopSignInException('bad-redirect');
  return code;
}

/// Letters, digits and '-' only (Google's error words, for the error log).
String _word(String s) {
  final w = s.replaceAll('_', '-').replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
  return w.length > 40 ? w.substring(0, 40) : w;
}

/// What came of a token request.
typedef Tokens = ({String accessToken, Duration expiresIn, String? refreshToken, String? email});

/// Reads Google's answer to `/token`. Throws [DesktopSignInException]: `network` (no
/// answer), `invalid-grant` (refresh token revoked or expired: sign in again),
/// `token-<status>` otherwise.
Tokens parseTokens(int status, String body) {
  if (status == 0) throw const DesktopSignInException('network');
  Object? json;
  try {
    json = jsonDecode(body);
  } catch (_) {}
  final m = json is Map<String, dynamic> ? json : const <String, dynamic>{};
  if (status != 200) {
    if (m['error'] == 'invalid_grant') throw const DesktopSignInException('invalid-grant');
    throw DesktopSignInException('token-$status');
  }
  final access = m['access_token'];
  if (access is! String || access.isEmpty) throw const DesktopSignInException('token-no-access');
  final expires = m['expires_in'];
  final refresh = m['refresh_token'];
  final id = m['id_token'];
  return (
    accessToken: access,
    expiresIn: Duration(seconds: expires is int && expires > 0 ? expires : 3600),
    refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
    email: id is String ? emailFromIdToken(id) : null,
  );
}

/// The `email` claim of an ID token. Its signature is not checked: it came straight
/// from Google's token endpoint over TLS, which OpenID Connect allows (Core 1.0,
/// 3.1.3.7), and it only names the account on screen.
String? emailFromIdToken(String idToken) {
  final parts = idToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final email = payload is Map ? payload['email'] : null;
    return email is String && email.contains('@') ? email : null;
  } catch (_) {
    return null;
  }
}

/// `application/x-www-form-urlencoded`.
String formEncode(Map<String, String> fields) => Uri(queryParameters: fields).query;

/// The network and the system, replaced in tests.
abstract class DesktopOAuthIo {
  /// Listen on 127.0.0.1; the port, 0 when it could not.
  Future<int> listen();

  /// The redirect's query, or null after [wait] or a cancel.
  Future<String?> redirect(int port, Duration wait);

  void cancel();

  /// POST [form] to Google's `/token` ([revoke] false) or `/revoke`; status 0 when the
  /// network failed.
  Future<({int status, String body})> post(String form, {bool revoke = false});

  Future<bool> openBrowser(Uri url);
}

/// Where the refresh token is kept, replaced in tests.
abstract class RefreshTokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

/// One signed-in account and an access token.
typedef DesktopSession = ({String email, String token});

class DesktopOAuth {
  DesktopOAuth({
    required this.clientId,
    required this.clientSecret,
    DesktopOAuthIo? io,
    RefreshTokenStore? store,
    Random? random,
    DateTime Function()? now,
  })  : io = io ?? _RustIo(),
        store = store ?? _SecureStore(),
        _random = random ?? Random.secure(),
        _now = now ?? DateTime.now;

  final String clientId;
  final String clientSecret;
  final DesktopOAuthIo io;
  final RefreshTokenStore store;
  final Random _random;
  final DateTime Function() _now;

  String? _access;
  DateTime? _expires;
  Future<String?>? _refreshing;

  /// Sign in through the browser. Null when the person cancelled, declined or did not
  /// come back within [signInWait]. [hint]: the account used before, preselected.
  Future<DesktopSession?> signIn({String? hint}) async {
    final port = await io.listen();
    if (port == 0) throw const DesktopSignInException('no-listen');
    final pkce = newPkce(_random);
    final state = newState(_random);
    final url = signInUrl(clientId: clientId, port: port, state: state, challenge: pkce.challenge, hint: hint);
    if (!await io.openBrowser(url)) {
      io.cancel();
      throw const DesktopSignInException('no-browser');
    }
    final query = await io.redirect(port, signInWait);
    if (query == null) return null;
    final code = codeFromRedirect(query, state);
    if (code == null) return null;
    final r = await io.post(formEncode({
      'grant_type': 'authorization_code',
      'code': code,
      'code_verifier': pkce.verifier,
      'client_id': clientId,
      'client_secret': clientSecret,
      'redirect_uri': redirectUri(port),
    }));
    final t = parseTokens(r.status, r.body);
    final email = t.email ?? hint;
    if (email == null) throw const DesktopSignInException('no-email');
    if (t.refreshToken != null) await store.write(t.refreshToken!);
    _keep(t);
    return (email: email, token: t.accessToken);
  }

  /// An access token without the browser: the one in memory while it has more than a
  /// minute left, else a refresh. Null when there is no refresh token or Google refused
  /// it (the stored one is then deleted: sign in again). Throws on network errors.
  Future<String?> accessToken() async {
    final a = _access, e = _expires;
    if (a != null && e != null && _now().isBefore(e.subtract(const Duration(minutes: 1)))) return a;
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _refresh() async {
    final refresh = await store.read();
    if (refresh == null || refresh.isEmpty) return null;
    final r = await io.post(formEncode({
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
      'client_id': clientId,
      'client_secret': clientSecret,
    }));
    final Tokens t;
    try {
      t = parseTokens(r.status, r.body);
    } on DesktopSignInException catch (e) {
      if (e.code == 'invalid-grant') {
        await store.delete();
        return null;
      }
      rethrow;
    }
    // Google may rotate the refresh token.
    if (t.refreshToken != null && t.refreshToken != refresh) await store.write(t.refreshToken!);
    _keep(t);
    return t.accessToken;
  }

  void _keep(Tokens t) {
    _access = t.accessToken;
    _expires = _now().add(t.expiresIn);
  }

  /// Forget the account here, and take back the app's access at Google (revoking the
  /// refresh token ends the whole grant). The token is deleted here even when Google
  /// cannot be reached; there is no "sign out but keep the grant" on computers, since
  /// a refresh token nobody holds any more should not stay valid.
  Future<void> signOut() async {
    io.cancel();
    final refresh = await store.read();
    final token = refresh ?? _access;
    _access = null;
    _expires = null;
    await store.delete();
    if (token != null && token.isNotEmpty) {
      try {
        await io.post(formEncode({'token': token}), revoke: true);
      } catch (_) {} // offline: at least forgotten here
    }
  }

  /// Stop waiting for the browser.
  void cancel() => io.cancel();
}

/// The app's: cs-net through the bridge, the system's browser.
class _RustIo implements DesktopOAuthIo {
  static const _channel = MethodChannel('cozysafe/signin');

  @override
  Future<int> listen() => rust.googleLoopbackOpen();

  @override
  Future<String?> redirect(int port, Duration wait) => rust.googleLoopbackWait(port: port, seconds: wait.inSeconds);

  @override
  void cancel() => rust.googleLoopbackCancel();

  @override
  Future<({int status, String body})> post(String form, {bool revoke = false}) async {
    final a = await rust.googleOauthPost(endpoint: revoke ? rust.GoogleEndpoint.revoke : rust.GoogleEndpoint.token, form: form);
    return (status: a.status, body: a.body);
  }

  /// Only Google's sign-in page ever opens this way (checked again on macOS natively).
  @override
  Future<bool> openBrowser(Uri url) async {
    if (url.scheme != 'https' || url.host != 'accounts.google.com') return false;
    LockGuard.allowAway();
    final s = url.toString();
    try {
      if (Device.macOS) return await _channel.invokeMethod<bool>('open', s) ?? false;
      if (Device.windows) {
        await Process.start('rundll32', ['url.dll,FileProtocolHandler', s]);
        return true;
      }
      if (Device.linux) {
        await Process.start('xdg-open', [s]);
        return true;
      }
    } catch (_) {}
    return false;
  }
}

/// The system's secure store: Keychain (legacy, no keychain-sharing entitlement needed,
/// like the Secret Key), Windows Credential Manager, libsecret on Linux.
class _SecureStore implements RefreshTokenStore {
  static const _key = 'drive-refresh-token';
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(accountName: 'cozysafe.drive', usesDataProtectionKeychain: false, synchronizable: false),
  );

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}
