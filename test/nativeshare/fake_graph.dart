import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class _Node {
  final String id, drive;
  String path;
  final bool isDir;
  Uint8List? bytes;
  final grants = <String, Map<String, Object?>>{}; // permission id -> {email, roles, shareId}

  _Node(this.id, this.drive, this.path, this.isDir);

  String get name => path.split('/').last;
}

/// Enough of Microsoft Graph for sharing a folder between two people: the app folder, items by id and by path, upload sessions, the
/// redirect that downloads, `invite` and the permissions, and the shares API that opens a link.
class FakeGraph {
  late HttpServer server;
  String address = '';

  /// token -> user, e-mail address, display name
  final users = <String, ({String user, String email, String name})>{
    'tokA': (user: 'alice', email: 'alice@example.org', name: 'Alice'),
    'tokB': (user: 'bob', email: 'bob@example.org', name: 'Bob'),
    'tokC': (user: 'carol', email: 'carol@example.org', name: 'Carol'),
  };

  final _nodes = <String, _Node>{};
  final _byPath = <String, String>{};
  final _uploads = <String, ({String drive, String path, BytesBuilder data})>{};
  int _next = 1;

  /// What a run of the server was asked, as `METHOD path`.
  final log = <String>[];

  /// Makes `invite` fail as an administrator who forbids sharing would.
  bool forbidInvite = false;

  /// Whether the answer to an invitation tells the id of the share (`shareId`); some do not.
  bool tellsShareId = true;

