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

/// Shares through the person's OneDrive (a personal Microsoft account). The sealed copy goes into the app's own
/// folder with an upload session, which takes files of any size, and an anonymous link is made. OneDrive
/// downloads such a link without a sign-in through its "shares" address, so this service fetches its own links.
/// Work and school accounts often forbid anonymous links; the person is told when that is so.
class OneDriveStorage extends OAuthShareStorage {
  static const keepDays = 30;
  static const _chunk = 327680 * 10; // upload parts must be multiples of 320 KiB

  @override
  final PkceOAuth oauth;
  @override
  final SettingsRepository? settings;
  @override
  final String defaultClientId;
  @override
  String get settingsKey => 'onedrive_client_id';
  final Dio? _dio;
  final String _graph, _shares;
  late final UploadLedger _ledger;

  /// [graphHost] and [sharesHost] are for tests against a local server.
  OneDriveStorage({
    String clientId = '',
    this.settings,
    SecretStore? store,
    Dio? dio,
    DateTime Function()? now,
    String authorizeUrl = 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
    String tokenUrl = 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    String graphHost = 'https://graph.microsoft.com',
    String sharesHost = 'https://api.onedrive.com',
  })  : defaultClientId = clientId,
        _dio = dio,
        _graph = graphHost,
        _shares = sharesHost,
        oauth = PkceOAuth(
          authorizeUrl: authorizeUrl,
          tokenUrl: tokenUrl,
          clientId: clientId,
          redirectUri: 'notation://oauth/onedrive',
          scopes: const ['Files.ReadWrite.AppFolder', 'offline_access'],
          store: store ?? const KeystoreSecretStore(appSecureStorage, 'onedrive_tokens'),
          dio: dio,
          now: now,
        ) {
    _ledger = UploadLedger(settings, 'onedrive_uploads', now: now);
  }

  @override
  String get label => 'OneDrive';

  // ---- sharing with people

  static const _sharingKey = 'onedrive_sharing';
  bool _sharing = false;

  /// Whether the person allowed sharing with other people. It needs the permission to see all the files on the OneDrive (what other
  /// people share cannot be reached with the permission for the app's folder alone), so it is a choice, and signing in is again needed
  /// when it is changed.
  bool get sharingEnabled => _sharing;

  void _applyScopes() => oauth.scopes = [_sharing ? 'Files.ReadWrite.All' : 'Files.ReadWrite.AppFolder', 'offline_access'];

  @override
  Future<void> load() async {
    _sharing = (await settings?.get(_sharingKey)) == '1';
    _applyScopes();
    await super.load();
  }

  Future<void> setSharing(bool on) async {
    if (on == _sharing) return;
    _sharing = on;
    if (on) {
      await settings?.set(_sharingKey, '1');
    } else {
      await settings?.remove(_sharingKey);
    }
    _applyScopes();
    // a sign-in has the permissions it was given: the other ones need a new one
    if (oauth.connected) await oauth.disconnect();
    notifyListeners();
  }

  /// Whether sharing with people can be used now: it is on, signed in, and the permission was given (a service that does not say which
  /// were given is taken at its word).
  bool get canShare {
    if (!_sharing || !available) return false;
    final granted = oauth.grantedScopes;
    return granted.isEmpty || granted.contains('files.readwrite.all');
  }

  /// For `OneDriveShares`: where the API is, a header that signs a request, the client, and a message for an answer that was no.
  String get graphHost => _graph;
  Dio get http => _client;
  Future<Map<String, String>> authHeaders() async => {'Authorization': 'Bearer ${await oauth.accessToken()}'};
  String errorText(Response<dynamic> r) => _error(r);

  /// A folder of the app folder for the sync of the library (see `FolderSync`).
  @override
  CloudFolder folderFor(String name) => _OneDriveFolder(this, name);

  @override
  String get clientIdLabel => tr('Application (client) ID');

  @override
  String get setupHint => tr('OneDrive needs an app of your own: register one in the Azure portal (App registrations, accounts of any kind), '
      'add the redirect URI notation://oauth/onedrive for "Mobile and desktop", allow Files.ReadWrite.AppFolder and offline_access, '
      'and enter its application ID here.');

  @override
  String get redirectName => 'onedrive';

  @override
  Duration get keeps => const Duration(days: keepDays);

