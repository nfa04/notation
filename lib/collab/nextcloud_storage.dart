import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../data/settings_repository.dart';
import '../l10n/language.dart';
import '../sync/caldav_service.dart';
import '../cloudsync/cloud_folder.dart';
import 'share_storage.dart';
import '../util/user_agent.dart';

/// Shares through the Nextcloud (or ownCloud) of the calendar connection: the sealed file is put in a folder
/// by WebDAV and a public link is made with the sharing API. The server stores a file it cannot read.
class NextcloudStorage extends ShareStorage {
  final CalDavService _caldav;
  final Dio? _dio;

  /// The folder on the Nextcloud that shared files are put in.
  static const folder = 'Notation shared';

  /// How many days a shared copy stays; after that the server takes the link away.
  static const keepDays = 30;

  late final UploadLedger _ledger;

  /// [settings] keeps the list of what was put there, so that it can be removed again when its time is up.
  NextcloudStorage(this._caldav, {Dio? dio, SettingsRepository? settings, DateTime Function()? now}) : _dio = dio {
    _ledger = UploadLedger(settings, 'nextcloud_uploads', now: now);
    _caldav.addListener(notifyListeners);
  }

  /// The account behind it: the same login serves the calendar, shared copies and the sync of folders.
  CalDavService get caldav => _caldav;

