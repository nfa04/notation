import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../cloudsync/cloud_folder.dart';
import '../collab/dropbox_storage.dart';
import '../l10n/language.dart';
import 'native_share_provider.dart';

/// Sharing a folder with other people who have a Dropbox, by its sharing API: the folder is made a shared folder, people are added by
/// e-mail address as viewers or editors, and a folder shared with the person is mounted in their Dropbox, where the files are read and
/// written like any other. It needs an app registered with the access type "Full Dropbox" (see `collab/defaults.dart`): an app folder app
/// cannot share its folder or reach one that is shared with the person.
class DropboxShares extends NativeShareProvider {
  final DropboxStorage _storage;

  DropboxShares(this._storage);

  @override
  String get id => 'dropbox';

  @override
  String get label => 'Dropbox';

  @override
  bool get available => _storage.available;

  @override
  String? get unsupportedReason {
    if (!_storage.available) return null;
    if (!_storage.sharingEnabled) return tr('Allow sharing with people in the Dropbox settings first (it needs a Dropbox app with access to the whole Dropbox).');
    if (!_storage.canShare) return tr('Sign in to Dropbox again, so that it can be allowed to share.');
    return null;
  }

  Future<Response<dynamic>> _post(String method, [Map<String, Object?>? body]) async => _storage.http.post<dynamic>(
        '${_storage.apiHost}/2/$method',
        data: body == null ? null : jsonEncode(body),
        options: Options(headers: {...await _storage.authHeaders(), if (body != null) 'Content-Type': 'application/json'}),
      );

  NativeShareException _fail(Response<dynamic> r) {
    final data = r.data;
    final summary = data is Map ? '${data['error_summary'] ?? ''}' : '';
    if (r.statusCode == 401) return NativeShareException(tr('Dropbox did not accept the sign-in. Sign in again in the settings.'));
    if (r.statusCode == 429) return NativeShareException(tr('Dropbox says to wait a little. Try again in a few minutes.'));
    if (summary.contains('no_permission') || summary.contains('app_folder') || summary.contains('access_error') || r.statusCode == 403) {
      return NativeShareException(tr('This Dropbox app is not allowed to share. It has to be registered with access to the whole Dropbox, and with the sharing permissions.'));
    }
    if (summary.contains('email_unverified')) return NativeShareException(tr('Your Dropbox e-mail address has to be verified before you can share.'));
    if (summary.contains('insufficient_plan')) return NativeShareException(tr('Your Dropbox plan does not allow sharing with this many people.'));
    if (summary.contains('not_found')) return NativeShareException(tr('The shared folder is not on your Dropbox (any more).'));
    return NativeShareException(_storage.errorText(r));
  }

  Object? _ok(Response<dynamic> r) {
    if (r.statusCode != 200) throw _fail(r);
    return r.data;
  }

  static String _path(String place) => '/${place.split('/').where((p) => p.isNotEmpty).join('/')}';

  /// A path of the Dropbox as the place of a folder: without the slash in front (see [folderAt]).
  static String _rel(String path) => _path(path).substring(1);

  static String _tag(ShareRole r) => r == ShareRole.editor ? 'editor' : 'viewer';

  static ShareRole _role(Object? access) {
    final tag = access is Map ? access['.tag'] : access;
    return tag == 'editor' || tag == 'owner' ? ShareRole.editor : ShareRole.viewer;
  }

  /// Waits for a job that Dropbox does in the background (`async_job_id`), a few seconds at most.
  Future<void> _job(Object? answer, String checkMethod) async {
    if (answer is! Map || answer['.tag'] != 'async_job_id') return;
    for (var i = 0; i < 20; i++) {
      final r = await _post(checkMethod, {'async_job_id': answer['async_job_id']});
      final d = _ok(r);
      final tag = d is Map ? d['.tag'] : null;
      if (tag == 'complete') return;
      if (tag == 'failed') throw NativeShareException(tr('Dropbox did not do it.'));
      await Future<void>.delayed(Duration(milliseconds: 100 * (i + 1)));
    }
  }

