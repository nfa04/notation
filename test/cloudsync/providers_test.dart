import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_folder.dart';
import 'package:notes/collab/dropbox_storage.dart';
import 'package:notes/collab/nextcloud_storage.dart';
import 'package:notes/collab/onedrive_storage.dart';
import 'package:notes/collab/s3_storage.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/sync/caldav_service.dart';

import '../collab/fake_nextcloud.dart';

class _Secret implements SecretStore {
  String? value;
  _Secret([this.value]);
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

Uint8List bytes(List<int> l) => Uint8List.fromList(l);

/// What every cloud folder has to do, whatever the service.
Future<void> contract(CloudFolder f) async {
  expect(await f.read('n/missing'), isNull);
  expect(await f.list('n'), isEmpty);
  await f.write('n/one.bin', bytes([1, 2, 3]));
  await f.write('n/two file.bin', bytes([4, 5]));
  await f.write('f/pic', bytes(List.generate(200000, (i) => i % 251)));
  expect(await f.read('n/one.bin'), bytes([1, 2, 3]));
  expect(await f.read('f/pic'), bytes(List.generate(200000, (i) => i % 251)));
  expect((await f.list('n')).toSet(), {'one.bin', 'two file.bin'});
  expect(await f.list('f'), ['pic']);
  await f.write('n/one.bin', bytes([9])); // replaced
  expect(await f.read('n/one.bin'), bytes([9]));
  await f.delete('n/one.bin');
  expect(await f.read('n/one.bin'), isNull);
  await f.delete('n/one.bin'); // not there: nothing happens
  expect(await f.list('n'), ['two file.bin']);
}

/// Dropbox and OneDrive, as far as the sync uses them.
class _FakeDrive {
  late HttpServer server;
  final files = <String, Uint8List>{};
  String address = '';
  final _uploads = <String, String>{};
  final _pending = <String, BytesBuilder>{};

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    address = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      try {
        await _handle(req);
      } catch (e, st) {
        // ignore: avoid_print
        print('FAKE DRIVE: $e\n$st');
        rethrow;
      }
    });
  }

  Future<void> _handle(HttpRequest req) async {
    {
      final body = Uint8List.fromList(await req.fold<List<int>>([], (a, b) => a..addAll(b)));
      void json(int code, Object data) {
        req.response
          ..statusCode = code
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(data));
        req.response.close();
      }

      final path = Uri.decodeFull(req.uri.path);
      if (req.headers.value('authorization') != 'Bearer AT' && !path.startsWith('/dl/') && !path.startsWith('/upload/')) return json(401, {'error_summary': 'expired_access_token'});

      // ---- Dropbox
      List<String> childrenOf(String dir) => [
            for (final p in files.keys)
              if (p.startsWith('$dir/') && !p.substring(dir.length + 1).contains('/')) p.substring(dir.length + 1),
          ];
      if (path == '/2/files/list_folder') {
        final arg = jsonDecode(utf8.decode(body)) as Map;
        final names = childrenOf(arg['path'] as String);
        if (names.isEmpty) return json(409, {'error_summary': 'path/not_found/..'});
        return json(200, {
          'entries': [for (final n in names.take(1)) {'.tag': 'file', 'name': n}],
          'has_more': names.length > 1,
          'cursor': '${arg['path']}|1',
        });
      }
      if (path == '/2/files/list_folder/continue') {
        final cursor = ((jsonDecode(utf8.decode(body)) as Map)['cursor'] as String).split('|');
        final names = childrenOf(cursor[0]).skip(int.parse(cursor[1])).toList();
        return json(200, {
          'entries': [for (final n in names.take(1)) {'.tag': 'file', 'name': n}],
          'has_more': names.length > 1,
          'cursor': '${cursor[0]}|${int.parse(cursor[1]) + 1}',
        });
      }
      if (path == '/2/files/download') {
        final f = files[(jsonDecode(req.headers.value('dropbox-api-arg')!) as Map)['path']];
        if (f == null) return json(409, {'error_summary': 'path/not_found/'});
        req.response
          ..statusCode = 200
          ..add(f);
        return req.response.close();
      }
      if (path == '/2/files/upload') {
        files[(jsonDecode(req.headers.value('dropbox-api-arg')!) as Map)['path'] as String] = body;
        return json(200, {});
      }
      if (path == '/2/files/delete_v2') {
        final p = (jsonDecode(utf8.decode(body)) as Map)['path'] as String;
        return files.remove(p) == null ? json(409, {'error_summary': 'path_lookup/not_found/'}) : json(200, {});
      }

      // ---- OneDrive
      const root = '/v1.0/me/drive/special/approot:';
      if (path.startsWith(root)) {
        final rest = path.substring(root.length);
        if (req.method == 'GET' && rest.endsWith(':/children')) {
          final dir = rest.substring(0, rest.length - ':/children'.length);
          final skip = int.tryParse(req.uri.queryParameters['skip'] ?? '') ?? 0;
          final names = childrenOf(dir).skip(skip).toList();
          if (childrenOf(dir).isEmpty) return json(404, {'error': {'code': 'itemNotFound'}});
          return json(200, {
            'value': [for (final n in names.take(1)) {'name': n, 'file': {}}],
            if (names.length > 1) '@odata.nextLink': '$address$root${Uri.encodeFull(dir)}:/children?skip=${skip + 1}',
          });
        }
        if (req.method == 'GET' && rest.endsWith(':/content')) {
          final p = rest.substring(0, rest.length - ':/content'.length);
          if (files[p] == null) return json(404, {});
          req.response
            ..statusCode = 302
            ..headers.set('location', '$address/dl${Uri.encodeFull(p)}');
          return req.response.close();
        }
        if (req.method == 'PUT' && rest.endsWith(':/content')) {
          // a small file goes up in one request
          files[rest.substring(0, rest.length - ':/content'.length)] = body;
          return json(201, {'id': 'ITEM-simple'});
        }
        if (req.method == 'POST' && rest.endsWith(':/createUploadSession')) {
          final p = rest.substring(0, rest.length - ':/createUploadSession'.length);
          final id = '${_uploads.length + 1}';
          _uploads[id] = p;
          _pending[id] = BytesBuilder();
          return json(200, {'uploadUrl': '$address/upload/$id'});
        }
        if (req.method == 'DELETE') {
          return files.remove(rest) == null ? json(404, {}) : (req.response..statusCode = 204).close();
        }
      }
      if (path.startsWith('/dl/')) {
        final f = files[path.substring('/dl'.length)];
        if (f == null) return json(404, {});
        if (req.headers.value('authorization') != null) return json(400, {'error': 'the sign-in was passed on'});
        req.response
          ..statusCode = 200
          ..add(f);
        return req.response.close();
      }
      if (path.startsWith('/upload/')) {
        final id = path.substring('/upload/'.length);
        _pending[id]!.add(body);
        final m = RegExp(r'bytes (\d+)-(\d+)/(\d+)').firstMatch(req.headers.value('content-range')!)!;
        if (int.parse(m.group(2)!) + 1 < int.parse(m.group(3)!)) return json(202, {});
        files[_uploads[id]!] = _pending[id]!.toBytes();
        return json(201, {'id': 'ITEM$id'});
      }
      json(404, {});
    }
  }

  Future<void> stop() => server.close(force: true);
}