  @override
  void dispose() {
    _caldav.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  String get label => 'Nextcloud';

  /// A folder of the Nextcloud for the sync of the library (see `FolderSync`).
  CloudFolder folderFor(String name) => _NextcloudFolder(this, name);

  @override
  Duration get keeps => const Duration(days: keepDays);

  /// The site address inside a CalDAV address of a Nextcloud (`https://host/remote.php/dav/...`); null if
  /// [serverUrl] is not one.
  static String? rootOf(String serverUrl) {
    final i = serverUrl.indexOf('/remote.php/');
    return i < 0 ? null : serverUrl.substring(0, i);
  }

  /// Removes the Nextcloud account (the one of the calendar connection too: it is the same). Local tasks stay.
  Future<void> disconnect() => _caldav.disconnect();

  @override
  bool get available => _caldav.isConnected && rootOf(_caldav.config!.serverUrl) != null;

  @override
  String? get unavailableReason => available ? null : tr('Connect a Nextcloud in the settings under Sharing and files first.');

  /// One client for all requests: a new one for each would open a new connection (and TLS handshake) every time, where a sync is hundreds
  /// of small requests that can share a few.
  Dio? _made;
  Dio get _client =>
      _dio ??
      (_made ??= Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 2),
        sendTimeout: const Duration(minutes: 5),
        validateStatus: (s) => s != null && s < 500,
      )));

  @override
  Future<StoredFile> store(Uint8List sealed) async {
    final login = await _caldav.login();
    final root = login == null ? null : rootOf(login.serverUrl);
    if (login == null || root == null) throw StateError(tr('Sharing a copy needs a Nextcloud account (connect one in the settings under Sharing and files).'));
    final auth = {'Authorization': 'Basic ${base64Encode(utf8.encode('${login.username}:${login.password}'))}',
      ...userAgentHeader,};
    final files = '$root/remote.php/dav/files/${Uri.encodeComponent(login.username)}';
    final dio = _client;

    await _ledger.sweep(keeps + const Duration(hours: 1), (path) async {
      final gone = await dio.delete<void>('$files/${path.split('/').map(Uri.encodeComponent).join('/')}', options: Options(headers: auth));
      return gone.statusCode == 204 || gone.statusCode == 200 || gone.statusCode == 404;
    });

    final r = Random.secure();
    final name = '${List.generate(12, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}.uninote.enc';
    final mkcol = await dio.request<void>('$files/${Uri.encodeComponent(folder)}', options: Options(method: 'MKCOL', headers: auth));
    _check(mkcol, okIn: const [201, 405], step: 'MKCOL'); // 405: the folder is there already
    final put = await dio.put<void>(
      '$files/${Uri.encodeComponent(folder)}/$name',
      data: Stream.fromIterable([sealed]),
      options: Options(headers: {...auth, 'Content-Type': 'application/octet-stream', 'Content-Length': '${sealed.length}'}),
    );
    _check(put, okIn: const [201, 204], step: 'PUT');

    final expires = DateTime.now().add(keeps);
    String two(int n) => n.toString().padLeft(2, '0');
    final share = await dio.post<dynamic>(
      '$root/ocs/v2.php/apps/files_sharing/api/v1/shares',
      data: {'path': '/$folder/$name', 'shareType': 3, 'permissions': 1, 'expireDate': '${expires.year}-${two(expires.month)}-${two(expires.day)}'},
      options: Options(contentType: Headers.formUrlEncodedContentType, headers: {...auth, 'OCS-APIRequest': 'true', 'Accept': 'application/json'}),
    );
    if (share.statusCode == 401) throw StateError(tr('The Nextcloud did not accept the login. Connect again in the settings under Sharing and files.'));
    if (share.statusCode == 405) throw StateError(tr('The Nextcloud answered with an error ({code}).', {'code': '405 (link, ${share.realUri})'}));
    final body = share.data is Map ? share.data as Map : null;
    final data = (body?['ocs'] as Map?)?['data'];
    final token = data is Map ? data['token'] : null;
    if (token is! String || token.isEmpty) {
      throw StateError(tr('The Nextcloud did not make a public link. Is link sharing turned on for it?'));
    }
    await _ledger.add('$folder/$name');
    return StoredFile(Uri.parse('$root/s/$token/download'), '$folder/$name');
  }

  @override
  Future<void> replace(String ref, Uint8List sealed) async {
    final login = await _caldav.login();
    final root = login == null ? null : rootOf(login.serverUrl);
    if (login == null || root == null) throw StateError(tr('Sharing a copy needs a Nextcloud account (connect one in the settings under Sharing and files).'));
    final auth = {'Authorization': 'Basic ${base64Encode(utf8.encode('${login.username}:${login.password}'))}',
      ...userAgentHeader,};
    final path = ref.split('/').map(Uri.encodeComponent).join('/');
    final put = await _client.put<void>(
      '$root/remote.php/dav/files/${Uri.encodeComponent(login.username)}/$path',
      data: Stream.fromIterable([sealed]),
      options: Options(headers: {...auth, 'Content-Type': 'application/octet-stream', 'Content-Length': '${sealed.length}'}),
    );
    _check(put, okIn: const [201, 204], step: 'PUT');
  }

  // ---- inbox: a folder that is shared as a "file drop" (people with the link can put files in, nothing else)

  @override
  bool get hasInbox => true;

  @override
  Future<InboxInfo> createInbox() async {
    final login = await _caldav.login();
    final root = login == null ? null : rootOf(login.serverUrl);
    if (login == null || root == null) throw StateError(tr('Sharing a copy needs a Nextcloud account (connect one in the settings under Sharing and files).'));
    final auth = {'Authorization': 'Basic ${base64Encode(utf8.encode('${login.username}:${login.password}'))}',
      ...userAgentHeader,};
    final files = '$root/remote.php/dav/files/${Uri.encodeComponent(login.username)}';
    final dio = _client;
    final r = Random.secure();
    final name = 'inbox-${List.generate(10, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _check(await dio.request<void>('$files/${Uri.encodeComponent(folder)}', options: Options(method: 'MKCOL', headers: auth)), okIn: const [201, 405]);
    _check(await dio.request<void>('$files/${Uri.encodeComponent(folder)}/$name', options: Options(method: 'MKCOL', headers: auth)), okIn: const [201]);
    final expires = DateTime.now().add(keeps);
    String two(int n) => n.toString().padLeft(2, '0');
    final share = await dio.post<dynamic>(
      '$root/ocs/v2.php/apps/files_sharing/api/v1/shares',
      // 4: create only (a "file drop")
      data: {'path': '/$folder/$name', 'shareType': 3, 'permissions': 4, 'expireDate': '${expires.year}-${two(expires.month)}-${two(expires.day)}'},
      options: Options(contentType: Headers.formUrlEncodedContentType, headers: {...auth, 'OCS-APIRequest': 'true', 'Accept': 'application/json'}),
    );
    final ocs = share.data is Map ? (share.data as Map)['ocs'] : null;
    final data = ocs is Map ? ocs['data'] : null;
    final token = data is Map ? data['token'] : null;
    if (token is! String || token.isEmpty) throw StateError(tr('The Nextcloud did not make a public link. Is link sharing turned on for it?'));
    await _ledger.add('$folder/$name');
    return InboxInfo(Uri.parse('$root/s/$token?drop=1'), '$folder/$name');
  }

  static final _dropPath = RegExp(r'^(.*)/s/([A-Za-z0-9]+)$');

  @override
  bool handlesDrop(Uri dropUrl) => dropUrl.queryParameters['drop'] == '1' && _dropPath.hasMatch(dropUrl.path);

  @override
  Future<void> drop(Uri dropUrl, String name, Uint8List sealed) async {
    final m = _dropPath.firstMatch(dropUrl.path);
    if (m == null) throw StateError(tr('This link does not use a secure address.'));
    final root = '${dropUrl.scheme}://${dropUrl.authority}${m.group(1)}';
    final token = m.group(2)!;
    final put = await _client.put<void>(
      '$root/public.php/webdav/${Uri.encodeComponent(name)}',
      data: Stream.fromIterable([sealed]),
      options: Options(headers: {
        'Authorization': 'Basic ${base64Encode(utf8.encode('$token:'))}',
        'X-Requested-With': 'XMLHttpRequest',
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${sealed.length}',
          ...userAgentHeader,
      }),
    );
    final code = put.statusCode ?? 0;
    if (code == 404 || code == 401 || code == 403) throw StateError(tr('This shared copy is gone: it expired or was taken down.'));
    if (code != 201 && code != 204) throw StateError(tr('The Nextcloud answered with an error ({code}).', {'code': code}));
  }

  /// The signed-in account, for the sharing with people (`NextcloudShares`): the site address, the user, and the headers that sign a request.
  Future<({String root, String user, Map<String, String> auth})> account() async {
    final login = await _caldav.login();
    final root = login == null ? null : rootOf(login.serverUrl);
    if (login == null || root == null) throw StateError(tr('Connect a Nextcloud in the settings under Sharing and files first.'));
    return (
      root: root,
      user: login.username,
      auth: {'Authorization': 'Basic ${base64Encode(utf8.encode('${login.username}:${login.password}'))}',
        ...userAgentHeader,},
    );
  }

  /// The client requests go through (a test can give it another).
  Dio get http => _client;

  Future<({String root, String files, Map<String, String> auth})> _owner() async {
    final login = await _caldav.login();
    final root = login == null ? null : rootOf(login.serverUrl);
    if (login == null || root == null) throw StateError(tr('Sharing a copy needs a Nextcloud account (connect one in the settings under Sharing and files).'));
    return (
      root: root,
      files: '$root/remote.php/dav/files/${Uri.encodeComponent(login.username)}',
      auth: {'Authorization': 'Basic ${base64Encode(utf8.encode('${login.username}:${login.password}'))}',
        ...userAgentHeader,},
    );
  }

  String _encodedPath(String ref) => ref.split('/').map(Uri.encodeComponent).join('/');

  @override
  Future<List<InboxFile>> readInbox(String ref) async {
    final o = await _owner();
    final r = await _client.request<String>('${o.files}/${_encodedPath(ref)}',
        options: Options(method: 'PROPFIND', headers: {...o.auth, 'Depth': '1', 'Content-Type': 'application/xml'}, responseType: ResponseType.plain));
    if (r.statusCode == 404) return const [];
    if (r.statusCode != 207) throw StateError(tr('The Nextcloud answered with an error ({code}).', {'code': r.statusCode}));
    final names = <InboxFile>[];
    for (final m in RegExp(r'<[^>]*?href[^>]*>([^<]+)</[^>]*?href>', caseSensitive: false).allMatches(r.data ?? '')) {
      final href = Uri.decodeFull(m.group(1)!.trim());
      if (href.endsWith('/')) continue; // the folder itself
      names.add(InboxFile(href.substring(href.lastIndexOf('/') + 1)));
    }
    return names;
  }

  @override
  Future<Uint8List> readInboxFile(String ref, String name) async {
    final o = await _owner();
    final r = await _client.get<List<int>>('${o.files}/${_encodedPath(ref)}/${Uri.encodeComponent(name)}', options: Options(headers: o.auth, responseType: ResponseType.bytes));
    if (r.statusCode != 200 || r.data == null) throw StateError(tr('The Nextcloud answered with an error ({code}).', {'code': r.statusCode}));
    return Uint8List.fromList(r.data!);
  }

  @override
  Future<void> removeInboxFile(String ref, String name) async {
    final o = await _owner();
    await _client.delete<void>('${o.files}/${_encodedPath(ref)}/${Uri.encodeComponent(name)}', options: Options(headers: o.auth));
  }

  void _check(Response<void> r, {required List<int> okIn, String? step}) {
    final code = r.statusCode ?? 0;
    if (code == 401) throw StateError(tr('The Nextcloud did not accept the login. Connect again in the settings under Sharing and files.'));
    if (!okIn.contains(code)) throw StateError(tr('The Nextcloud answered with an error ({code}).', {'code': step == null ? code : '$code, $step ${r.realUri}'}));
  }
}

