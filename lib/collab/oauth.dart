import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../cloudsync/cloud_folder.dart';
import '../data/settings_repository.dart';
import '../l10n/language.dart';
import '../sync/caldav_service.dart' show SecretStore;
import 'share_storage.dart';

/// Signing in to a service with OAuth 2 for an app that cannot keep a secret (PKCE, RFC 7636): the person is
/// sent to the service's page in the browser, signs in and agrees, and the page returns to the app with a code
/// (`notation://oauth/<service>?code=...`) which is traded for tokens. The tokens are kept in the keystore.
class PkceOAuth {
  final String authorizeUrl;
  final String tokenUrl;
  String clientId;

  /// Where the service sends the person back to: has to be registered with the service.
  final String redirectUri;
  List<String> scopes;

  /// More for the sign-in address (`token_access_type=offline` for Dropbox).
  final Map<String, String> extraParams;

  /// Where the tokens (and a sign-in that is under way) are kept.
  final SecretStore _store;
  final Dio? _dio;
  final DateTime Function() _now;

  PkceOAuth({
    required this.authorizeUrl,
    required this.tokenUrl,
    required this.clientId,
    required this.redirectUri,
    required this.scopes,
    required SecretStore store,
    this.extraParams = const {},
    Dio? dio,
    DateTime Function()? now,
  })  : _store = store,
        _dio = dio,
        _now = now ?? DateTime.now;

  Map<String, Object?> _state = {};

  Future<void> load() async {
    final text = await _store.read();
    try {
      _state = text == null ? {} : (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      _state = {};
    }
  }

  Future<void> _save() => _state.isEmpty ? _store.delete() : _store.write(jsonEncode(_state));

  bool get connected => _state['refresh'] is String || _state['access'] is String;

  /// The token that renews the sign-in (null when not signed in, or when the service gave none).
  String? get refreshToken => _state['refresh'] is String ? _state['refresh'] as String : null;

  /// Takes the sign-in of another device of the same person: a refresh token is enough, a token for the moment is asked for when
  /// it is needed.
  Future<void> adopt(String refresh) async {
    _state = {'access': '', 'refresh': refresh, 'expires': 0};
    await _save();
  }

  static String _random(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// The page to open in the browser. Remembers what is needed to finish when the person comes back.
  Future<Uri> begin() async {
    final verifier = _random(64);
    final state = _random(24);
    _state = {..._state, 'pending': {'verifier': verifier, 'state': state}};
    await _save();
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final base = Uri.parse(authorizeUrl);
    return base.replace(queryParameters: {
      ...base.queryParameters,
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': scopes.join(' '),
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      ...extraParams,
    });
  }

  /// One client for all requests: a new one for each would open a new connection (and TLS handshake) every time, where a sync is hundreds
  /// of small requests that can share a few.
  Dio? _made;
  Dio get _client => _dio ?? (_made ??= Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 30), validateStatus: (s) => s != null && s < 500)));

  Future<Map<String, Object?>> _token(Map<String, String> form) async {
    final r = await _client.post<dynamic>(tokenUrl, data: form, options: Options(contentType: Headers.formUrlEncodedContentType, headers: {'Accept': 'application/json'}));
    final body = r.data is Map ? (r.data as Map).cast<String, Object?>() : <String, Object?>{};
    if (r.statusCode != 200 || body['access_token'] is! String) {
      final why = body['error_description'] ?? body['error'] ?? r.statusCode;
      throw StateError(tr('Signing in failed: {why}', {'why': why}));
    }
    return body;
  }

  void _take(Map<String, Object?> body) {
    final seconds = (body['expires_in'] as num?)?.toInt() ?? 3600;
    _state = {
      'access': body['access_token'],
      'refresh': body['refresh_token'] ?? _state['refresh'],
      'expires': _now().add(Duration(seconds: seconds)).millisecondsSinceEpoch,
      // what the service says it allowed (not every service says); kept as it was when a renewal does not say
      if ((body['scope'] ?? _state['scope']) is String) 'scope': body['scope'] ?? _state['scope'],
    };
  }

  /// The permissions the service gave at the sign-in (empty when it did not say, or when this device took the sign-in over).
  Set<String> get grantedScopes => {
        for (final s in ('${_state['scope'] ?? ''}').split(RegExp(r'[\s,]+')))
          if (s.isNotEmpty) s.toLowerCase(),
      };

  /// Finishes the sign-in with the address the service returned to. Throws if it is not the answer to the sign-in
  /// that was begun, or the service refused.
  Future<void> finish(Uri redirect) async {
    final pending = _state['pending'];
    if (pending is! Map || pending['state'] != redirect.queryParameters['state']) {
      throw StateError(tr('This sign-in was not started here, or it took too long. Start it again.'));
    }
    final error = redirect.queryParameters['error'];
    if (error != null) {
      _state = {..._state}..remove('pending');
      await _save();
      throw StateError(tr('Signing in failed: {why}', {'why': redirect.queryParameters['error_description'] ?? error}));
    }
    final code = redirect.queryParameters['code'];
    if (code == null) throw StateError(tr('Signing in failed: {why}', {'why': tr('no code came back')}));
    final body = await _token({
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'code_verifier': pending['verifier'] as String,
    });
    _take(body);
    await _save();
  }

  /// A token that is good now, renewed with the refresh token when it has run out.
  Future<String> accessToken() async {
    final access = _state['access'];
    if (access is! String) throw StateError(tr('Not signed in.'));
    final expires = (_state['expires'] as num?)?.toInt() ?? 0;
    if (_now().millisecondsSinceEpoch < expires - 60000) return access;
    final refresh = _state['refresh'];
    if (refresh is! String) throw StateError(tr('The sign-in has run out. Sign in again.'));
    final body = await _token({'grant_type': 'refresh_token', 'refresh_token': refresh, 'client_id': clientId});
    _take(body);
    await _save();
    return _state['access'] as String;
  }

  Future<void> disconnect() async {
    _state = {};
    await _save();
  }
}