  /// What the sign-in says it allowed.
  String grantedScope = 'Files.ReadWrite.All offline_access';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    address = 'http://127.0.0.1:${server.port}';
    server.listen(_handle);
  }

  Future<void> stop() => server.close(force: true);

  String refreshTokenOf(String user) => 'RT-$user';

  // ---- the tree

  _Node? _at(String drive, String path) {
    final id = _byPath['$drive|$path'];
    return id == null ? null : _nodes[id];
  }

  _Node _make(String drive, String path, {required bool dir}) {
    final existing = _at(drive, path);
    if (existing != null) return existing;
    final slash = path.lastIndexOf('/');
    if (slash > 0) _make(drive, path.substring(0, slash), dir: true);
    final n = _Node('I${_next++}', drive, path, dir);
    _nodes[n.id] = n;
    _byPath['$drive|$path'] = n.id;
    return n;
  }

  void _remove(_Node n) {
    final gone = [for (final x in _nodes.values) if (x.drive == n.drive && (x.path == n.path || x.path.startsWith('${n.path}/'))) x];
    for (final x in gone) {
      _nodes.remove(x.id);
      _byPath.remove('${x.drive}|${x.path}');
    }
  }

  /// Whether [email] may read (or write) at [n]: it is the owner's drive, or an invitation on the item or a folder above it says so.
  bool _may(({String user, String email, String name}) who, _Node n, {required bool write}) {
    if (n.drive == 'd-${who.user}') return true;
    var path = n.path;
    while (true) {
      final here = _at(n.drive, path);
      if (here != null) {
        for (final g in here.grants.values) {
          final roles = g['roles'] as List;
          if (g['email'] == who.email && (!write || roles.contains('write'))) return true;
        }
      }
      final slash = path.lastIndexOf('/');
      if (slash <= 0) return false;
      path = path.substring(0, slash);
    }
  }

  // ---- the server

  Future<void> _handle(HttpRequest req) async {
    final body = Uint8List.fromList(await req.fold<List<int>>([], (a, b) => a..addAll(b)));
    final path = Uri.decodeFull(req.uri.path);
    log.add('${req.method} $path');
    void send(int code, [Object? data]) {
      req.response.statusCode = code;
      if (data is Uint8List) {
        req.response.add(data);
      } else if (data != null) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(data));
      }
      req.response.close();
    }

    void error(int code, String c, [String m = '']) => send(code, {'error': {'code': c, 'message': m}});

    if (path == '/token') {
      final form = Uri.splitQueryString(utf8.decode(body));
      final entry = users.entries.where((e) => form['refresh_token'] == refreshTokenOf(e.value.user)).firstOrNull;
      if (entry == null) return send(400, {'error': 'invalid_grant'});
      return send(200, {'access_token': entry.key, 'refresh_token': form['refresh_token'], 'expires_in': 3600, 'scope': grantedScope});
    }
    if (path.startsWith('/dl/')) {
      final n = _nodes[path.substring(4)];
      return n?.bytes == null ? send(404) : send(200, n!.bytes);
    }
    if (path.startsWith('/upload/')) {
      final u = _uploads[path.substring(8)];
      if (u == null) return send(404);
      u.data.add(body);
      final range = RegExp(r'bytes (\d+)-(\d+)/(\d+)').firstMatch(req.headers.value('content-range') ?? '');
      if (range != null && int.parse(range.group(2)!) + 1 < int.parse(range.group(3)!)) return send(202, {});
      final n = _make(u.drive, u.path, dir: false)..bytes = u.data.toBytes();
      _uploads.remove(path.substring(8));
      return send(201, {'id': n.id});
    }

    final token = (req.headers.value('authorization') ?? '').replaceFirst('Bearer ', '');
    final who = users[token];
    if (who == null) return error(401, 'InvalidAuthenticationToken');
    final drive = 'd-${who.user}';

    // ---- the shares API: what a link opens
    final share = RegExp(r'^/v1\.0/shares/([^/]+)/(driveItem|permission)$').firstMatch(path);
    if (share != null) {
      var key = share.group(1)!;
      if (key.startsWith('u!')) {
        // an address: the link of the invitation is `https://1drv.ms/f/s!<share id>`
        final url = utf8.decode(base64Url.decode(base64Url.normalize(key.substring(2))));
        final item = RegExp(r'redir\?id=(I\d+)$').firstMatch(url);
        if (item != null) {
          // the address of an item: it opens for whoever has a grant on it
          final grants = _nodes[item.group(1)]?.grants.values.where((g) => g['email'] == who.email);
          key = grants == null || grants.isEmpty ? '' : grants.first['shareId'] as String;
        } else {
          key = url.split('/').last.replaceFirst('s!', '');
        }
      }
      for (final n in _nodes.values) {
        for (final g in n.grants.values) {
          if (g['shareId'] != key) continue;
          if (g['email'] != who.email) return error(403, 'accessDenied');
          if (share.group(2) == 'permission') return send(200, {'roles': g['roles']});
          return send(200, {
            'id': n.id,
            'name': n.name,
            'folder': {},
            'parentReference': {'driveId': n.drive},
            'createdBy': {'user': {'displayName': users.values.firstWhere((u) => 'd-${u.user}' == n.drive).name}},
          });
        }
      }
      return error(404, 'itemNotFound');
    }

    final m = RegExp(r'^(/v1\.0/(?:me/drive/special/approot|me/drive/items/[^/:]+|drives/[^/:]+/items/[^/:]+))(?::(/[^:]*))?(?::?(/.*))?$').firstMatch(path);
    if (m == null) return error(404, 'notFound');
    final prefix = m.group(1)!, rel = m.group(2) ?? '', tail = m.group(3) ?? '';
    _Node? base;
    if (prefix.endsWith('/approot')) {
      base = _make(drive, '/Apps/Notation', dir: true);
    } else {
      final id = prefix.split('/items/').last;
      base = _nodes[id];
      if (base == null) return error(404, 'itemNotFound');
      if (prefix.startsWith('/v1.0/me/drive/') && base.drive != drive) return error(404, 'itemNotFound');
      if (prefix.startsWith('/v1.0/drives/') && prefix.split('/')[3] != base.drive) return error(404, 'itemNotFound');
    }
    final targetPath = '${base.path}$rel';
    final target = _at(base.drive, targetPath);
    final write = req.method != 'GET';

    if (tail == '/content' && req.method == 'PUT') {
      // a small file goes up in one request
      if (!_may(who, target ?? base, write: true)) return error(403, 'accessDenied');
      final n = _make(base.drive, targetPath, dir: false)..bytes = body;
      return send(201, {'id': n.id});
    }
    if (tail == '/createUploadSession') {
      if (!_may(who, target ?? base, write: true)) return error(403, 'accessDenied');
      final t = 'U${_next++}';
      _uploads[t] = (drive: base.drive, path: targetPath, data: BytesBuilder());
      return send(200, {'uploadUrl': '$address/upload/$t'});
    }
    if (tail == '/invite' && req.method == 'POST') {
      if (base.drive != drive) return error(403, 'accessDenied');
      if (forbidInvite) return error(403, 'accessDenied', 'Sharing is turned off');
      if (base.path == '' || base.path == '/Apps') return error(400, 'invalidRequest', 'Permissions cannot be created on the root');
      final j = jsonDecode(utf8.decode(body)) as Map;
      final email = ((j['recipients'] as List).first as Map)['email'] as String;
      final pid = 'P${_next++}';
      final g = {'email': email, 'roles': j['roles'], 'shareId': 'SH${_next++}'};
      base.grants[pid] = g;
      return send(200, {
        'value': [
          {
            'id': pid,
            'roles': g['roles'],
            'invitation': {'email': email, 'signInRequired': true},
            'grantedToV2': {'user': {'displayName': users.values.where((u) => u.email == email).firstOrNull?.name ?? email, 'email': email}},
            if (tellsShareId) 'shareId': g['shareId'],
          },
        ],
      });
    }
    if (tail.startsWith('/permissions')) {
      if (base.drive != drive) return error(403, 'accessDenied');
      final pid = tail.length > '/permissions/'.length ? tail.substring('/permissions/'.length) : null;
      if (pid == null) {
        return send(200, {
          'value': [
            {'id': 'owner', 'roles': ['owner'], 'grantedToV2': {'user': {'displayName': who.name}}},
            for (final e in base.grants.entries)
              {
                'id': e.key,
                'roles': e.value['roles'],
                'invitation': {'email': e.value['email']},
                'grantedToV2': {'user': {'displayName': users.values.where((u) => u.email == e.value['email']).firstOrNull?.name ?? e.value['email'], 'email': e.value['email']}},
              },
          ],
        });
      }
      if (!base.grants.containsKey(pid)) return error(404, 'itemNotFound');
      if (req.method == 'DELETE') {
        base.grants.remove(pid);
        return send(204);
      }
      if (req.method == 'PATCH') {
        base.grants[pid]!['roles'] = (jsonDecode(utf8.decode(body)) as Map)['roles'];
        return send(200, {'id': pid});
      }
    }

    if (target == null && !(req.method == 'GET' && tail == '/children')) return error(404, 'itemNotFound');
    if (target != null && !_may(who, target, write: write)) return error(403, 'accessDenied');
    if (tail == '/children') {
      if (target == null || !target.isDir) return error(404, 'itemNotFound');
      final prefixPath = '${target.path}/';
      return send(200, {
        'value': [
          for (final n in _nodes.values)
            if (n.drive == target.drive && n.path.startsWith(prefixPath) && !n.path.substring(prefixPath.length).contains('/'))
              {'name': n.name, if (n.isDir) 'folder': {} else 'file': {}},
        ],
      });
    }
    if (tail == '/content') {
      if (target!.isDir || target.bytes == null) return error(404, 'itemNotFound');
      req.response
        ..statusCode = 302
        ..headers.set('location', '$address/dl/${target.id}');
      return req.response.close();
    }
    if (tail.isEmpty && req.method == 'DELETE') {
      _remove(target!);
      return send(204);
    }
    if (tail.isEmpty && req.method == 'GET') {
      return send(200, {'id': target!.id, 'name': target.name, 'webUrl': 'https://onedrive.live.com/redir?id=${target.id}', 'parentReference': {'driveId': target.drive}});
    }
    send(404);
  }
}
