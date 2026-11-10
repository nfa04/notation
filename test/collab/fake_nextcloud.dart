import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Enough of a Nextcloud for sharing: WebDAV folder and file, the sharing API, and the public download.
class FakeNextcloud {
  /// The directories asked for, in order, the ones that exist, and how slow making one is. With [strictParents] a file cannot be put in a
  /// directory that was not made (as on a real server).
  final List<String> mkcolRequests = [];
  final Set<String> madeDirs = {};
  Duration mkcolDelay = Duration.zero;
  bool strictParents = false;

  late HttpServer server;
  final files = <String, Uint8List>{};
  final shares = <String, String>{}; // token -> path
  final folders = <String>{};
  final shareRights = <String, int>{};
  final dropped = <String>[]; // names that guests left
  String user = 'alice', password = 'app-pw';
  bool linkSharing = true;

  /// While true every request fails, as when there is no network.
  bool down = false;
  int mkcols = 0;
  final deletes = <String>[];
  String? lastExpire;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = Uri.decodeFull(req.uri.path);
      final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      bool authed() => req.headers.value('authorization') == 'Basic ${base64Encode(utf8.encode('$user:$password'))}';
      void reply(int code, [String body = '', String type = 'text/plain']) {
        req.response
          ..statusCode = code
          ..headers.contentType = ContentType.parse(type)
          ..write(body);
        req.response.close();
      }

      if (down) return reply(503, 'no network');

      if (path.startsWith('/s/') && path.endsWith('/download')) {
        final token = path.split('/')[2];
        final file = shares[token];
        if (file == null || files[file] == null) return reply(404);
        req.response
          ..statusCode = 200
          ..add(files[file]!);
        return req.response.close();
      }
      // a guest leaving a file in a shared folder ("file drop"): the token is the user name, no password
      if (path.startsWith('/public.php/webdav/')) {
        final auth = req.headers.value('authorization') ?? '';
        final token = utf8.decode(base64Decode(auth.replaceFirst('Basic ', ''))).split(':').first;
        final folder = shares[token];
        if (folder == null || shareRights[token] != 4 || !folders.contains(folder)) return reply(401);
        if (req.method != 'PUT') return reply(403); // (create only: no reading, no changing)
        var name = path.substring('/public.php/webdav/'.length);
        var target = '$folder/$name';
        for (var n = 2; files.containsKey(target); n++) {
          target = '$folder/$name ($n)'; // a file drop does not replace what is there
        }
        files[target] = Uint8List.fromList(bytes);
        dropped.add(name);
        return reply(201);
      }
      if (!authed()) return reply(401);
      final base = '/remote.php/dav/files/$user/';
      if (req.method == 'MKCOL' && path.startsWith(base)) {
        final folder = '/${path.substring(base.length)}';
        mkcolRequests.add(folder);
        if (mkcolDelay > Duration.zero) await Future<void>.delayed(mkcolDelay);
        madeDirs.add(folder);
        final isRoot = !folder.substring(1).contains('/');
        if (isRoot) return reply(mkcols++ == 0 ? 201 : 405);
        folders.add(folder);
        return reply(201);
      }
      if (req.method == 'PROPFIND' && path.startsWith(base)) {
        final folder = '/${path.substring(base.length)}';
        if (!folders.contains(folder)) return reply(404);
        final entries = ['$folder/', ...files.keys.where((k) => k.startsWith('$folder/'))];
        final xml = '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${[for (final e in entries) '<d:response><d:href>/remote.php/dav/files/$user${Uri.encodeFull(e)}</d:href></d:response>'].join()}</d:multistatus>';
        return reply(207, xml, 'application/xml');
      }
      if (req.method == 'GET' && path.startsWith(base)) {
        final f = files['/${path.substring(base.length)}'];
        if (f == null) return reply(404);
        req.response
          ..statusCode = 200
          ..add(f);
        return req.response.close();
      }
      if (req.method == 'DELETE' && path.startsWith(base)) {
        deletes.add(path.substring(base.length - 1));
        return reply(files.remove(path.substring(base.length - 1)) == null ? 404 : 204);
      }
      if (req.method == 'PUT' && path.startsWith(base)) {
        final file = path.substring(base.length - 1);
        if (strictParents && file.lastIndexOf('/') > 0 && !madeDirs.contains(file.substring(0, file.lastIndexOf('/')))) return reply(409);
        files[file] = Uint8List.fromList(bytes);
        return reply(201);
      }
      if (req.method == 'POST' && path == '/ocs/v2.php/apps/files_sharing/api/v1/shares') {
        if (!linkSharing) return reply(403, jsonEncode({'ocs': {'meta': {'statuscode': 403}, 'data': []}}), 'application/json');
        final form = Uri.splitQueryString(utf8.decode(bytes));
        lastExpire = form['expireDate'];
        final rights = int.tryParse(form['permissions'] ?? '') ?? 0;
        final isFolder = folders.contains(form['path']);
        if (form['shareType'] != '3' || !((rights == 1 && files.containsKey(form['path'])) || (rights == 4 && isFolder))) return reply(404);
        final token = 'tok${shares.length + 1}abc';
        shares[token] = form['path']!;
        shareRights[token] = rights;
        return reply(200, jsonEncode({'ocs': {'meta': {'statuscode': 200}, 'data': {'token': token}}}), 'application/json');
      }
      reply(404);
    });
  }

  /// The path of the file a public link downloads.
  String? pathOf(Uri link) => shares[link.pathSegments[1]];

  Future<void> stop() => server.close(force: true);
  String get address => 'http://127.0.0.1:${server.port}';
}

