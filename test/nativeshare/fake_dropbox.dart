import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class _Shared {
  final String id, owner, path; // path: lower case, in the owner's Dropbox
  final String name;
  final members = <String, String>{}; // e-mail -> 'editor' | 'viewer'
  final mounted = <String, String>{}; // user -> path in that user's Dropbox
  _Shared(this.id, this.owner, this.path, this.name);
}

/// Enough of the Dropbox API for sharing a folder between people: files (upload, download, list, delete, metadata) and sharing (share a
/// folder, members, mounting). Everything, apart from the sign-in, is a call of the same server, as the app's two hosts are.
class FakeDropbox {
  late HttpServer server;
  String address = '';

  final users = <String, ({String user, String email, String name})>{
    'tokA': (user: 'alice', email: 'alice@example.org', name: 'Alice'),
    'tokB': (user: 'bob', email: 'bob@example.org', name: 'Bob'),
    'tokC': (user: 'carol', email: 'carol@example.org', name: 'Carol'),
  };

  /// What the sign-in says it allowed.
  String grantedScope = 'files.content.write files.content.read files.metadata.read sharing.write sharing.read';

  /// The app is an "app folder" app: it may not share.
  bool appFolderOnly = false;

  /// Makes `share_folder` answer with a job, as Dropbox does for big folders.
  bool asyncShare = false;

  final _files = <String, Map<String, Uint8List>>{}; // user -> path_lower -> bytes
  final _dirs = <String, Set<String>>{};
  final _shared = <String, _Shared>{};
  int _next = 1;
  final log = <String>[];

  String refreshTokenOf(String user) => 'RT-$user';

  Future<void> start() async {
    for (final u in users.values) {
      _files[u.user] = {};
      _dirs[u.user] = {};
    }
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    address = 'http://127.0.0.1:${server.port}';
    server.listen(_handle);
  }

  Future<void> stop() => server.close(force: true);

  /// Where [path] of [user] really is, and whether [user] may write there: the owner's Dropbox, or the folder shared with them.
  ({String owner, String path, bool write})? _resolve(String user, String email, String path) {
    final lower = path.toLowerCase();
    for (final s in _shared.values) {
      final mount = s.mounted[user];
      if (mount == null || s.owner == user) continue;
      if (lower == mount || lower.startsWith('$mount/')) {
        return (owner: s.owner, path: '${s.path}${lower.substring(mount.length)}', write: s.members[email] == 'editor');
      }
    }
    return (owner: user, path: lower, write: true);
  }