  /// The id of the shared folder at [place]; the folder is made a shared folder when it is not yet one.
  Future<String> _sharedFolderId(String place, {bool make = true}) async {
    final meta = await _post('files/get_metadata', {'path': _path(place)});
    if (meta.statusCode == 409) throw NativeShareException(tr('The shared folder is not on your Dropbox (any more).'));
    final info = _ok(meta);
    final existing = info is Map && info['sharing_info'] is Map ? (info['sharing_info'] as Map)['shared_folder_id'] : null;
    if (existing is String) return existing;
    if (!make) throw NativeShareException(tr('The shared folder is not on your Dropbox (any more).'));
    final r = await _post('sharing/share_folder', {'path': _path(place), 'member_policy': {'.tag': 'anyone'}, 'acl_update_policy': {'.tag': 'owner'}, 'force_async': false});
    final d = _ok(r);
    if (d is Map && d['.tag'] == 'async_job_id') {
      for (var i = 0; i < 20; i++) {
        final s = _ok(await _post('sharing/check_share_job_status', {'async_job_id': d['async_job_id']}));
        if (s is Map && s['.tag'] == 'complete' && s['shared_folder_id'] is String) return s['shared_folder_id'] as String;
        if (s is Map && s['.tag'] == 'failed') throw NativeShareException(tr('Dropbox did not share the folder.'));
        await Future<void>.delayed(Duration(milliseconds: 100 * (i + 1)));
      }
      throw NativeShareException(tr('Dropbox is slow to share the folder. Try again in a moment.'));
    }
    final id = d is Map ? d['shared_folder_id'] : null;
    if (id is! String) throw NativeShareException(tr('Dropbox did not share the folder.'));
    return id;
  }

  /// How a person is named in the calls that change them: `sfid|email:<address>` or `sfid|id:<account id>` as [ProviderShare.id].
  static Map<String, Object?> _member(String key) {
    final i = key.indexOf(':');
    final kind = key.substring(0, i), value = key.substring(i + 1);
    return kind == 'email' ? {'.tag': 'email', 'email': value} : {'.tag': 'dropbox_id', 'dropbox_id': value};
  }

  static (String, String) _ids(ProviderShare s) {
    final i = s.id.indexOf('|');
    return (s.id.substring(0, i), s.id.substring(i + 1));
  }

  @override
  Future<List<SharePerson>> searchPeople(String query) async => const []; // (the address is typed)

  @override
  Future<ProviderShare> share(String place, SharePerson person, ShareRole role) async {
    final sfid = await _sharedFolderId(place);
    final r = await _post('sharing/add_folder_member', {
      'shared_folder_id': sfid,
      'members': [
        {'member': {'.tag': 'email', 'email': person.id}, 'access_level': {'.tag': _tag(role)}},
      ],
      'quiet': false,
      'custom_message': tr('Shared with Notation. Accept it in your Dropbox, then it is listed in the app: Settings, Sharing and files.'),
    });
    if (r.statusCode == 409 && '${(r.data is Map ? (r.data as Map)['error_summary'] : '')}'.contains('already')) {
      // (added already: the role asked for is set)
      final existing = (await sharesOf(place)).where((s) => s.person.id.toLowerCase() == person.id.toLowerCase()).firstOrNull;
      if (existing != null) {
        if (existing.role != role) await changeRole(existing, role);
        return ProviderShare(existing.id, existing.person, role);
      }
    }
    _ok(r);
    return ProviderShare('$sfid|email:${person.id}', person, role);
  }