  /// One client for all requests: a new one for each would open a new connection (and TLS handshake) every time, where a sync is hundreds
  /// of small requests that can share a few.
  Dio? _made;
  Dio get _client => _dio ?? (_made ??= Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 2), sendTimeout: const Duration(minutes: 5), validateStatus: (s) => s != null && s < 500)));

  String _error(Response<dynamic> r) {
    final data = r.data;
    final code = data is Map ? (data['error'] is Map ? (data['error'] as Map)['code'] : null) : null;
    if (r.statusCode == 401) return tr('OneDrive did not accept the sign-in. Sign in again in the settings.');
    if (code == 'accessDenied' || r.statusCode == 403) return tr('OneDrive does not allow links for anyone here (work and school accounts often forbid them).');
    if (code == 'quotaLimitReached' || r.statusCode == 507) return tr('Your OneDrive is full.');
    return tr('OneDrive answered with an error ({code}).', {'code': r.statusCode});
  }

  @override
  Future<StoredFile> store(Uint8List sealed) async {
    final token = await oauth.accessToken();
    final auth = {'Authorization': 'Bearer $token'};
    final dio = _client;
    await _ledger.sweep(keeps + const Duration(hours: 1), (id) async {
      final r = await dio.delete<dynamic>('$_graph/v1.0/me/drive/items/$id', options: Options(headers: auth));
      return r.statusCode == 204 || r.statusCode == 404;
    });

    final random = Random.secure();
    final name = '${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}.uninote.enc';
    final itemId = await _putFile(dio, auth, name, sealed, 'rename');
    await _ledger.add(itemId);

    final link = await dio.post<dynamic>(
      '$_graph/v1.0/me/drive/items/$itemId/createLink',
      data: jsonEncode({'type': 'view', 'scope': 'anonymous'}),
      options: Options(headers: {...auth, 'Content-Type': 'application/json'}),
    );
    final linkData = link.data is Map ? (link.data as Map)['link'] : null;
    final web = linkData is Map ? linkData['webUrl'] as String? : null;
    if ((link.statusCode != 200 && link.statusCode != 201) || web == null) throw StateError(_error(link));
    return StoredFile(Uri.parse(web), name);
  }

  @override
  Future<void> replace(String ref, Uint8List sealed) async {
    final token = await oauth.accessToken();
    await _putFile(_client, {'Authorization': 'Bearer $token'}, ref, sealed, 'replace');
  }

  /// Uploads [sealed] as the file [name] of the app's folder, in parts; returns the id of the item.
  Future<String> _putFile(Dio dio, Map<String, String> auth, String name, Uint8List sealed, String conflict, {String folder = 'shared'}) =>
      putAt(dio, auth, '$_graph/v1.0/me/drive/special/approot:/$folder/$name', sealed, conflict);

  /// Uploads [sealed] to the item address [itemUrl] (`.../items/<id>:/<path>` or `.../approot:/<path>`, no colon at the end), in parts;
  /// returns the id of the item. Folders on the way are made.
  Future<String> putAt(Dio dio, Map<String, String> auth, String itemUrl, Uint8List sealed, String conflict) async {
    final session = await dio.post<dynamic>(
      '$itemUrl:/createUploadSession',
      data: jsonEncode({'item': {'@microsoft.graph.conflictBehavior': conflict}}),
      options: Options(headers: {...auth, 'Content-Type': 'application/json'}),
    );
    final uploadUrl = session.data is Map ? (session.data as Map)['uploadUrl'] as String? : null;
    if (session.statusCode != 200 || uploadUrl == null) throw StateError(_error(session));

    String? itemId;
    for (var at = 0; at < sealed.length; at += _chunk) {
      final end = at + _chunk < sealed.length ? at + _chunk : sealed.length;
      final part = await dio.put<dynamic>(
        uploadUrl,
        data: Stream.fromIterable([Uint8List.sublistView(sealed, at, end)]),
        options: Options(headers: {'Content-Length': '${end - at}', 'Content-Range': 'bytes $at-${end - 1}/${sealed.length}'}),
      );
      if (part.statusCode != 200 && part.statusCode != 201 && part.statusCode != 202) throw StateError(_error(part));
      if (part.data is Map && (part.data as Map)['id'] is String) itemId = (part.data as Map)['id'] as String;
    }
    if (itemId == null) throw StateError(tr('OneDrive answered with an error ({code}).', {'code': 0}));
    return itemId;
  }

  @override
  bool handles(Uri url) => url.host == '1drv.ms' || url.host.endsWith('.1drv.ms') || url.host == 'onedrive.live.com';

  /// The address that downloads what a sharing link points at, without a sign-in.
  Uri downloadAddress(Uri url) {
    final encoded = 'u!${base64Url.encode(utf8.encode(url.toString())).replaceAll('=', '')}';
    return Uri.parse('$_shares/v1.0/shares/$encoded/root/content');
  }

  @override
  Future<Uint8List> fetch(Uri url) => downloadShared(downloadAddress(url), dio: _dio, allowInsecure: _shares.startsWith('http://'));
}

