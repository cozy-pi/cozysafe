import 'dart:convert';
import 'dart:math';

import 'package:cozysafe/sync/desktop_oauth.dart';
import 'package:flutter_test/flutter_test.dart';

/// Google sign-in on computers (lib/sync/desktop_oauth.dart), with the network and the
/// browser faked: nothing here leaves the machine.
void main() {
  group('PKCE and state', () {
    test('S256 challenge matches RFC 7636 appendix B', () {
      expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('verifiers are 64 unreserved characters, different each time', () {
      final r = Random(1);
      final a = newPkce(r), b = newPkce(r);
      expect(a.verifier, hasLength(64));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a.verifier), isTrue);
      expect(a.verifier, isNot(b.verifier));
      expect(a.challenge, pkceChallenge(a.verifier));
      expect(newState(r), hasLength(43));
    });

    test('constant-time compare', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'ab'), isFalse);
      expect(constantTimeEquals('', 'a'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });
  });

  test('the sign-in address', () {
    final u = signInUrl(clientId: 'cid', port: 51234, state: 'st', challenge: 'ch', hint: 'a@b.c');
    expect(u.scheme, 'https');
    expect(u.host, 'accounts.google.com');
    expect(u.path, '/o/oauth2/v2/auth');
    expect(u.queryParameters, {
      'client_id': 'cid',
      'redirect_uri': 'http://127.0.0.1:51234/',
      'response_type': 'code',
      'scope': 'openid email https://www.googleapis.com/auth/drive.file',
      'state': 'st',
      'code_challenge': 'ch',
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'select_account consent',
      'login_hint': 'a@b.c',
    });
    expect(signInUrl(clientId: 'c', port: 1, state: 's', challenge: 'x').queryParameters.containsKey('login_hint'), isFalse);
  });

  group('the redirect', () {
    test('gives the code when the state is this sign-in\'s', () {
      expect(codeFromRedirect('state=s1&code=4%2Fabc&scope=x', 's1'), '4/abc');
    });
    test('refuses another state, or none', () {
      expect(() => codeFromRedirect('state=s2&code=c', 's1'), throwsA(_code('state-mismatch')));
      expect(() => codeFromRedirect('code=c', 's1'), throwsA(_code('state-mismatch')));
    });
    test('declined is null, other errors throw', () {
      expect(codeFromRedirect('state=s&error=access_denied', 's'), isNull);
      expect(() => codeFromRedirect('state=s&error=invalid_scope', 's'), throwsA(_code('google-invalid-scope')));
      expect(() => codeFromRedirect('state=s', 's'), throwsA(_code('bad-redirect')));
    });
  });

  group('token answers', () {
    test('reads the tokens and the email of the ID token', () {
      final t = parseTokens(200, _tokenBody(refresh: 'r1', email: 'me@example.com'));
      expect(t.accessToken, 'a1');
      expect(t.expiresIn, const Duration(seconds: 3599));
      expect(t.refreshToken, 'r1');
      expect(t.email, 'me@example.com');
    });
    test('a refresh answer has no refresh token or ID token', () {
      final t = parseTokens(200, '{"access_token":"a2","expires_in":3599,"token_type":"Bearer"}');
      expect(t.accessToken, 'a2');
      expect(t.refreshToken, isNull);
      expect(t.email, isNull);
    });
    test('errors', () {
      expect(() => parseTokens(0, ''), throwsA(_code('network')));
      expect(() => parseTokens(400, '{"error":"invalid_grant"}'), throwsA(_code('invalid-grant')));
      expect(() => parseTokens(401, '{"error":"invalid_client"}'), throwsA(_code('token-401')));
      expect(() => parseTokens(500, 'not json'), throwsA(_code('token-500')));
      expect(() => parseTokens(200, '{}'), throwsA(_code('token-no-access')));
    });
    test('a damaged ID token names no one', () {
      expect(emailFromIdToken('x.y'), isNull);
      expect(emailFromIdToken('x.%%%.z'), isNull);
      expect(emailFromIdToken(_idToken({'sub': '1'})), isNull);
    });
  });

  group('the flow', () {
    test('signs in, keeps the refresh token, refreshes quietly', () async {
      final io = _FakeIo();
      final store = _MemStore();
      var now = DateTime(2026, 10, 28, 12);
      final o = DesktopOAuth(clientId: 'cid', clientSecret: 'sec', io: io, store: store, random: Random(7), now: () => now);
      io.onOpen = (url) {
        final q = url.queryParameters;
        io.query = 'state=${Uri.encodeQueryComponent(q['state']!)}&code=c1';
        io.challenge = q['code_challenge'];
      };
      io.answers.add((status: 200, body: _tokenBody(refresh: 'r1', email: 'me@example.com')));
      final s = await o.signIn();
      expect(s, (email: 'me@example.com', token: 'a1'));
      expect(store.token, 'r1');

      final exchange = Uri.splitQueryString(io.posts.single.form);
      expect(exchange['grant_type'], 'authorization_code');
      expect(exchange['code'], 'c1');
      expect(exchange['redirect_uri'], 'http://127.0.0.1:${_FakeIo.port}/');
      expect(exchange['client_id'], 'cid');
      expect(exchange['client_secret'], 'sec');
      expect(pkceChallenge(exchange['code_verifier']!), io.challenge);

      // Still fresh: no request.
      expect(await o.accessToken(), 'a1');
      expect(io.posts, hasLength(1));
      // Near expiry: one refresh with the stored token.
      now = now.add(const Duration(minutes: 59));
      io.answers.add((status: 200, body: '{"access_token":"a2","expires_in":3599}'));
      expect(await o.accessToken(), 'a2');
      final refresh = Uri.splitQueryString(io.posts.last.form);
      expect(refresh['grant_type'], 'refresh_token');
      expect(refresh['refresh_token'], 'r1');
      expect(io.posts.last.revoke, isFalse);
    });

    test('another state is refused before any token request', () async {
      final io = _FakeIo()..onOpen = (_) {};
      io.query = 'state=forged&code=c1';
      final o = DesktopOAuth(clientId: 'c', clientSecret: 's', io: io, store: _MemStore(), random: Random(1));
      await expectLater(o.signIn(), throwsA(_code('state-mismatch')));
      expect(io.posts, isEmpty);
    });

    test('no answer from the browser, or declined: null', () async {
      final io = _FakeIo()..onOpen = (_) {};
      final o = DesktopOAuth(clientId: 'c', clientSecret: 's', io: io, store: _MemStore(), random: Random(1));
      expect(await o.signIn(), isNull);
      io.onOpen = (url) => io.query = 'state=${Uri.encodeQueryComponent(url.queryParameters['state']!)}&error=access_denied';
      expect(await o.signIn(), isNull);
      expect(io.posts, isEmpty);
    });

    test('no browser: an error, and the listener is closed', () async {
      final io = _FakeIo()..browser = false;
      final o = DesktopOAuth(clientId: 'c', clientSecret: 's', io: io, store: _MemStore(), random: Random(1));
      await expectLater(o.signIn(), throwsA(_code('no-browser')));
      expect(io.cancelled, 1);
    });

    test('a revoked refresh token is deleted and asks for the browser', () async {
      final io = _FakeIo();
      final store = _MemStore()..token = 'old';
      final o = DesktopOAuth(clientId: 'c', clientSecret: 's', io: io, store: store);
      io.answers.add((status: 400, body: '{"error":"invalid_grant"}'));
      expect(await o.accessToken(), isNull);
      expect(store.token, isNull);
    });

    test('offline refresh throws and keeps the token', () async {
      final io = _FakeIo();
      final store = _MemStore()..token = 'r';
      final o = DesktopOAuth(clientId: 'c', clientSecret: 's', io: io, store: store);
      io.answers.add((status: 0, body: ''));
      await expectLater(o.accessToken(), throwsA(_code('network')));
      expect(store.token, 'r');
    });

    test('sign out revokes at Google and deletes, even offline', () async {
      final io = _FakeIo();
      final store = _MemStore()..token = 'r9';
      final o = DesktopOAuth(clientId: 'c', clientSecret: 's', io: io, store: store);
      io.answers.add((status: 0, body: ''));
      await o.signOut();
      expect(store.token, isNull);
      expect(io.posts.single.revoke, isTrue);
      expect(Uri.splitQueryString(io.posts.single.form), {'token': 'r9'});
    });
  });

  test('form encoding', () {
    expect(formEncode({'a': 'x y', 'b': '4/&='}), 'a=x+y&b=4%2F%26%3D');
  });
}

