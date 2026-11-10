import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../cloudsync/cloud_folder.dart';
import '../collab/onedrive_storage.dart';
import '../l10n/language.dart';
import 'native_share_provider.dart';

/// Sharing a folder with other people who have a Microsoft account, through OneDrive (personal, or work or school), by Microsoft Graph:
/// the folder in the app's folder is shared with `invite` (the person by e-mail address, with the right to read or to write), and the
/// files are read and written through the same folder by the person's own item address.
///
/// OneDrive cannot be asked what has been shared with a person (the list it had, `sharedWithMe`, is retired), so the invitation carries
/// a **link**: `notation://share?p=onedrive&s=<share id>`. The sender gives it to the person (the invitation e-mail of Microsoft has a
/// link to the folder as well, which is read too); the person adds it, and the share is listed from then on. See `docs/native-sharing.md`.
class OneDriveShares extends NativeShareProvider {
  final OneDriveStorage _storage;

  OneDriveShares(this._storage);

  @override
  String get id => 'onedrive';

  @override
  String get label => 'OneDrive';

  @override
  bool get available => _storage.available;

  @override
  String? get unsupportedReason {
    if (!_storage.available) return null;
    if (!_storage.sharingEnabled) return tr('Allow sharing with people in the OneDrive settings first (it needs access to all your files).');
    if (!_storage.canShare) return tr('Sign in to OneDrive again, so that it can be allowed to share.');
    return null;
  }

  @override
  bool get acceptsLinks => true;

  String get _graph => '${_storage.graphHost}/v1.0';

  static String _enc(String path) => path.split('/').where((p) => p.isNotEmpty).map(Uri.encodeComponent).join('/');

  NativeShareException _fail(Response<dynamic> r) {
    final data = r.data;
    final error = data is Map && data['error'] is Map ? data['error'] as Map : const {};
    final code = '${error['code'] ?? ''}';
    if (r.statusCode == 401) return NativeShareException(tr('OneDrive did not accept the sign-in. Sign in again in the settings.'));
    if (code == 'accessDenied' || code == 'notAllowed' || r.statusCode == 403) {
      return NativeShareException(tr('OneDrive does not allow sharing with this person here (an administrator can forbid it for work and school accounts).'));
    }
    if (r.statusCode == 429) return NativeShareException(tr('OneDrive says to wait a little. Try again in a few minutes.'));
    final message = error['message'];
    if (r.statusCode == 400 && message is String && message.isNotEmpty) return NativeShareException(message);
    return NativeShareException(_storage.errorText(r));
  }

  Future<Response<dynamic>> _get(String url, {Map<String, String>? headers}) async =>
      _storage.http.get<dynamic>(url, options: Options(headers: {...await _storage.authHeaders(), ...?headers}));

  /// The folder [place] of the app's folder as an item: its id and where it is.
  Future<({String id, String driveId, String? webUrl})> _item(String place) async {
    final r = await _get('$_graph/me/drive/special/approot:/${_enc(place)}?\$select=id,name,parentReference,webUrl');
    final d = r.data;
    if (r.statusCode == 404) throw NativeShareException(tr('The shared folder is not on your OneDrive (any more).'));
    if (r.statusCode != 200 || d is! Map || d['id'] is! String) throw _fail(r);
    final parent = d['parentReference'];
    return (id: d['id'] as String, driveId: parent is Map ? '${parent['driveId'] ?? ''}' : '', webUrl: d['webUrl'] as String?);
  }

  static ShareRole _role(Object? roles) => roles is List && (roles.contains('write') || roles.contains('owner')) ? ShareRole.editor : ShareRole.viewer;

  static String _link(String? shareId, String? webUrl) {
    final query = shareId != null ? {'p': 'onedrive', 's': shareId} : {'p': 'onedrive', 'u': webUrl ?? ''};
    return Uri(scheme: 'notation', host: 'share', queryParameters: query).toString();
  }