/// The folder of the sync through a cloud folder, by WebDAV.
class _NextcloudFolder implements CloudFolder {
  final NextcloudStorage _storage;
  final String _name;
  final Map<String, Future<void>> _made = {};

  _NextcloudFolder(this._storage, this._name);

  @override
  String get label => 'Nextcloud';

  /// The address and the sign-in, read once for as long as this folder object lives (one run of the sync): reading the password from
  /// the keystore costs a moment on a phone, and a sync asks for it in front of every single request.
  Future<({String base, Map<String, String> auth})>? _loginCache;

  Future<({String base, Map<String, String> auth})> _login() {
    final cached = _loginCache;
    if (cached != null) return cached;
    final fresh = _readLogin();
    _loginCache = fresh;
    fresh.then((_) {}, onError: (Object _) {
      if (identical(_loginCache, fresh)) _loginCache = null; // (not kept: a login that was not there may be there next time)
    });
    return fresh;
  }

  Future<({String base, Map<String, String> auth})> _readLogin() async {
    final login = await _storage._caldav.login();
    final root = login == null ? null : NextcloudStorage.rootOf(login.serverUrl);
    if (login == null || root == null) {
      // (an address and a user are saved but no password can be read: the keystore lost it, or the settings came here without it)
 throw CloudAccountMissing(
        _storage._caldav.isConnected
            ? tr(
                'The password of the Nextcloud account is not in the keystore of this device. Log in again in the settings under Sharing and files.',
              )
            :tr('Connect a Nextcloud in the settings under Sharing and files first.'));
    }
    return (
      base: '$root/remote.php/dav/files/${Uri.encodeComponent(login.username)}',
      auth: {'Authorization': 'Basic ${base64Encode(utf8.encode('${login.username}:${login.password}'))}',
        ...userAgentHeader,},
    );
  }