/// A [ShareStorage] that needs the person to sign in to the service in the browser.
abstract class OAuthShareStorage extends ShareStorage {
  PkceOAuth get oauth;

  /// Reads the tokens that were kept.
  Future<void> load() async {
    await loadClientId();
    await oauth.load();
    notifyListeners();
  }

  /// The folder [name] in the person's storage, for the sync through a cloud folder.
  CloudFolder folderFor(String name);

  /// The page to open in the browser to sign in.
  Future<Uri> beginSignIn() => oauth.begin();

  /// Where the person's own app registration is kept, if they entered one (the built-in one is [defaultClientId]).
  SettingsRepository? get settings;
  String get settingsKey;

  /// The registration this build comes with; empty if there is none.
  String get defaultClientId;

  /// How to make an app registration, in words for the person; what the field for it is called.
  String get setupHint;
  String get clientIdLabel;

  /// Whether there is an app registration to sign in with.
  bool get configured => oauth.clientId.isNotEmpty;

  /// Whether the registration is one the person entered.
  bool get customClientId => oauth.clientId.isNotEmpty && oauth.clientId != defaultClientId;

  /// Reads the registration the person entered, over the one of the build.
  Future<void> loadClientId() async {
    final own = (await settings?.get(settingsKey))?.trim();
    oauth.clientId = own == null || own.isEmpty ? defaultClientId : own;
  }

  /// Uses [id] as the app registration (empty: back to the one of the build). Signs out, as tokens belong to one.
  Future<void> setClientId(String id) async {
    final next = id.trim().isEmpty ? defaultClientId : id.trim();
    if (next != oauth.clientId) await oauth.disconnect();
    oauth.clientId = next;
    if (id.trim().isEmpty) {
      await settings?.remove(settingsKey);
    } else {
      await settings?.set(settingsKey, id.trim());
    }
    notifyListeners();
  }

  /// The path of the address that returns to the app: `notation://oauth/<this>`.
  String get redirectName;

  @override
  bool get available => configured && oauth.connected;

  @override
  String? get unavailableReason => available ? null : tr('Sign in to {service} in the settings first.', {'service': label});

  /// Last problem of a sign-in, for the settings.
  String? signInProblem;

  @override
  Future<bool> handleRedirect(Uri uri) async {
    if (uri.scheme != 'notation' || uri.host != 'oauth' || uri.path != '/$redirectName') return false;
    try {
      await oauth.finish(uri);
      signInProblem = null;
    } catch (e) {
      signInProblem = '$e'.replaceFirst('Bad state: ', '');
    }
    notifyListeners();
    return true;
  }

  Future<void> signOut() async {
    await oauth.disconnect();
    notifyListeners();
  }
}