  @override
  Future<List<SharePerson>> searchPeople(String query) async => const []; // (the address is typed: the app has no right to look in the address book)

  @override
  Future<ProviderShare> share(String place, SharePerson person, ShareRole role) async {
    final item = await _item(place);
    final r = await _storage.http.post<dynamic>(
      '$_graph/me/drive/items/${item.id}/invite',
      data: jsonEncode({
        'recipients': [
          {'email': person.id},
        ],
        'roles': [role == ShareRole.editor ? 'write' : 'read'],
        'requireSignIn': true,
        'sendInvitation': true,
        'message': tr('Shared with Notation. Open the link in the invitation, or add it in the app: Settings, Sharing and files.'),
      }),
      options: Options(headers: {...await _storage.authHeaders(), 'Content-Type': 'application/json'}),
    );
    final d = r.data;
    if (r.statusCode != 200 && r.statusCode != 207 || d is! Map) throw _fail(r);
    final given = (d['value'] as List? ?? const []).firstOrNull;
    if (given is! Map || given['error'] != null) {
      final inner = given is Map && given['error'] is Map ? (given['error'] as Map)['message'] : null;
      throw NativeShareException(inner is String && inner.isNotEmpty ? inner : tr('OneDrive did not share the folder.'));
    }
    return ProviderShare('${item.id}/${given['id']}', person, _role(given['roles']) == role ? role : _role(given['roles']),
        link: _link(given['shareId'] as String?, item.webUrl));
  }

  @override
  Future<List<ProviderShare>> sharesOf(String place) async {
    final item = await _item(place);
    final r = await _get('$_graph/me/drive/items/${item.id}/permissions');
    final d = r.data;
    if (r.statusCode != 200 || d is! Map) throw _fail(r);
    final out = <ProviderShare>[];
    for (final p in (d['value'] as List? ?? const [])) {
      if (p is! Map || p['link'] != null || p['inheritedFrom'] != null) continue; // (invitations of people only)
      final user = (p['grantedToV2'] is Map ? (p['grantedToV2'] as Map)['user'] : null) ?? (p['grantedTo'] is Map ? (p['grantedTo'] as Map)['user'] : null);
      final email = (p['invitation'] is Map ? (p['invitation'] as Map)['email'] : null) ?? (user is Map ? user['email'] : null);
      final name = user is Map ? user['displayName'] : null;
      if (email is! String && name is! String) continue;
      final roles = p['roles'];
      if (roles is List && roles.contains('owner')) continue;
      final address = email is String ? email : '';
      out.add(ProviderShare('${item.id}/${p['id']}', SharePerson(address.isEmpty ? '$name' : address, name is String ? name : address, detail: address), _role(roles)));
    }
    return out;
  }

  /// `itemId/permissionId`, as [ProviderShare.id] is made.
  static (String, String) _ids(ProviderShare s) {
    final i = s.id.indexOf('/');
    return i < 0 ? ('', s.id) : (s.id.substring(0, i), s.id.substring(i + 1));
  }

  @override
  Future<void> changeRole(ProviderShare share, ShareRole role) async {
    final (item, perm) = _ids(share);
    final r = await _storage.http.patch<dynamic>(
      '$_graph/me/drive/items/$item/permissions/$perm',
      data: jsonEncode({'roles': [role == ShareRole.editor ? 'write' : 'read']}),
      options: Options(headers: {...await _storage.authHeaders(), 'Content-Type': 'application/json'}),
    );
    if (r.statusCode != 200) throw _fail(r);
  }

  @override
  Future<void> unshare(ProviderShare share) async {
    final (item, perm) = _ids(share);
    final r = await _storage.http.delete<dynamic>('$_graph/me/drive/items/$item/permissions/$perm', options: Options(headers: await _storage.authHeaders()));
    if (r.statusCode != 204 && r.statusCode != 200 && r.statusCode != 404) throw _fail(r);
  }

