import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../data/settings_repository.dart';
import '../l10n/language.dart';
import '../sync/caldav_service.dart' show SecretStore, KeystoreSecretStore;
import 'oauth.dart';
import '../cloudsync/cloud_folder.dart';
import 'share_storage.dart';
import '../data/app_secure_storage.dart';

/// Shares through the person's Dropbox. The app only sees its own folder (an "app folder" app); the sealed copy
/// is put there, a public link is made, and the link is turned into a direct download (`dl=1`). Dropbox does not
/// let free accounts give links an end date, so the app deletes its copies itself after 30 days.
class DropboxStorage extends OAuthShareStorage {
  static const keepDays = 30;

  @override
  final PkceOAuth oauth;
  @override
  final SettingsRepository? settings;
  @override
  final String defaultClientId;
  @override
  String get settingsKey => 'dropbox_app_key';
  final Dio? _dio;
  final String _api, _content;
  late final UploadLedger _ledger;
  final DateTime Function() _now;

  /// [fullAccess]: the app is registered with the access type "Full Dropbox", which sharing with people needs (see `collab/defaults.dart`).
  /// [apiHost] and [contentHost] are for tests against a local server.
  DropboxStorage({
    String appKey = '',
    bool fullAccess = false,
    this.settings,
    SecretStore? store,
    Dio? dio,
    DateTime Function()? now,
    String authorizeUrl = 'https://www.dropbox.com/oauth2/authorize',
    String apiHost = 'https://api.dropboxapi.com',
    String contentHost = 'https://content.dropboxapi.com',
  })  : defaultClientId = appKey,
        _fullAccess = fullAccess,
        _sharing = fullAccess,
        _dio = dio,
        _api = apiHost,
        _content = contentHost,
        _now = now ?? DateTime.now,
        oauth = PkceOAuth(
          authorizeUrl: authorizeUrl,
          tokenUrl: '$apiHost/oauth2/token',
          clientId: appKey,
          redirectUri: 'notation://oauth/dropbox',
          scopes: const ['files.content.write', 'files.content.read', 'files.metadata.read', 'sharing.write'],
          extraParams: const {'token_access_type': 'offline'},
          store: store ?? const KeystoreSecretStore(appSecureStorage, 'dropbox_tokens'),
          dio: dio,
          now: now,
        ) {
    _ledger = UploadLedger(settings, 'dropbox_uploads', now: _now);
  }

  @override
  String get label => 'Dropbox';

  // ---- sharing with people

  static const _sharingKey = 'dropbox_sharing';
  final bool _fullAccess;
  bool _sharing;

  /// Whether the person allowed sharing with other people. Dropbox lets only an app that has access to the whole Dropbox share its folders
  /// and reach the ones shared with the person (an "app folder" app cannot), so this needs an app registered that way; the key of the
  /// build is such a one when `dropboxFullAccess` says so, and a key the person enters is taken at their word when they turn this on.
  bool get sharingEnabled => _sharing;

  void _applyScopes() => oauth.scopes = [...oauth.scopes.where((s) => s != 'sharing.read'), if (_sharing) 'sharing.read'];

  @override
  Future<void> load() async {
    final saved = await settings?.get(_sharingKey);
    _sharing = saved == null ? _fullAccess : saved == '1';
    _applyScopes();
    await super.load();
  }

  Future<void> setSharing(bool on) async {
    if (on == _sharing) return;
    _sharing = on;
    await settings?.set(_sharingKey, on ? '1' : '0');
    _applyScopes();
    // a sign-in has the permissions it was given: the other ones need a new one
    if (oauth.connected) await oauth.disconnect();
    notifyListeners();
  }

  /// Whether sharing with people can be used now (a service that does not say which permissions were given is taken at its word).
  bool get canShare {
    if (!_sharing || !available) return false;
    final granted = oauth.grantedScopes;
    return granted.isEmpty || granted.contains('sharing.read');
  }

  /// For `DropboxShares`: the hosts, a header that signs a request, the client, and a message for an answer that was no.
  String get apiHost => _api;
  String get contentHost => _content;
  Dio get http => _client;
  Future<Map<String, String>> authHeaders() async => {'Authorization': 'Bearer ${await oauth.accessToken()}'};
  String errorText(Response<dynamic> r) => _error(r);

  /// A folder of the app folder for the sync of the library (see `FolderSync`). Needs the read scopes: sign in again after an update.
  @override
  CloudFolder folderFor(String name) => _DropboxFolder(this, name);

  @override
  String get clientIdLabel => tr('App key');

  @override
  String get setupHint => tr('Dropbox needs an app of your own: create one at dropbox.com/developers/apps ("Scoped access", "App folder"), '
      'allow files.content.write, files.content.read, files.metadata.read and sharing.write, add the redirect URI notation://oauth/dropbox, and enter its app key here.');

  @override
  String get redirectName => 'dropbox';

  @override
  Duration get keeps => const Duration(days: keepDays);