/// The folder of the sync through a cloud folder: a directory in the app folder.
class _OneDriveFolder implements CloudFolder {
  @override
  Future<Map<String, String>?> stamps(String dir) async => null;
  /// Files up to this size go up in a single request (the service allows 4 MB that way).
  static const simpleUploadMax = 3 * 1024 * 1024;

  final OneDriveStorage _storage;
  final String _name;

  _OneDriveFolder(this._storage, this._name);

  @override
  String get label => 'OneDrive';

  Future<Map<String, String>> _auth() async => {'Authorization': 'Bearer ${await _storage.oauth.accessToken()}'};

  static String _enc(String path) => path.split('/').map(Uri.encodeComponent).join('/');

  String _item(String path) => '${_storage._graph}/v1.0/me/drive/special/approot:/${_enc('$_name/$path')}';

  @override
  Future<List<String>> list(String dir) async {
    final auth = await _auth();
    final names = <String>[];
    String? url = '${_item(dir)}:/children?\$select=name,file&\$top=200';
    while (url != null) {
      final r = await _storage._client.get<dynamic>(url, options: Options(headers: auth));
      if (r.statusCode == 404) return const [];
      final data = r.data;
      if (r.statusCode != 200 || data is! Map) throw CloudFolderException(_storage._error(r), r.statusCode);
      for (final e in (data['value'] as List? ?? const [])) {
        if (e is Map && e['file'] != null) names.add(e['name'] as String);
      }
      url = data['@odata.nextLink'] as String?;
    }
    return names;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final auth = await _auth();
    // the content address answers with a redirect to the file; the sign-in is for Microsoft, not for where it leads
    final r = await _storage._client.get<List<int>>(
      '${_item(path)}:/content',
      options: Options(headers: auth, followRedirects: false, responseType: ResponseType.bytes, validateStatus: (s) => s != null && s < 500),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode == 302 || r.statusCode == 301 || r.statusCode == 307) {
      final to = r.headers.value('location');
      if (to == null) throw CloudFolderException(_storage._error(r), r.statusCode);
      final file = await _storage._client.get<List<int>>(to, options: Options(responseType: ResponseType.bytes));
      if (file.statusCode != 200 || file.data == null) throw CloudFolderException(_storage._error(file), file.statusCode);
      return Uint8List.fromList(file.data!);
    }
    if (r.statusCode != 200 || r.data == null) throw CloudFolderException(_storage._error(r), r.statusCode);
    return Uint8List.fromList(r.data!);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    if (bytes.length <= simpleUploadMax) {
      // one request instead of the two (a session, then the part) that a big file needs; the folders on the way are made
      final r = await _storage._client.put<dynamic>(
        '${_item(path)}:/content?@microsoft.graph.conflictBehavior=replace',
        data: Stream.fromIterable([bytes]),
        options: Options(headers: {...await _auth(), 'Content-Type': 'application/octet-stream', 'Content-Length': '${bytes.length}'}),
      );
      if (r.statusCode != 200 && r.statusCode != 201) throw CloudFolderException(_storage._error(r), r.statusCode);
      return;
    }
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? _name : '$_name/${path.substring(0, slash)}';
    final name = slash < 0 ? path : path.substring(slash + 1);
    await _storage._putFile(_storage._client, await _auth(), Uri.encodeComponent(name), bytes, 'replace', folder: _enc(dir));
  }

  @override
  Future<void> delete(String path) async {
    final r = await _storage._client.delete<dynamic>(_item(path), options: Options(headers: await _auth()));
    if (r.statusCode != 204 && r.statusCode != 200 && r.statusCode != 404) throw CloudFolderException(_storage._error(r), r.statusCode);
  }
}