/// An S3 that checks signatures, with listing.
class _FakeS3 {
  late HttpServer server;
  final objects = <String, Uint8List>{};
  final signer = const SigV4(accessKey: 'AKID', secretKey: 'topsecret', region: 'auto');
  int rejected = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = Uint8List.fromList(await req.fold<List<int>>([], (a, b) => a..addAll(b)));
      final host = '127.0.0.1:${server.port}';
      void reply(int code, [String text = '']) {
        req.response
          ..statusCode = code
          ..write(text);
        req.response.close();
      }

      final auth = req.headers.value('authorization') ?? '';
      final hash = req.headers.value('x-amz-content-sha256') ?? '';
      final signed = RegExp(r'SignedHeaders=([^,]+)').firstMatch(auth)?.group(1)?.split(';') ?? const <String>[];
      final headers = {for (final h in signed) h: h == 'host' ? host : req.headers.value(h) ?? ''};
      final time = req.headers.value('x-amz-date') ?? '20200101T000000Z';
      final when = DateTime.parse('${time.substring(0, 4)}-${time.substring(4, 6)}-${time.substring(6, 8)}T${time.substring(9, 11)}:${time.substring(11, 13)}:${time.substring(13, 15)}Z');
      final expected = signer.sign(method: req.method, path: req.uri.path, headers: headers, payloadHash: hash, now: when, query: req.uri.queryParameters);
      if (expected['Authorization'] != auth || hash != SigV4.sha256Hex(body)) {
        rejected++;
        return reply(403, '<Error><Code>SignatureDoesNotMatch</Code></Error>');
      }
      if (!req.uri.path.startsWith('/bucket')) return reply(404, '<Error><Code>NoSuchBucket</Code></Error>');
      if (req.method == 'GET' && req.uri.queryParameters['list-type'] == '2') {
        final prefix = req.uri.queryParameters['prefix'] ?? '';
        final token = int.tryParse(req.uri.queryParameters['continuation-token'] ?? '') ?? 0;
        final keys = [for (final k in objects.keys) if (k.startsWith(prefix) && !k.substring(prefix.length).contains('/')) k]..sort();
        final page = keys.skip(token).take(2).toList();
        final more = keys.length > token + 2;
        return reply(200, '<ListBucketResult>${[for (final k in page) '<Contents><Key>${k.replaceAll('&', '&amp;')}</Key></Contents>'].join()}<IsTruncated>$more</IsTruncated>${more ? '<NextContinuationToken>${token + 2}</NextContinuationToken>' : ''}</ListBucketResult>');
      }
      final key = Uri.decodeFull(req.uri.path.substring('/bucket/'.length));
      switch (req.method) {
        case 'PUT':
          objects[key] = body;
          return reply(200);
        case 'GET':
          final o = objects[key];
          if (o == null) return reply(404, '<Error><Code>NoSuchKey</Code></Error>');
          req.response
            ..statusCode = 200
            ..add(o);
          return req.response.close();
        case 'DELETE':
          objects.remove(key);
          return reply(204);
      }
      reply(404);
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('providers_'));
  tearDown(() => dir.delete(recursive: true));

  const signedIn = '{"access":"AT","refresh":"RT","expires":9999999999999}';

  test('Nextcloud (WebDAV)', () async {
    final nextcloud = FakeNextcloud();
    await nextcloud.start();
    addTearDown(nextcloud.stop);
    final db = await AppDatabase.open(path: '${dir.path}/n.db');
    addTearDown(db.close);
    final caldav = CalDavService(SettingsRepository(db), TaskRepository(db), secret: _Secret());
    await caldav.save('${nextcloud.address}/remote.php/dav', 'alice', 'app-pw', taskCalendar: null, eventCalendars: {});
    final folder = NextcloudStorage(caldav).folderFor('Notation Sync');
    await contract(folder);
    // the wrong password is told
    nextcloud.password = 'changed';
    await expectLater(folder.read('n/x'), throwsA(isA<CloudFolderException>()));
  });

  test('Nextcloud: files written at once into a directory that is not there yet wait for it, which is made once', () async {
    final nextcloud = FakeNextcloud()
      ..strictParents = true
      ..mkcolDelay = const Duration(milliseconds: 80);
    await nextcloud.start();
    addTearDown(nextcloud.stop);
    final db = await AppDatabase.open(path: '${dir.path}/n2.db');
    addTearDown(db.close);
    final caldav = CalDavService(SettingsRepository(db), TaskRepository(db), secret: _Secret());
    await caldav.save('${nextcloud.address}/remote.php/dav', 'alice', 'app-pw', taskCalendar: null, eventCalendars: {});
    final folder = NextcloudStorage(caldav).folderFor('Notation Sync');
    await Future.wait([for (var i = 0; i < 6; i++) folder.write('dev/n/file$i', Uint8List.fromList([i]))]);
    expect([for (var i = 0; i < 6; i++) (await folder.read('dev/n/file$i'))!.single], [0, 1, 2, 3, 4, 5]);
    expect(nextcloud.mkcolRequests, ['/Notation Sync', '/Notation Sync/dev', '/Notation Sync/dev/n'], reason: 'each directory once');
  });

  test('S3: signed requests, and the listing is signed with its query', () async {
    final s3 = _FakeS3();
    await s3.start();
    addTearDown(s3.stop);
    final db = await AppDatabase.open(path: '${dir.path}/s.db');
    addTearDown(db.close);
    final storage = S3Storage(SettingsRepository(db), secret: _Secret());
    await storage.save(S3Config(endpoint: 'http://127.0.0.1:${s3.server.port}', region: 'auto', bucket: 'bucket', accessKey: 'AKID'), 'topsecret');
    final folder = storage.folderFor('Notation Sync');
    await contract(folder);
    expect(s3.rejected, 0);
    expect(s3.objects.keys.every((k) => k.startsWith('Notation Sync/')), isTrue);
  });

  test('Dropbox', () async {
    final drive = _FakeDrive();
    await drive.start();
    addTearDown(drive.stop);
    final storage = DropboxStorage(appKey: 'k', store: _Secret(signedIn), apiHost: drive.address, contentHost: drive.address);
    await storage.load();
    await contract(storage.folderFor('Notation Sync'));
    expect(drive.files.keys.every((k) => k.startsWith('/Notation Sync/')), isTrue);
  });

  test('OneDrive: the file is fetched without passing the sign-in on to where the redirect leads', () async {
    final drive = _FakeDrive();
    await drive.start();
    addTearDown(drive.stop);
    final storage = OneDriveStorage(clientId: 'c', store: _Secret(signedIn), graphHost: drive.address, sharesHost: drive.address);
    await storage.load();
    await contract(storage.folderFor('Notation Sync'));
    expect(drive.files.keys.every((k) => k.startsWith('/Notation Sync/')), isTrue);
  });

  test('the Dropbox header holds ASCII only: a folder with umlauts or an emoji is written as escapes that decode to the same path', () {
    final arg = dropboxArg({'path': '/Notizen für Uni 😀/d-1/m', 'mode': 'overwrite'});
    expect(arg.codeUnits.every((u) => u < 0x7f), isTrue);
    expect(jsonDecode(arg), {'path': '/Notizen für Uni 😀/d-1/m', 'mode': 'overwrite'});
  });
}