  /// One client for all requests: a new one for each would open a new connection (and TLS handshake) every time, where a sync is hundreds
  /// of small requests that can share a few.
  Dio? _made;
  Dio get _client => _dio ?? (_made ??= Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 2), sendTimeout: const Duration(minutes: 5), validateStatus: (s) => s != null && s < 500)));

  String _error(Response<dynamic> r) {
    final data = r.data;
    final summary = data is Map ? '${data['error_summary'] ?? ''}' : (data is String ? data : '');
    if (r.statusCode == 401) return tr('Dropbox did not accept the sign-in. Sign in again in the settings.');
    if (summary.contains('insufficient_space')) return tr('Your Dropbox is full.');
    return tr('Dropbox answered with an error ({code}).', {'code': r.statusCode});
  }

  @override
  Future<StoredFile> store(Uint8List sealed) async {
    final token = await oauth.accessToken();
    await _ledger.sweep(keeps + const Duration(hours: 1), (path) async {
      final r = await _client.post<dynamic>('$_api/2/files/delete_v2',
          data: jsonEncode({'path': path}), options: Options(headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'}));
      return r.statusCode == 200 || r.statusCode == 409; // 409: not there any more
    });
    final random = Random.secure();
    final path = '/shared/${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}.uninote.enc';
    final put = await _client.post<dynamic>(
      '$_content/2/files/upload',
      data: Stream.fromIterable([sealed]),
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Dropbox-API-Arg': dropboxArg({'path': path, 'mode': 'add', 'autorename': true, 'mute': true}),
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${sealed.length}',
      }),
    );
    if (put.statusCode != 200) throw StateError(_error(put));
    final stored = put.data is Map ? (put.data as Map)['path_display'] as String? ?? path : path;
    await _ledger.add(stored);
    final link = await _client.post<dynamic>(
      '$_api/2/sharing/create_shared_link_with_settings',
      data: jsonEncode({
        'path': stored,
        'settings': {'requested_visibility': 'public', 'audience': 'public', 'access': 'viewer'},
      }),
      options: Options(headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'}),
    );
    final url = link.data is Map ? (link.data as Map)['url'] as String? : null;
    if (link.statusCode != 200 || url == null) throw StateError(_error(link));
    final uri = Uri.parse(url);
    // dl=1 downloads the file itself instead of showing Dropbox's page about it
    return StoredFile(uri.replace(queryParameters: {...uri.queryParameters, 'dl': '1'}), stored);
  }

  @override
  Future<void> replace(String ref, Uint8List sealed) async {
    final token = await oauth.accessToken();
    final put = await _client.post<dynamic>(
      '$_content/2/files/upload',
      data: Stream.fromIterable([sealed]),
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        'Dropbox-API-Arg': dropboxArg({'path': ref, 'mode': 'overwrite', 'mute': true}),
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${sealed.length}',
      }),
    );
    if (put.statusCode != 200) throw StateError(_error(put));
  }
}

/// The folder of the sync through a cloud folder: a directory in the app folder.
/// The JSON of a `Dropbox-API-Arg` header: a header holds ASCII only, so every other character is written as a `\uXXXX` escape (a folder
/// called "Notizen für Uni" would otherwise not be sent).
String dropboxArg(Object json) {
  final text = jsonEncode(json);
  final out = StringBuffer();
  for (final unit in text.codeUnits) {
    if (unit < 0x7f) {
      out.writeCharCode(unit);
    } else {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    }
  }
  return out.toString();
}

class _DropboxFolder implements CloudFolder {
  @override
  Future<Map<String, String>?> stamps(String dir) async => null;
  final DropboxStorage _storage;
  final String _name;

  _DropboxFolder(this._storage, this._name);

  @override
  String get label => 'Dropbox';

  Future<Map<String, String>> _auth() async => {'Authorization': 'Bearer ${await _storage.oauth.accessToken()}'};

  String _path(String path) => '/$_name/$path';

  bool _notFound(Response<dynamic> r) {
    if (r.statusCode != 409) return false;
    final data = r.data;
    final text = data is Map ? '${data['error_summary'] ?? ''}' : (data is List<int> ? utf8.decode(data, allowMalformed: true) : '$data');
    return text.contains('not_found');
  }

  @override
  Future<List<String>> list(String dir) async {
    final auth = await _auth();
    final names = <String>[];
    var r = await _storage._client.post<dynamic>('${_storage._api}/2/files/list_folder',
        data: jsonEncode({'path': _path(dir), 'recursive': false, 'limit': 1000}), options: Options(headers: {...auth, 'Content-Type': 'application/json'}));
    while (true) {
      if (_notFound(r)) return const [];
      final data = r.data;
      if (r.statusCode != 200 || data is! Map) throw CloudFolderException(_storage._error(r), r.statusCode);
      for (final e in (data['entries'] as List? ?? const [])) {
        if (e is Map && e['.tag'] == 'file') names.add(e['name'] as String);
      }
      if (data['has_more'] != true) break;
      r = await _storage._client.post<dynamic>('${_storage._api}/2/files/list_folder/continue',
          data: jsonEncode({'cursor': data['cursor']}), options: Options(headers: {...auth, 'Content-Type': 'application/json'}));
    }
    return names;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final r = await _storage._client.post<List<int>>('${_storage._content}/2/files/download',
        options: Options(headers: {...await _auth(), 'Dropbox-API-Arg': dropboxArg({'path': _path(path)})}, responseType: ResponseType.bytes));
    if (_notFound(r)) return null;
    if (r.statusCode != 200 || r.data == null) throw CloudFolderException(_storage._error(r), r.statusCode);
    return Uint8List.fromList(r.data!);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final r = await _storage._client.post<dynamic>(
      '${_storage._content}/2/files/upload',
      data: Stream.fromIterable([bytes]),
      options: Options(headers: {
        ...await _auth(),
        'Dropbox-API-Arg': dropboxArg({'path': _path(path), 'mode': 'overwrite', 'mute': true}),
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${bytes.length}',
      }),
    );
    if (r.statusCode != 200) throw CloudFolderException(_storage._error(r), r.statusCode);
  }

  @override
  Future<void> delete(String path) async {
    final r = await _storage._client.post<dynamic>('${_storage._api}/2/files/delete_v2',
        data: jsonEncode({'path': _path(path)}), options: Options(headers: {...await _auth(), 'Content-Type': 'application/json'}));
    if (r.statusCode != 200 && !_notFound(r)) throw CloudFolderException(_storage._error(r), r.statusCode);
  }
}