  static String _enc(String path) => path.split('/').map(Uri.encodeComponent).join('/');

  CloudFolderException _fail(Response<dynamic> r) {
    if (r.statusCode == 401) return CloudFolderException(tr('The Nextcloud did not accept the login. Connect again in the settings under Sharing and files.'), 401);
    if (r.statusCode == 507) return CloudFolderException(tr('Your Nextcloud is full.'), 507);
    return CloudFolderException(tr('The Nextcloud answered with an error ({code}).', {'code': r.statusCode}), r.statusCode);
  }

  /// Directories that were made, or are being made: several files written at once wait for the same MKCOL instead of racing it
  /// (a PUT into a directory that is not there yet is refused).
  Future<void> _ensure(String base, Map<String, String> auth, String dir) async {
    final parts = [..._name.split('/').where((p) => p.isNotEmpty), ...dir.split('/').where((p) => p.isNotEmpty)];
    for (var i = 0; i < parts.length; i++) {
      final path = parts.sublist(0, i + 1).join('/');
      final making = _made[path] ??= _mkcol(base, auth, path);
      try {
        await making;
      } catch (_) {
        if (identical(_made[path], making)) _made.remove(path);
        rethrow;
      }
    }
  }

  Future<void> _mkcol(String base, Map<String, String> auth, String path) async {
    final r = await _storage._client.request<void>('$base/${_enc(path)}', options: Options(method: 'MKCOL', headers: auth));
    if (r.statusCode != 201 && r.statusCode != 405) throw _fail(r);
  }