  void _mkdirs(String user, String path) {
    var p = path;
    while (p.isNotEmpty && p != '/') {
      _dirs[user]!.add(p);
      final i = p.lastIndexOf('/');
      p = i <= 0 ? '' : p.substring(0, i);
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final body = Uint8List.fromList(await req.fold<List<int>>([], (a, b) => a..addAll(b)));
    final path = req.uri.path;
    log.add('${req.method} $path');
    void send(int code, [Object? data, bool raw = false]) {
      req.response.statusCode = code;
      if (raw) {
        req.response.add(data as Uint8List);
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(data));
      }
      req.response.close();
    }

    void conflict(String summary) => send(409, {'error_summary': summary, 'error': {'.tag': summary.split('/').first}});

    if (path == '/oauth2/token') {
      final form = Uri.splitQueryString(utf8.decode(body));
      final entry = users.entries.where((e) => form['refresh_token'] == refreshTokenOf(e.value.user)).firstOrNull;
      if (entry == null) return send(400, {'error': 'invalid_grant'});
      return send(200, {'access_token': entry.key, 'refresh_token': form['refresh_token'], 'expires_in': 14400, 'scope': grantedScope});
    }
    final token = (req.headers.value('authorization') ?? '').replaceFirst('Bearer ', '');
    final who = users[token];
    if (who == null) return send(401, {'error_summary': 'invalid_access_token/'});

    Map<String, Object?> json() => body.isEmpty ? {} : (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
    final a = path.replaceFirst('/2/', '');

    // ---- files
    if (a == 'files/upload') {
      final arg = jsonDecode(req.headers.value('dropbox-api-arg')!) as Map;
      final r = _resolve(who.user, who.email, arg['path'] as String)!;
      if (!r.write) return conflict('path/no_write_permission/');
      _mkdirs(r.owner, r.path.substring(0, r.path.lastIndexOf('/')));
      _files[r.owner]![r.path] = body;
      return send(200, {'path_display': arg['path']});
    }
    if (a == 'files/download') {
      final arg = jsonDecode(req.headers.value('dropbox-api-arg')!) as Map;
      final r = _resolve(who.user, who.email, arg['path'] as String)!;
      final f = _files[r.owner]![r.path];
      return f == null ? conflict('path/not_found/') : send(200, f, true);
    }
    if (a == 'files/list_folder') {
      final r = _resolve(who.user, who.email, json()['path'] as String)!;
      if (!_dirs[r.owner]!.contains(r.path)) return conflict('path/not_found/');
      final prefix = '${r.path}/';
      return send(200, {
        'entries': [
          for (final k in _files[r.owner]!.keys)
            if (k.startsWith(prefix) && !k.substring(prefix.length).contains('/')) {'.tag': 'file', 'name': k.substring(prefix.length)},
          for (final d in _dirs[r.owner]!)
            if (d.startsWith(prefix) && !d.substring(prefix.length).contains('/')) {'.tag': 'folder', 'name': d.substring(prefix.length)},
        ],
        'has_more': false,
      });
    }
    if (a == 'files/delete_v2') {
      final r = _resolve(who.user, who.email, json()['path'] as String)!;
      if (!r.write) return conflict('path_lookup/no_write_permission/');
      final tree = _files[r.owner]!;
      if (tree.remove(r.path) != null) return send(200, {'metadata': {}});
      if (_dirs[r.owner]!.contains(r.path)) {
        _dirs[r.owner]!.removeWhere((d) => d == r.path || d.startsWith('${r.path}/'));
        tree.removeWhere((k, _) => k.startsWith('${r.path}/'));
        return send(200, {'metadata': {}});
      }
      return conflict('path_lookup/not_found/');
    }
    if (a == 'files/get_metadata') {
      final p = json()['path'] as String;
      final r = _resolve(who.user, who.email, p)!;
      if (!_dirs[r.owner]!.contains(r.path) && !_files[r.owner]!.containsKey(r.path)) return conflict('path/not_found/');
      final shared = _shared.values.where((s) => s.owner == r.owner && s.path == r.path).firstOrNull;
      return send(200, {'.tag': 'folder', 'name': p.split('/').last, 'path_lower': r.path, if (shared != null) 'sharing_info': {'shared_folder_id': shared.id}});
    }

    // ---- sharing
    if (a == 'sharing/share_folder') {
      if (appFolderOnly) return conflict('access_error/no_permission/');
      final p = (json()['path'] as String).toLowerCase();
      if (!_dirs[who.user]!.contains(p)) return conflict('bad_path/not_found/');
      final existing = _shared.values.where((s) => s.owner == who.user && s.path == p).firstOrNull;
      final s = existing ?? (_shared['SF${_next++}'] = _Shared('SF${_next - 1}', who.user, p, p.split('/').last));
      if (asyncShare && existing == null) return send(200, {'.tag': 'async_job_id', 'async_job_id': 'J-${s.id}'});
      return send(200, {'.tag': 'complete', 'shared_folder_id': s.id});
    }
    if (a == 'sharing/check_share_job_status') {
      final id = (json()['async_job_id'] as String).substring(2);
      return send(200, {'.tag': 'complete', 'shared_folder_id': id});
    }
    if (a == 'sharing/check_job_status') return send(200, {'.tag': 'complete'});
    final sf = _shared[json()['shared_folder_id']];
    switch (a) {
      case 'sharing/add_folder_member':
        if (sf == null || sf.owner != who.user) return conflict('access_error/no_permission/');
        for (final m in (json()['members'] as List)) {
          final email = (((m as Map)['member'] as Map)['email'] as String);
          if (sf.members.containsKey(email)) return conflict('already_a_member/');
          sf.members[email] = ((m['access_level'] as Map)['.tag'] as String);
        }
        return send(200, null);
      case 'sharing/list_folder_members':
        if (sf == null || sf.owner != who.user) return conflict('access_error/no_permission/');
        return send(200, {
          'users': [
            {'access_type': {'.tag': 'owner'}, 'user': {'account_id': 'dbid:${sf.owner}', 'email': who.email, 'display_name': who.name}},
            for (final e in sf.members.entries)
              if (users.values.any((u) => u.email == e.key && sf.mounted.containsKey(u.user)))
                {'access_type': {'.tag': e.value}, 'user': {'account_id': 'dbid:${users.values.firstWhere((u) => u.email == e.key).user}', 'email': e.key, 'display_name': users.values.firstWhere((u) => u.email == e.key).name}},
          ],
          'invitees': [
            for (final e in sf.members.entries)
              if (!users.values.any((u) => u.email == e.key && sf.mounted.containsKey(u.user)))
                {'access_type': {'.tag': e.value}, 'invitee': {'.tag': 'email', 'email': e.key}},
          ],
        });
      case 'sharing/update_folder_member':
      case 'sharing/remove_folder_member':
        if (sf == null || sf.owner != who.user) return conflict('access_error/no_permission/');
        final member = json()['member'] as Map;
        final email = member['.tag'] == 'email' ? member['email'] as String : users.values.firstWhere((u) => 'dbid:${u.user}' == member['dropbox_id']).email;
        if (!sf.members.containsKey(email)) return conflict('member_error/not_a_member/');
        if (a.endsWith('update_folder_member')) {
          sf.members[email] = ((json()['access_level'] as Map)['.tag'] as String);
          return send(200, {});
        }
        sf.members.remove(email);
        sf.mounted.removeWhere((u, _) => users.values.firstWhere((x) => x.user == u).email == email);
        return send(200, {'.tag': 'complete'});
      case 'sharing/unshare_folder':
        if (sf == null || sf.owner != who.user) return conflict('access_error/no_permission/');
        _shared.remove(sf.id);
        return send(200, {'.tag': 'complete'});
      case 'sharing/list_mountable_folders':
        return send(200, {
          'entries': [
            for (final s in _shared.values)
              if (s.owner == who.user || s.members.containsKey(who.email))
                {
                  'shared_folder_id': s.id,
                  'name': s.name,
                  'access_type': {'.tag': s.owner == who.user ? 'owner' : s.members[who.email]},
                  'owner_display_names': [users.values.firstWhere((u) => u.user == s.owner).name],
                  if (s.owner == who.user) 'path_lower': s.path else if (s.mounted[who.user] != null) 'path_lower': s.mounted[who.user],
                },
          ],
          'has_more': false,
        });
      case 'sharing/mount_folder':
        if (sf == null || !sf.members.containsKey(who.email)) return conflict('access_error/no_permission/');
        var mount = '/${sf.name}';
        for (var n = 2; _dirs[who.user]!.contains(mount) || _shared.values.any((s) => s.mounted[who.user] == mount); n++) {
          mount = '/${sf.name} ($n)';
        }
        sf.mounted[who.user] = mount;
        return send(200, {'shared_folder_id': sf.id, 'name': sf.name, 'path_lower': mount});
      case 'sharing/relinquish_folder_membership':
        if (sf == null || !sf.members.containsKey(who.email)) return conflict('access_error/no_permission/');
        sf.members.remove(who.email);
        sf.mounted.remove(who.user);
        return send(200, {'.tag': 'complete'});
    }
    send(404, {'error_summary': 'unknown'});
  }
}
