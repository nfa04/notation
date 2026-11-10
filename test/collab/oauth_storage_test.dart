import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/dropbox_storage.dart';
import 'package:notes/collab/oauth.dart';
import 'package:notes/collab/onedrive_storage.dart';
import 'package:notes/collab/share_storage.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/sync/caldav_service.dart';

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

/// A small stand-in for the sign-in and file APIs of Dropbox and OneDrive.
class _Fake {
  late HttpServer server;
  String? challenge;
  int tokenCalls = 0, refreshCalls = 0;
  String access = 'AT1';
  final files = <String, Uint8List>{};
  final deleted = <String>[];
  final uploadParts = <String>[];
  final _upload = BytesBuilder();
  String address = '';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    address = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = Uint8List.fromList(await req.fold<List<int>>([], (a, b) => a..addAll(b)));
      void json(int code, Object data) {
        req.response
          ..statusCode = code
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(data));
        req.response.close();
      }

      final path = req.uri.path;
      bool authed() => req.headers.value('authorization') == 'Bearer $access';

      if (path == '/oauth2/token' || path == '/token') {
        final form = Uri.splitQueryString(utf8.decode(body));
        if (form['grant_type'] == 'authorization_code') {
          tokenCalls++;
          final verifierHash = base64Url.encode(sha256.convert(utf8.encode(form['code_verifier']!)).bytes).replaceAll('=', '');
          if (form['code'] != 'GOODCODE' || verifierHash != challenge) return json(400, {'error': 'invalid_grant', 'error_description': 'bad code'});
          return json(200, {'access_token': 'AT1', 'refresh_token': 'RT1', 'expires_in': 3600});
        }
        refreshCalls++;
        if (form['refresh_token'] != 'RT1') return json(400, {'error': 'invalid_grant'});
        access = 'AT2';
        return json(200, {'access_token': 'AT2', 'expires_in': 3600});
      }

      // Dropbox
      if (path == '/2/files/upload') {
        if (!authed()) return json(401, {'error_summary': 'expired_access_token'});
        final arg = jsonDecode(req.headers.value('dropbox-api-arg')!) as Map;
        files[arg['path'] as String] = body;
        return json(200, {'path_display': arg['path']});
      }
      if (path == '/2/sharing/create_shared_link_with_settings') {
        final arg = jsonDecode(utf8.decode(body)) as Map;
        return json(200, {'url': '$address/scl/fi/abc${arg['path']}?rlkey=k&dl=0'});
      }
      if (path == '/2/files/delete_v2') {
        final arg = jsonDecode(utf8.decode(body)) as Map;
        deleted.add(arg['path'] as String);
        return files.remove(arg['path']) == null ? json(409, {'error_summary': 'path_lookup/not_found'}) : json(200, {});
      }
      if (path.startsWith('/scl/fi/')) {
        final file = files[path.substring('/scl/fi/abc'.length)];
        if (file == null || req.uri.queryParameters['dl'] != '1') return json(404, {});
        req.response
          ..statusCode = 200
          ..add(file);
        return req.response.close();
      }

      // OneDrive
      if (path.contains('/createUploadSession')) {
        if (!authed()) return json(401, {'error': {'code': 'InvalidAuthenticationToken'}});
        _upload.clear();
        return json(200, {'uploadUrl': '$address/upload/1'});
      }
      if (path == '/upload/1') {
        uploadParts.add(req.headers.value('content-range')!);
        _upload.add(body);
        final m = RegExp(r'bytes (\d+)-(\d+)/(\d+)').firstMatch(req.headers.value('content-range')!)!;
        if (int.parse(m.group(2)!) + 1 < int.parse(m.group(3)!)) return json(202, {});
        files['ITEM1'] = _upload.toBytes();
        return json(201, {'id': 'ITEM1'});
      }
      if (path.endsWith('/createLink')) return json(200, {'link': {'webUrl': 'https://1drv.ms/u/s!abc'}});
      if (req.method == 'DELETE' && path.startsWith('/v1.0/me/drive/items/')) {
        deleted.add(path.split('/').last);
        files.remove(path.split('/').last);
        req.response.statusCode = 204;
        return req.response.close();
      }
      if (path.startsWith('/v1.0/shares/u!') && path.endsWith('/root/content')) {
        final url = utf8.decode(base64Url.decode(base64Url.normalize(path.split('/')[3].substring(2))));
        if (url != 'https://1drv.ms/u/s!abc' || files['ITEM1'] == null) return json(404, {});
        req.response
          ..statusCode = 200
          ..add(files['ITEM1']!);
        return req.response.close();
      }
      json(404, {});
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late _Fake fake;
  late Directory dir;
  late SettingsRepository settings;
  late _Secret tokens;
  var clock = DateTime.utc(2026, 5, 1);

  setUp(() async {
    clock = DateTime.utc(2026, 5, 1);
    fake = _Fake();
    await fake.start();
    dir = await Directory.systemTemp.createTemp('oauth_');
    settings = SettingsRepository(await AppDatabase.open(path: '${dir.path}/s.db'));
    tokens = _Secret();
  });
  tearDown(() async {
    await fake.stop();
    await dir.delete(recursive: true);
  });

  DropboxStorage dropbox() => DropboxStorage(
        appKey: 'APPKEY',
        settings: settings,
        store: tokens,
        now: () => clock,
        apiHost: fake.address,
        contentHost: fake.address,
      );

  /// Begins a sign-in and returns what the browser would send the person back with.
  Future<Uri> signInAddress(OAuthShareStorage s, {String code = 'GOODCODE', String? state}) async {
    final page = await s.beginSignIn();
    fake.challenge = page.queryParameters['code_challenge'];
    return Uri.parse('notation://oauth/${s.redirectName}?code=$code&state=${state ?? page.queryParameters['state']}');
  }

  group('signing in', () {
    test('the sign-in page asks for the app folder only, with a challenge and no secret', () async {
      final s = dropbox();
      final page = await s.beginSignIn();
      expect(page.host, 'www.dropbox.com');
      expect(page.queryParameters['client_id'], 'APPKEY');
      expect(page.queryParameters['response_type'], 'code');
      expect(page.queryParameters['code_challenge_method'], 'S256');
      expect(page.queryParameters['redirect_uri'], 'notation://oauth/dropbox');
      expect(page.queryParameters['scope'], 'files.content.write files.content.read files.metadata.read sharing.write');
      expect(page.queryParameters['token_access_type'], 'offline');
      expect(page.toString(), isNot(contains('code_verifier')));
      expect(s.available, isFalse);
      expect(s.unavailableReason, contains('Sign in to Dropbox'));
    });

    test('coming back with the code signs in, and the tokens are kept for the next start', () async {
      final s = dropbox();
      expect(await s.handleRedirect(await signInAddress(s)), isTrue);
      expect(s.signInProblem, isNull);
      expect(s.available, isTrue);
      expect(tokens.value, contains('RT1'));

      final next = dropbox();
      await next.load();
      expect(next.available, isTrue);
      await next.signOut();
      expect(next.available, isFalse);
      expect(tokens.value, isNull);
    });

    test('an answer to some other sign-in, a refusal and a wrong code are told apart and sign nobody in', () async {
      final s = dropbox();
      expect(await s.handleRedirect(Uri.parse('notation://oauth/onedrive?code=x&state=y')), isFalse, reason: 'not for this service');
      expect(await s.handleRedirect(Uri.parse('notation://join?s=x')), isFalse);

      expect(await s.handleRedirect(await signInAddress(s, state: 'forged')), isTrue);
      expect(s.signInProblem, contains('not started here'));
      expect(s.available, isFalse);

      final page = await s.beginSignIn();
      expect(await s.handleRedirect(Uri.parse('notation://oauth/dropbox?error=access_denied&state=${page.queryParameters['state']}')), isTrue);
      expect(s.signInProblem, contains('access_denied'));

      expect(await s.handleRedirect(await signInAddress(s, code: 'WRONG')), isTrue);
      expect(s.signInProblem, contains('bad code'));
      expect(s.available, isFalse);
    });
  });

  group('Dropbox', () {
    test('a copy goes into the app folder and the link is a direct download', () async {
      final s = dropbox();
      await s.handleRedirect(await signInAddress(s));
      final sealed = Uint8List.fromList(List.generate(500, (i) => i % 256));
      final url = await s.upload(sealed);
      expect(fake.files.keys.single, matches(RegExp(r'^/shared/[0-9a-f]{24}\.uninote\.enc$')));
      expect(url.queryParameters['dl'], '1');
      expect(url.queryParameters['rlkey'], 'k');
      expect(await downloadShared(url, allowInsecure: true), sealed);
      expect(s.keeps.inDays, 30);
    });

    test('the sign-in is renewed when it has run out, and copies past 30 days are deleted at the next share', () async {
      final s = dropbox();
      await s.handleRedirect(await signInAddress(s));
      await s.upload(Uint8List(5));
      final first = fake.files.keys.single;
      clock = clock.add(const Duration(hours: 2)); // the token is old now
      fake.access = 'AT2';
      await s.upload(Uint8List(5));
      expect(fake.refreshCalls, 1);
      expect(fake.files, hasLength(2));
      clock = clock.add(const Duration(days: 31));
      await s.upload(Uint8List(5));
      expect(fake.deleted, contains(first));
      expect(fake.files.containsKey(first), isFalse);
    });

    test('a stored file can be replaced', () async {
      final s = dropbox();
      await s.handleRedirect(await signInAddress(s));
      final f = await s.store(Uint8List.fromList([1, 2]));
      await s.replace(f.ref, Uint8List.fromList([7, 7, 7]));
      expect(fake.files[f.ref], [7, 7, 7]);
    });

    test('not signed in, the person is told', () async {
      await expectLater(dropbox().upload(Uint8List(1)), throwsA(predicate((e) => '$e'.contains('Not signed in'))));
    });
  });

  group('OneDrive', () {
    OneDriveStorage drive() => OneDriveStorage(
          clientId: 'CLIENT',
          settings: settings,
          store: tokens,
          now: () => clock,
          tokenUrl: '${fake.address}/token',
          graphHost: fake.address,
          sharesHost: fake.address,
        );

    test('a big copy goes up in parts, the link is made, and it is fetched without a sign-in through the shares address', () async {
      final s = drive();
      expect((await s.beginSignIn()).queryParameters['scope'], 'Files.ReadWrite.AppFolder offline_access');
      await s.handleRedirect(await signInAddress(s));
      expect(s.available, isTrue);

      final rnd = List.generate(4 * 1024 * 1024, (i) => (i * 31 + 7) % 256);
      final sealed = Uint8List.fromList(rnd);
      final url = await s.upload(sealed);
      expect(fake.uploadParts, hasLength(2), reason: 'parts of 3.2 MB');
      expect(fake.uploadParts.first, startsWith('bytes 0-3276799/'));
      expect(url.toString(), 'https://1drv.ms/u/s!abc');

      expect(s.handles(url), isTrue);
      expect(s.handles(Uri.parse('https://cloud.example.org/s/abc')), isFalse);
      expect(await s.fetch(url), sealed);
      expect(s.downloadAddress(url).path, startsWith('/v1.0/shares/u!'));
    });

    test('a stored file can be replaced', () async {
      final s = drive();
      await s.handleRedirect(await signInAddress(s));
      final f = await s.store(Uint8List.fromList([1, 2]));
      await s.replace(f.ref, Uint8List.fromList([5, 5, 5]));
      expect(fake.files['ITEM1'], [5, 5, 5]);
    });

    test('copies past 30 days are deleted at the next share', () async {
      final s = drive();
      await s.handleRedirect(await signInAddress(s));
      await s.upload(Uint8List(100));
      expect(fake.files.keys, ['ITEM1']);
      clock = clock.add(const Duration(days: 31));
      fake.access = 'AT1';
      await s.upload(Uint8List(100)); // (the token had run out: renewed)
      expect(fake.deleted, ['ITEM1']);
    });
  });

  test('every service can say what it is, through the one interface', () {
    final all = <ShareStorage>[dropbox()];
    expect(all.single.label, 'Dropbox');
    expect(all.single.handles(Uri.parse('https://www.dropbox.com/scl/fi/x')), isFalse, reason: 'its links are plain downloads');
  });
}