  @override
  Future<List<String>> list(String dir) async {
    final l = await _login();
    final r = await _storage._client.request<String>(
      '${l.base}/${_enc('$_name/$dir')}',
      options: Options(method: 'PROPFIND', headers: {...l.auth, 'Depth': '1', 'Content-Type': 'application/xml'}, responseType: ResponseType.plain),
      data: '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
    );
    if (r.statusCode == 404) return const [];
    if (r.statusCode != 207 && r.statusCode != 200) throw _fail(r);
    final names = <String>[];
    for (final m in RegExp(r'<(?:\w+:)?href>([^<]*)</(?:\w+:)?href>', caseSensitive: false).allMatches(r.data ?? '')) {
      final href = Uri.decodeFull(m.group(1)!);
      if (href.endsWith('/')) continue; // the directory itself, or a sub directory
      names.add(href.split('/').last);
    }
    return names;
  }

  /// The ETags of [dir] and of what is directly in it, in one request (the ETag of a directory changes when anything below it does).
  @override
  Future<Map<String, String>?> stamps(String dir) async {
    final l = await _login();
    final r = await _storage._client.request<String>(
      '${l.base}/${_enc('$_name/$dir')}',
      options: Options(
        method: 'PROPFIND',
        headers: {...l.auth, 'Depth': '1', 'Content-Type': 'application/xml'},
        responseType: ResponseType.plain,
      ),
      data:
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>',
    );
    if (r.statusCode == 404) return const {};
    if (r.statusCode != 207 && r.statusCode != 200) throw _fail(r);
    final self = [
      ..._name.split('/'),
      ...dir.split('/'),
    ].where((p) => p.isNotEmpty).toList();
    final out = <String, String>{};
    for (final m in RegExp(
      r'<(?:\w+:)?response>(.*?)</(?:\w+:)?response>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(r.data ?? '')) {
      final block = m.group(1)!;
      final href = RegExp(
        r'<(?:\w+:)?href>([^<]*)</(?:\w+:)?href>',
        caseSensitive: false,
      ).firstMatch(block)?.group(1);
      final etag = RegExp(
        r'<(?:\w+:)?getetag>([^<]*)</(?:\w+:)?getetag>',
        caseSensitive: false,
      ).firstMatch(block)?.group(1);
      if (href == null || etag == null || etag.isEmpty) continue;
      final parts = Uri.decodeFull(
        href,
      ).split('/').where((p) => p.isNotEmpty).toList();
      // (the response for the directory itself ends with the parts of its path; an entry is one part further)
      final isSelf =
          parts.length >= self.length &&
          [
                for (var i = 0; i < self.length; i++)
                  parts[parts.length - self.length + i],
              ].join('/') ==
              self.join('/');
      out[isSelf ? '' : parts.last] = etag;
    }
    return out;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final l = await _login();
    final r = await _storage._client.get<List<int>>('${l.base}/${_enc('$_name/$path')}', options: Options(headers: l.auth, responseType: ResponseType.bytes));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200 || r.data == null) throw _fail(r);
    return Uint8List.fromList(r.data!);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final l = await _login();
    final slash = path.lastIndexOf('/');
    await _ensure(l.base, l.auth, slash < 0 ? '' : path.substring(0, slash));
    final r = await _storage._client.put<void>(
      '${l.base}/${_enc('$_name/$path')}',
      data: Stream.fromIterable([bytes]),
      options: Options(headers: {...l.auth, 'Content-Type': 'application/octet-stream', 'Content-Length': '${bytes.length}'}),
    );
    if (r.statusCode != 201 && r.statusCode != 204 && r.statusCode != 200) throw _fail(r);
  }

  @override
  Future<void> delete(String path) async {
    final l = await _login();
    final r = await _storage._client.delete<void>('${l.base}/${_enc('$_name/$path')}', options: Options(headers: l.auth));
    if (r.statusCode != 204 && r.statusCode != 200 && r.statusCode != 404) throw _fail(r);
  }
}
