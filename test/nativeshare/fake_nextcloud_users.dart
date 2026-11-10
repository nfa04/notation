import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A Nextcloud with several users, enough for sharing a folder between them: WebDAV (a folder shared with someone appears at the top
/// of their files, under the permissions it was shared with) and the Share API (OCS) with the sharee search.
class FakeNextcloudUsers {
  late HttpServer server;
  final passwords = <String, String>{'alice': 'pw-a', 'bob': 'pw-b', 'carol': 'pw-c'};
  final names = <String, String>{'alice': 'Alice', 'bob': 'Bob', 'carol': 'Carol'};

  /// Each user's files and folders (paths start with `/`, folders have no trailing `/`).
  final files = <String, Map<String, Uint8List>>{};
  final dirs = <String, Set<String>>{};

  final shares = <Map<String, Object?>>[];
  int _nextId = 1;

  /// Whether a new share waits for the person to accept it (some servers are set up so).
  bool pendingShares = false;

  /// Refuses to make shares (a real server allows only so many in a few minutes).
  bool rateLimited = false;

  /// The requests the server saw, as `METHOD path`.
  final log = <String>[];

  FakeNextcloudUsers() {
    for (final u in passwords.keys) {
      files[u] = {};
      dirs[u] = {};
    }
  }

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> stop() => server.close(force: true);
  String get address => 'http://127.0.0.1:${server.port}';

  // ---- the files a user sees

  /// Where [rel] (a path in [user]'s files) really is, and what [user] may do there: 1 read, 2 update, 4 create, 8 delete.
  ({String owner, String path, int perms, bool isMount})? _resolve(String user, String rel) {
    final parts = rel.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isNotEmpty) {
      for (final s in shares) {
        if (s['with'] == user && s['state'] == 0 && s['target'] == '/${parts.first}') {
          return (owner: s['owner'] as String, path: '${s['path']}${parts.length > 1 ? '/${parts.sublist(1).join('/')}' : ''}', perms: s['perms'] as int, isMount: parts.length == 1);
        }
      }
    }
    return (owner: user, path: parts.isEmpty ? '' : '/${parts.join('/')}', perms: 31, isMount: false);
  }

  bool _isDir(String user, String path) => path.isEmpty || dirs[user]!.contains(path);

  Map<String, Object?> _json(Map<String, Object?> s) => {
        'id': '${s['id']}',
        'share_type': 0,
        'uid_owner': s['owner'],
        'displayname_owner': names[s['owner']],
        'permissions': s['perms'],
        'share_with': s['with'],
        'share_with_displayname': names[s['with']],
        'item_type': 'folder',
        'path': s['path'],
        'file_target': s['target'],
      };

  Future<void> _handle(HttpRequest req) async {
    final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
    final path = Uri.decodeFull(req.uri.path);
    log.add('${req.method} $path');
    void reply(int code, [Object body = '', String type = 'text/plain']) {
      req.response
        ..statusCode = code
        ..headers.contentType = ContentType.parse(type);
      if (body is List<int>) {
        req.response.add(body);
      } else {
        req.response.write(body);
      }
      req.response.close();
    }

    void ocs(int code, Object? data, {String message = 'OK'}) =>
        reply(code, jsonEncode({'ocs': {'meta': {'status': code < 300 ? 'ok' : 'failure', 'statuscode': code, 'message': message}, 'data': data}}), 'application/json');

    final auth = req.headers.value('authorization') ?? '';
    String? user;
    if (auth.startsWith('Basic ')) {
      final pair = utf8.decode(base64Decode(auth.substring(6))).split(':');
      if (passwords[pair.first] == pair.sublist(1).join(':')) user = pair.first;
    }
    if (user == null) return reply(401);
    final me = user;

    // ---- WebDAV
    final dav = '/remote.php/dav/files/$me';
    if (path == dav || path.startsWith('$dav/')) {
      final rel = path.substring(dav.length);
      final r = _resolve(me, rel);
      if (r == null) return reply(404);
      final tree = files[r.owner]!, folders = dirs[r.owner]!;
      String parentOf(String p) => p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '';
      switch (req.method) {
        case 'MKCOL':
          if (r.isMount || _isDir(r.owner, r.path) && r.path.isNotEmpty) return reply(405);
          if (r.perms & 4 == 0) return reply(403);
          if (!_isDir(r.owner, parentOf(r.path))) return reply(409);
          folders.add(r.path);
          return reply(201);
        case 'PUT':
          if (!_isDir(r.owner, parentOf(r.path))) return reply(409);
          final exists = tree.containsKey(r.path);
          if (r.perms & (exists ? 2 : 4) == 0) return reply(403);
          tree[r.path] = Uint8List.fromList(bytes);
          return reply(exists ? 204 : 201);
        case 'GET':
          if (r.perms & 1 == 0) return reply(403);
          final f = tree[r.path];
          return f == null ? reply(404) : reply(200, f, 'application/octet-stream');
        case 'DELETE':
          if (r.perms & 8 == 0) return reply(403);
          if (tree.remove(r.path) != null) return reply(204);
          if (folders.contains(r.path)) {
            folders.removeWhere((d) => d == r.path || d.startsWith('${r.path}/'));
            tree.removeWhere((k, _) => k.startsWith('${r.path}/'));
            shares.removeWhere((s) => s['owner'] == r.owner && ((s['path'] as String) == r.path || (s['path'] as String).startsWith('${r.path}/')));
            return reply(204);
          }
          return reply(404);
        case 'PROPFIND':
          if (r.perms & 1 == 0) return reply(403);
          if (!_isDir(r.owner, r.path)) return reply(404);
          final prefix = r.path.isEmpty ? '/' : '${r.path}/';
          final entries = <String>['$rel/'];
          for (final k in tree.keys) {
            if (k.startsWith(prefix) && !k.substring(prefix.length).contains('/')) entries.add('$rel${rel.endsWith('/') ? '' : '/'}${k.substring(prefix.length)}');
          }
          for (final d in folders) {
            if (d.startsWith(prefix) && !d.substring(prefix.length).contains('/')) entries.add('$rel${rel.endsWith('/') ? '' : '/'}${d.substring(prefix.length)}/');
          }
          // (the ETag of a directory follows everything below it, as on a real server)
          String etagOf(String p, {required bool dir}) {
            if (!dir) return '"${Object.hashAll(tree[p]!)}"';
            final below = [for (final k in tree.keys) if (k.startsWith('$p/')) '$k:${Object.hashAll(tree[k]!)}']..sort();
            final inner = [for (final d in folders) if (d.startsWith('$p/')) d]..sort();
            return '"${Object.hashAll([...below, ...inner].join('|').codeUnits)}"';
          }
          String propOf(String e) {
            final dir = e.endsWith('/');
            final real = e == '$rel/' ? r.path : '${r.path}/${e.substring(0, e.length - (dir ? 1 : 0)).split('/').last}';
            final tag = etagOf(real, dir: dir);
            return '<d:propstat><d:prop><d:getetag>${tag.replaceAll('"', '&quot;')}</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>';
          }
          return reply(207, '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${[for (final e in entries) '<d:response><d:href>${Uri.encodeFull('$dav$e')}</d:href>${propOf(e)}</d:response>'].join()}</d:multistatus>', 'application/xml');
      }
      return reply(405);
    }

    // ---- the Share API
    const api = '/ocs/v2.php/apps/files_sharing/api/v1';
    if (!path.startsWith(api)) return reply(404);
    final sub = path.substring(api.length);
    final form = req.method == 'POST' || req.method == 'PUT' ? Uri.splitQueryString(utf8.decode(bytes)) : <String, String>{};
    final q = req.uri.queryParameters;

    if (sub == '/sharees' && req.method == 'GET') {
      final s = (q['search'] ?? '').toLowerCase();
      final users = [
        for (final u in passwords.keys)
          if (u.startsWith(s) || names[u]!.toLowerCase().startsWith(s)) {'label': names[u], 'value': {'shareType': 0, 'shareWith': u}},
      ];
      return ocs(200, {'exact': {'users': []}, 'users': users});
    }
    if (sub == '/shares' && req.method == 'POST') {
      if (rateLimited) return reply(429, '{"message":"Too many requests"}', 'application/json');
      final p = form['path'] ?? '';
      final with_ = form['shareWith'] ?? '';
      if (form['shareType'] != '0' || !passwords.containsKey(with_) || with_ == me) return ocs(404, [], message: 'Wrong share recipient');
      if (!_isDir(me, p) || p.isEmpty) return ocs(404, [], message: "Wrong path, file/folder doesn't exist");
      // (a real server answers a share that exists with that share, as it is)
      final there = shares.where((s) => s['owner'] == me && s['path'] == p && s['with'] == with_).firstOrNull;
      if (there != null) return ocs(200, _json(there));
      var target = '/${p.split('/').last}';
      for (var n = 2; _isDir(with_, target) || files[with_]!.containsKey(target) || shares.any((s) => s['with'] == with_ && s['target'] == target); n++) {
        target = '/${p.split('/').last} ($n)';
      }
      final s = <String, Object?>{'id': _nextId++, 'owner': me, 'path': p, 'with': with_, 'perms': int.tryParse(form['permissions'] ?? '') ?? 1, 'target': target, 'state': pendingShares ? 1 : 0};
      shares.add(s);
      return ocs(200, _json(s));
    }
    if (sub == '/shares' && req.method == 'GET') {
      if (q['shared_with_me'] == 'true') {
        return ocs(200, [for (final s in shares) if (s['with'] == me && s['state'] == 0) _json(s)]);
      }
      final p = q['path'];
      return ocs(200, [for (final s in shares) if (s['owner'] == me && (p == null || s['path'] == p)) _json(s)]);
    }
    final one = RegExp(r'^/shares/(\d+)$').firstMatch(sub);
    if (one != null) {
      final id = int.parse(one.group(1)!);
      final s = shares.where((s) => s['id'] == id).firstOrNull;
      if (s == null) return ocs(404, [], message: 'Wrong share ID, share does not exist');
      if (req.method == 'PUT' && s['owner'] == me) {
        s['perms'] = int.tryParse(form['permissions'] ?? '') ?? s['perms'];
        return ocs(200, _json(s));
      }
      if (req.method == 'DELETE' && (s['owner'] == me || s['with'] == me)) {
        shares.remove(s);
        return ocs(200, []);
      }
      return ocs(403, [], message: 'Not allowed');
    }
    // (like the real server: the shares that wait are listed apart, without the rights they will have, with the name of the folder as "path")
    if (sub == '/shares/pending' && req.method == 'GET') {
      return ocs(200, [
        for (final s in shares)
          if (s['with'] == me && s['state'] == 1) {..._json(s), 'permissions': 0, 'path': '/${(s['path'] as String).split('/').last}'},
      ]);
    }
    final pending = RegExp(r'^/shares/pending/(\d+)$').firstMatch(sub);
    if (pending != null && req.method == 'POST') {
      final s = shares.where((s) => s['id'] == int.parse(pending.group(1)!) && s['with'] == me).firstOrNull;
      if (s == null) return ocs(404, [], message: 'Wrong share ID, share does not exist');
      s['state'] = 0;
      return ocs(200, []);
    }
    reply(404);
  }
}
