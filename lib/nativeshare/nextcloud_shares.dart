import 'package:dio/dio.dart';

import '../cloudsync/cloud_folder.dart';
import '../collab/nextcloud_storage.dart';
import '../l10n/language.dart';
import 'native_share_provider.dart';

/// Sharing a folder with the other users of the same Nextcloud (or ownCloud), by its sharing API (OCS). The account is the one that is
/// connected for the calendar; the files of a share are read and written by WebDAV, as the sync through a cloud folder does.
class NextcloudShares extends NativeShareProvider {
  final NextcloudStorage _storage;

  NextcloudShares(this._storage);

  @override
  String get id => 'nextcloud';

  @override
  String get label => 'Nextcloud';

  @override
  bool get available => _storage.available;

  /// `permissions` of the Share API: 1 read, 2 update, 4 create, 8 delete.
  static const _viewer = 1, _editor = 1 | 2 | 4 | 8;

  static int rights(ShareRole r) => r == ShareRole.editor ? _editor : _viewer;

  static ShareRole roleOf(Object? permissions) => permissions is num && (permissions.toInt() & (2 | 4)) != 0 ? ShareRole.editor : ShareRole.viewer;

  static const _api = '/ocs/v2.php/apps/files_sharing/api/v1';

  /// The ways to ask, in the order they are tried when a server answers 405 (some hosts refuse a way that others accept): the OCS v2 address
  /// with the form in the body, the v1 address, and the form as query.
  Future<Response<dynamic>> _call(String method, String path, {Map<String, Object?>? query, Map<String, Object?>? form}) async {
    final a = await _storage.account();
    Response<dynamic>? last;
    String? lastUrl;
    for (final (api, inQuery) in [(_api, false), (_apiV1, false), (_api, true)]) {
      if (inQuery && form == null) continue;
      final r = await _send(a, method, '${a.root}$api$path', query: {if (inQuery) ...?form, ...?query}, form: inQuery ? null : form);
      if (r.statusCode != 405) return r;
      last = r;
      lastUrl = '${a.root}$api$path';
    }
    final body = last!.data;
    final meta = body is Map && body['ocs'] is Map ? (body['ocs'] as Map)['meta'] : null;
    final said = meta is Map ? meta['message'] : null;
    if (said is String && said.trim().isNotEmpty) throw NativeShareException(said.trim());
    final allow = last.headers.value('allow');
    throw NativeShareException(tr('The Nextcloud refused {method} at {url} (405). Check that the address of the Nextcloud in the settings under Sharing and files is the one you open in the browser.', {'method': method, 'url': lastUrl}) +
        (allow == null ? '' : ' (Allow: $allow)'));
  }

  static const _apiV1 = '/ocs/v1.php/apps/files_sharing/api/v1';