  @override
  Future<List<ProviderShare>> sharesOf(String place) async {
    final sfid = await _sharedFolderId(place, make: false);
    final d = _ok(await _post('sharing/list_folder_members', {'shared_folder_id': sfid, 'limit': 200}));
    final out = <ProviderShare>[];
    if (d is Map) {
      for (final u in (d['users'] as List? ?? const [])) {
        if (u is! Map || u['user'] is! Map) continue;
        final access = (u['access_type'] as Map?)?['.tag'];
        if (access == 'owner') continue;
        final user = u['user'] as Map;
        final email = '${user['email'] ?? ''}', name = '${user['display_name'] ?? email}';
        out.add(ProviderShare('$sfid|id:${user['account_id']}', SharePerson(email.isEmpty ? name : email, name, detail: email), _role(access)));
      }
      for (final i in (d['invitees'] as List? ?? const [])) {
        if (i is! Map || i['invitee'] is! Map) continue;
        final email = (i['invitee'] as Map)['email'];
        if (email is! String) continue;
        out.add(ProviderShare('$sfid|email:$email', SharePerson(email, email, detail: email), _role((i['access_type'] as Map?)?['.tag'])));
      }
    }
    return out;
  }

  @override
  Future<void> changeRole(ProviderShare share, ShareRole role) async {
    final (sfid, who) = _ids(share);
    _ok(await _post('sharing/update_folder_member', {'shared_folder_id': sfid, 'member': _member(who), 'access_level': {'.tag': _tag(role)}}));
  }

  @override
  Future<void> unshare(ProviderShare share) async {
    final (sfid, who) = _ids(share);
    final r = await _post('sharing/remove_folder_member', {'shared_folder_id': sfid, 'member': _member(who), 'leave_a_copy': false});
    if (r.statusCode == 409 && '${(r.data is Map ? (r.data as Map)['error_summary'] : '')}'.contains('not_a_member')) return; // gone already
    await _job(_ok(r), 'sharing/check_job_status');
  }

  @override
  Future<void> removeFolder(String place) async {
    try {
      final sfid = await _sharedFolderId(place, make: false);
      final r = await _post('sharing/unshare_folder', {'shared_folder_id': sfid, 'leave_a_copy': false});
      if (r.statusCode == 200) await _job(r.data, 'sharing/check_job_status');
    } on NativeShareException {
      // not shared any more, or not there: the folder itself is taken away all the same
    }
    final r = await _post('files/delete_v2', {'path': _path(place)});
    if (r.statusCode != 200 && r.statusCode != 409) throw _fail(r);
  }

  @override
  Future<List<IncomingShare>> incoming() async {
    final out = <IncomingShare>[];
    String? cursor;
    var r = await _post('sharing/list_mountable_folders', {});
    while (true) {
      final d = _ok(r);
      if (d is! Map) break;
      for (final e in (d['entries'] as List? ?? const [])) {
        if (e is! Map || e['shared_folder_id'] is! String) continue;
        final access = (e['access_type'] as Map?)?['.tag'];
        if (access == 'owner') continue; // (the person's own)
        final name = '${e['name']}';
        final path = e['path_lower'];
        final owners = e['owner_display_names'];
        out.add(IncomingShare(
          id: e['shared_folder_id'] as String,
          name: name,
          owner: owners is List && owners.isNotEmpty ? '${owners.first}' : '',
          role: _role(access),
          pending: path is! String || path.isEmpty,
          place: path is String ? _rel(path) : '',
        ));
      }
      cursor = d['cursor'] as String?;
      if (d['has_more'] != true || cursor == null) break;
      r = await _post('sharing/list_mountable_folders/continue', {'cursor': cursor});
    }
    return out;
  }

  @override
  Future<IncomingShare> accept(IncomingShare share) async {
    if (!share.pending) return share;
    final d = _ok(await _post('sharing/mount_folder', {'shared_folder_id': share.id}));
    final path = d is Map ? d['path_lower'] : null;
    if (path is! String || path.isEmpty) throw NativeShareException(tr('Dropbox did not accept the share.'));
    return IncomingShare(id: share.id, name: share.name, owner: share.owner, role: share.role, place: _rel(path));
  }

  @override
  Future<void> leave(IncomingShare share) async {
    final r = await _post('sharing/relinquish_folder_membership', {'shared_folder_id': share.id, 'leave_a_copy': true});
    if (r.statusCode == 409) return; // not a member any more
    await _job(_ok(r), 'sharing/check_job_status');
  }

  @override
  CloudFolder folderAt(String place) => _storage.folderFor(place);
}