Matcher _code(String code) => isA<DesktopSignInException>().having((e) => e.code, 'code', code);

String _idToken(Map<String, Object> claims) =>
    '${base64UrlNoPad(utf8.encode('{"alg":"RS256"}'))}.${base64UrlNoPad(utf8.encode(jsonEncode(claims)))}.sig';

String _tokenBody({String? refresh, String? email}) => jsonEncode({
      'access_token': 'a1',
      'expires_in': 3599,
      'token_type': 'Bearer',
      'scope': 'openid https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email',
      'refresh_token': ?refresh,
      if (email != null) 'id_token': _idToken({'sub': '1', 'email': email}),
    });

class _FakeIo implements DesktopOAuthIo {
  static const port = 51234;
  String? query;
  String? challenge;
  bool browser = true;
  int cancelled = 0;
  void Function(Uri url)? onOpen;
  final answers = <({int status, String body})>[];
  final posts = <({String form, bool revoke})>[];

  @override
  Future<int> listen() async => port;

  @override
  Future<String?> redirect(int port, Duration wait) async {
    expect(port, _FakeIo.port);
    expect(wait, signInWait);
    return query;
  }

  @override
  void cancel() => cancelled++;

  @override
  Future<({int status, String body})> post(String form, {bool revoke = false}) async {
    posts.add((form: form, revoke: revoke));
    return answers.removeAt(0);
  }

  @override
  Future<bool> openBrowser(Uri url) async {
    onOpen?.call(url);
    return browser;
  }
}

class _MemStore implements RefreshTokenStore {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String t) async => token = t;
  @override
  Future<void> delete() async => token = null;
}