  /// One request, its redirects followed here with the same method and data: the HTTP client would turn a POST into a GET.
  Future<Response<dynamic>> _send(({String root, String user, Map<String, String> auth}) a, String method, String address,
      {Map<String, Object?>? query, Map<String, Object?>? form}) async {
    var url = address;
    for (var hops = 0;; hops++) {
      final r = await _storage.http.request<dynamic>(
        url,
        queryParameters: hops == 0 ? {'format': 'json', ...?query} : null,
        data: form,
        options: Options(
          method: method,
          contentType: form == null ? null : Headers.formUrlEncodedContentType,
          headers: {...a.auth, 'OCS-APIRequest': 'true', 'Accept': 'application/json'},
          followRedirects: false,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final to = r.headers.value('location');
      if (const [301, 302, 303, 307, 308].contains(r.statusCode) && to != null && hops < 5) {
        url = Uri.parse(url).resolve(to).toString();
        continue;
      }
      return r;
    }
  }

  /// The answer of the Share API: its `data`, or the reason it said no.
  Object? _data(Response<dynamic> r) {
    final code = r.statusCode ?? 0;
    final body = r.data is Map ? r.data as Map : null;
    final meta = (body?['ocs'] as Map?)?['meta'] as Map?;
    if (code == 401) throw NativeShareException(tr('The Nextcloud did not accept the login. Connect again in the settings under Sharing and files.'));
    if (code == 429) throw NativeShareException(tr('The Nextcloud allows only a few new shares in a short time. Try again in a few minutes.'));
    if (code == 404 && body == null) throw NativeShareException(tr('This Nextcloud does not offer sharing with people.'));
    final status = (meta?['statuscode'] as num?)?.toInt() ?? code;
    if (code >= 400 || (status >= 300 && status != 100)) {
      final message = meta?['message'];
      throw NativeShareException(message is String && message.isNotEmpty ? message : tr('The Nextcloud answered with an error ({code}).', {'code': code}));
    }
    return (body?['ocs'] as Map?)?['data'];
  }

  static String _absolute(String place) => place.startsWith('/') ? place : '/$place';

  ProviderShare? _share(Object? j) {
    if (j is! Map || j['share_type'] != 0) return null; // (people only: not links, groups or others)
    final with_ = j['share_with'];
    if (with_ is! String) return null;
    return ProviderShare('${j['id']}', SharePerson(with_, (j['share_with_displayname'] as String?) ?? with_), roleOf(j['permissions']));
  }

  @override
  Future<List<SharePerson>> searchPeople(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final data = _data(await _call('GET', '/sharees', query: {'search': q, 'itemType': 'folder', 'perPage': 10, 'lookup': 'false'}));
    final out = <SharePerson>[];
    if (data is Map) {
      final me = (await _storage.account()).user;
      for (final group in [data['exact'] is Map ? (data['exact'] as Map)['users'] : null, data['users']]) {
        for (final u in (group as List? ?? const [])) {
          if (u is! Map) continue;
          final value = u['value'];
          final id = value is Map ? value['shareWith'] : null;
          if (id is! String || id == me) continue;
          final person = SharePerson(id, (u['label'] as String?) ?? id, detail: id);
          if (!out.contains(person)) out.add(person);
        }
      }
    }
    return out;
  }

  @override
  Future<ProviderShare> share(String place, SharePerson person, ShareRole role) async {
    try {
      final data = _data(await _call('POST', '/shares', form: {'path': _absolute(place), 'shareType': 0, 'shareWith': person.id, 'permissions': rights(role)}));
      final s = _share(data);
      if (s != null) {
        // (shared with them already, the server answers with that share as it is: the role asked for has to be set)
        if (s.role == role) return s;
        await changeRole(s, role);
        return ProviderShare(s.id, s.person, role);
      }
    } on NativeShareException {
      // shared with them already: the share that is there gets the role asked for
      final existing = (await sharesOf(place)).where((s) => s.person.id == person.id).firstOrNull;
      if (existing == null) rethrow;
      if (existing.role != role) await changeRole(existing, role);
      return ProviderShare(existing.id, existing.person, role);
    }
    throw NativeShareException(tr('The Nextcloud did not share the folder.'));
  }

  @override
  Future<List<ProviderShare>> sharesOf(String place) async {
    final data = _data(await _call('GET', '/shares', query: {'path': _absolute(place), 'reshares': 'false', 'subfiles': 'false'}));
    return [for (final j in (data as List? ?? const [])) ?_share(j)];
  }

  @override
  Future<void> changeRole(ProviderShare share, ShareRole role) async {
    _data(await _call('PUT', '/shares/${share.id}', form: {'permissions': rights(role)}));
  }

  @override
  Future<void> unshare(ProviderShare share) async {
    final r = await _call('DELETE', '/shares/${share.id}');
    if (r.statusCode == 404) return; // gone already
    _data(r);
  }

  @override
  Future<void> removeFolder(String place) => folderAt(place).delete('');

  /// The shares given to the person: those they have taken in (`shared_with_me`), and those that wait for them. The server lists the
  /// waiting ones apart (`shares/pending`) and does not say what rights they have until they are accepted.
  @override
  Future<List<IncomingShare>> incoming() async {
    final out = <IncomingShare>[];
    for (final waiting in [false, true]) {
      Object? data;
      try {
        data = _data(waiting ? await _call('GET', '/shares/pending') : await _call('GET', '/shares', query: {'shared_with_me': 'true'}));
      } on NativeShareException {
        // (the list of the waiting shares is not offered or is blocked: those taken in are still shown)
        if (!waiting) rethrow;
        continue;
      }
      for (final j in (data as List? ?? const [])) {
        if (j is! Map || j['item_type'] != 'folder' || (j['share_type'] != null && j['share_type'] != 0)) continue;
        final target = waiting ? (j['path'] ?? j['file_target']) : j['file_target'];
        if (target is! String || target.isEmpty) continue;
        final owner = (j['displayname_owner'] as String?) ?? (j['uid_owner'] as String?) ?? '';
        final place = target.startsWith('/') ? target.substring(1) : target;
        out.add(IncomingShare(
          id: '${j['id']}',
          name: place.split('/').last,
          owner: owner,
          role: waiting ? ShareRole.viewer : roleOf(j['permissions']),
          roleKnown: !waiting,
          pending: waiting,
          place: waiting ? '' : place,
        ));
      }
    }
    return out;
  }

  @override
  Future<IncomingShare> accept(IncomingShare share) async {
    if (!share.pending) return share;
    _data(await _call('POST', '/shares/pending/${share.id}'));
    // it is mounted now, perhaps under another name than the one it was given: look it up
    final now = (await incoming()).where((s) => s.id == share.id && !s.pending).firstOrNull;
    if (now == null || now.place.isEmpty) throw NativeShareException(tr('The Nextcloud did not accept the share.'));
    return now;
  }

  @override
  Future<void> leave(IncomingShare share) async {
    final r = await _call('DELETE', '/shares/${share.id}');
    if (r.statusCode == 404) return;
    _data(r);
  }

  @override
  CloudFolder folderAt(String place) => _storage.folderFor(place);
}