  @override
  Future<void> removeFolder(String place) async {
    final r = await _storage.http.delete<dynamic>('$_graph/me/drive/special/approot:/${_enc(place)}', options: Options(headers: await _storage.authHeaders()));
    if (r.statusCode != 204 && r.statusCode != 200 && r.statusCode != 404) throw _fail(r);
  }

  // ---- receiving: the links the person added

  static const _linksKey = 'onedrive_share_links';

  Future<List<String>> _links() async {
    try {
      return [for (final l in (jsonDecode(await _storage.settings?.get(_linksKey) ?? '[]') as List)) '$l'];
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveLinks(List<String> links) async {
    if (links.isEmpty) {
      await _storage.settings?.remove(_linksKey);
    } else {
      await _storage.settings?.set(_linksKey, jsonEncode(links));
    }
  }

  static final _web = RegExp(r'https://(?:[a-z0-9-]+\.)*(?:1drv\.ms|onedrive\.live\.com|sharepoint\.com)/[^\s]*', caseSensitive: false);

  /// The key a link stands for: the share id (`s`), or the web address encoded for the shares API (`u!...`). Null: not a link to a share.
  static String? keyOf(String text) {
    final t = text.trim();
    final app = RegExp(r'notation://share[^\s]*').firstMatch(t);
    if (app != null) {
      final uri = Uri.tryParse(app.group(0)!);
      if (uri == null || uri.host != 'share' || uri.queryParameters['p'] != 'onedrive') return null;
      final s = uri.queryParameters['s'];
      if (s != null && s.isNotEmpty && s.length < 600) return s;
      final u = Uri.tryParse(uri.queryParameters['u'] ?? '');
      return u != null && u.scheme == 'https' && _web.hasMatch('$u') ? _encode('$u') : null;
    }
    final web = _web.firstMatch(t);
    return web == null ? null : _encode(web.group(0)!);
  }

  static String _encode(String url) => 'u!${base64Url.encode(utf8.encode(url)).replaceAll('=', '')}';

  @override
  bool recognizes(String text) => keyOf(text) != null;

  /// What a link opens (null: it opens nothing the person may reach).
  Future<IncomingShare?> _resolve(String key) async {
    final shares = '$_graph/shares/${Uri.encodeComponent(key)}';
    // (redeeming the link is what lets the person reach the folder by its own address afterwards)
    final r = await _get('$shares/driveItem?\$select=id,name,folder,parentReference,createdBy,shared', headers: {'Prefer': 'redeemSharingLink'});
    if (r.statusCode == 401) throw _fail(r);
    final d = r.data;
    if (r.statusCode == 403 || r.statusCode == 404 || r.statusCode == 400) return null;
    if (r.statusCode != 200 || d is! Map) throw _fail(r);
    final parent = d['parentReference'];
    final driveId = parent is Map ? parent['driveId'] : null;
    final itemId = d['id'];
    if (d['folder'] == null || driveId is! String || itemId is! String) return null;
    var role = ShareRole.viewer;
    var known = false;
    final p = await _get('$shares/permission');
    if (p.statusCode == 200 && p.data is Map) {
      role = _role((p.data as Map)['roles']);
      known = true;
    }
    String? nameOf(Object? who) => who is Map && who['user'] is Map ? (who['user'] as Map)['displayName'] as String? : null;
    final owner = nameOf(d['shared'] is Map ? (d['shared'] as Map)['owner'] : null) ?? nameOf(d['createdBy']) ?? '';
    return IncomingShare(id: key, name: '${d['name']}', owner: owner, role: role, roleKnown: known, place: 'od:$driveId:$itemId');
  }

  @override
  Future<IncomingShare> addLink(String text) async {
    final key = keyOf(text);
    if (key == null) throw NativeShareException(tr('This is not a link to a share.'));
    final found = await _resolve(key);
    if (found == null) throw NativeShareException(tr('This link does not open a shared folder for you. Are you signed in with the account that was invited?'));
    if (!ShareNaming.isOurs(found.name)) throw NativeShareException(tr('This is not a share from Notation.'));
    final links = await _links();
    if (!links.contains(key)) await _saveLinks([...links, key]);
    return found;
  }

  @override
  Future<List<IncomingShare>> incoming() async {
    final out = <IncomingShare>[];
    for (final key in await _links()) {
      final s = await _resolve(key);
      if (s != null && ShareNaming.isOurs(s.name)) out.add(s); // (a link that opens nothing now: the share was withdrawn)
    }
    return out;
  }

  @override
  Future<void> leave(IncomingShare share) async {
    // (the invitation itself stays with the owner: only the owner can take a person away)
    await _saveLinks([for (final l in await _links()) if (l != share.id) l]);
  }

  @override
  CloudFolder folderAt(String place) {
    final m = RegExp(r'^od:([^:]+):(.+)$').firstMatch(place);
    return m == null ? _storage.folderFor(place) : _OneDriveItemFolder(_storage, m.group(1)!, m.group(2)!);
  }
}

/// A folder that was shared with the person, by the address of the item: the files in it are read and written below it.
class _OneDriveItemFolder implements CloudFolder {
  @override
  Future<Map<String, String>?> stamps(String dir) async => null;
  final OneDriveStorage _storage;
  final String _drive, _item;

  _OneDriveItemFolder(this._storage, this._drive, this._item);

  @override
  String get label => 'OneDrive';

  String get _base => '${_storage.graphHost}/v1.0/drives/${Uri.encodeComponent(_drive)}/items/${Uri.encodeComponent(_item)}';

  String _at(String path) {
    final clean = OneDriveShares._enc(path);
    return clean.isEmpty ? _base : '$_base:/$clean';
  }

  CloudFolderException _fail(Response<dynamic> r) => CloudFolderException(_storage.errorText(r), r.statusCode);

  @override
  Future<List<String>> list(String dir) async {
    final auth = await _storage.authHeaders();
    final names = <String>[];
    final at = _at(dir);
    String? url = '${dir.isEmpty ? at : '$at:'}/children?\$select=name,file&\$top=200';
    while (url != null) {
      final r = await _storage.http.get<dynamic>(url, options: Options(headers: auth));
      if (r.statusCode == 404) return const [];
      final data = r.data;
      if (r.statusCode != 200 || data is! Map) throw _fail(r);
      for (final e in (data['value'] as List? ?? const [])) {
        if (e is Map && e['file'] != null) names.add(e['name'] as String);
      }
      url = data['@odata.nextLink'] as String?;
    }
    return names;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final auth = await _storage.authHeaders();
    // the content address answers with a redirect to the file; the sign-in is for Microsoft, not for where it leads
    final r = await _storage.http.get<List<int>>(
      '${_at(path)}:/content',
      options: Options(headers: auth, followRedirects: false, responseType: ResponseType.bytes, validateStatus: (s) => s != null && s < 500),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode == 302 || r.statusCode == 301 || r.statusCode == 307) {
      final to = r.headers.value('location');
      if (to == null) throw _fail(r);
      final file = await _storage.http.get<List<int>>(to, options: Options(responseType: ResponseType.bytes));
      if (file.statusCode != 200 || file.data == null) throw _fail(file);
      return Uint8List.fromList(file.data!);
    }
    if (r.statusCode != 200 || r.data == null) throw _fail(r);
    return Uint8List.fromList(r.data!);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    try {
      await _storage.putAt(_storage.http, await _storage.authHeaders(), _at(path), bytes, 'replace');
    } on StateError catch (e) {
      throw CloudFolderException('$e'.replaceFirst('Bad state: ', ''));
    }
  }

  @override
  Future<void> delete(String path) async {
    final r = await _storage.http.delete<dynamic>(_at(path), options: Options(headers: await _storage.authHeaders()));
    if (r.statusCode != 204 && r.statusCode != 200 && r.statusCode != 404) throw _fail(r);
  }
}
