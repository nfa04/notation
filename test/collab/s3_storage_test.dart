import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/s3_storage.dart';
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

/// An S3 that checks signatures: PUT and DELETE with signed headers, GET with a signed address.
class _FakeS3 {
  late HttpServer server;
  final objects = <String, Uint8List>{};
  final signer = const SigV4(accessKey: 'AKID', secretKey: 'topsecret', region: 'auto');
  DateTime now;
  int rejected = 0;

  _FakeS3(this.now);

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

      void deny(String code) {
        rejected++;
        reply(403, '<Error><Code>$code</Code></Error>');
      }

      final path = req.uri.path; // already encoded on the wire
      if (!path.startsWith('/bucket/')) return reply(404, '<Error><Code>NoSuchBucket</Code></Error>');
      final key = Uri.decodeFull(path.substring('/bucket/'.length));

      if (req.method == 'GET') {
        // an address signed for host only
        final q = req.uri.queryParameters;
        final signature = q['X-Amz-Signature'];
        final time = DateTime.parse('${q['X-Amz-Date']!.substring(0, 4)}-${q['X-Amz-Date']!.substring(4, 6)}-${q['X-Amz-Date']!.substring(6, 8)}T${q['X-Amz-Date']!.substring(9, 11)}:${q['X-Amz-Date']!.substring(11, 13)}:${q['X-Amz-Date']!.substring(13, 15)}Z');
        final expected = signer.presignedQuery(method: 'GET', host: host, path: path, expires: Duration(seconds: int.parse(q['X-Amz-Expires']!)), now: time);
        if (signature != expected['X-Amz-Signature']) return deny('SignatureDoesNotMatch');
        if (now.isAfter(time.add(Duration(seconds: int.parse(q['X-Amz-Expires']!))))) return deny('AccessDenied');
        final o = objects[key];
        if (o == null) return reply(404);
        req.response
          ..statusCode = 200
          ..add(o);
        return req.response.close();
      }

      final auth = req.headers.value('authorization') ?? '';
      if (!auth.contains('Credential=AKID/')) return deny('InvalidAccessKeyId');
      final hash = req.headers.value('x-amz-content-sha256')!;
      if (hash != SigV4.sha256Hex(body)) return deny('XAmzContentSHA256Mismatch');
      final signed = RegExp(r'SignedHeaders=([^,]+)').firstMatch(auth)!.group(1)!.split(';');
      final headers = {for (final h in signed) h: h == 'host' ? host : req.headers.value(h) ?? ''};
      final time = req.headers.value('x-amz-date')!;
      final when = DateTime.parse('${time.substring(0, 4)}-${time.substring(4, 6)}-${time.substring(6, 8)}T${time.substring(9, 11)}:${time.substring(11, 13)}:${time.substring(13, 15)}Z');
      final expected = signer.sign(method: req.method, path: path, headers: headers, payloadHash: hash, now: when);
      if (expected['Authorization'] != auth) return deny('SignatureDoesNotMatch');
      if (req.method == 'PUT') {
        objects[key] = body;
        return reply(200);
      }
      if (req.method == 'DELETE') {
        objects.remove(key);
        return reply(204);
      }
      reply(405);
    });
  }

  Future<void> stop() => server.close(force: true);
  String get address => 'http://127.0.0.1:${server.port}';
}

void main() {
  setUpAll(AppDatabase.initFfi);

  group('the signature', () {
    // the examples of the AWS documentation (Signature Version 4, "Examples")
    const signer = SigV4(accessKey: 'AKIAIOSFODNN7EXAMPLE', secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', region: 'us-east-1');
    final at = DateTime.utc(2013, 5, 24);

    test('a request signed in its headers', () {
      final h = signer.sign(
        method: 'GET',
        path: '/test.txt',
        headers: {'host': 'examplebucket.s3.amazonaws.com', 'Range': 'bytes=0-9'},
        payloadHash: SigV4.sha256Hex(const []),
        now: at,
      );
      expect(
        h['Authorization'],
        'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,'
        'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,'
        'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
      );
    });

    test('an address signed in its query', () {
      final q = signer.presignedQuery(method: 'GET', host: 'examplebucket.s3.amazonaws.com', path: '/test.txt', expires: const Duration(seconds: 86400), now: at);
      expect(q['X-Amz-Signature'], 'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
      expect(q['X-Amz-Credential'], 'AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request');
    });

    test('names are encoded as the signature wants', () {
      expect(SigV4.encode('a b/c~d_e-f.g'), 'a%20b%2Fc~d_e-f.g');
      expect(SigV4.encode('a b/c', keepSlash: true), 'a%20b/c');
      expect(SigV4.encode('ü'), '%C3%BC');
    });
  });

  group('S3 storage', () {
    late _FakeS3 s3;
    late S3Storage storage;
    late SettingsRepository settings;
    late _Secret secret;
    var clock = DateTime.utc(2026, 5, 1, 12);
    late Directory dir;

    S3Config config({String? endpoint, String bucket = 'bucket'}) => S3Config(endpoint: endpoint ?? s3.address, region: 'auto', bucket: bucket, accessKey: 'AKID');

    setUp(() async {
      clock = DateTime.utc(2026, 5, 1, 12);
      s3 = _FakeS3(clock);
      await s3.start();
      dir = await Directory.systemTemp.createTemp('s3_');
      settings = SettingsRepository(await AppDatabase.open(path: '${dir.path}/s.db'));
      secret = _Secret();
      storage = S3Storage(settings, secret: secret, now: () => clock);
    });
    tearDown(() async {
      await s3.stop();
      await dir.delete(recursive: true);
    });

    test('the account is checked by putting a file, downloading it through a signed link and removing it', () async {
      expect(await storage.check(config(), 'topsecret'), isNull);
      expect(s3.objects, isEmpty, reason: 'the test file is removed again');
      expect(await storage.check(config(), 'wrong'), contains('secret key'));
      expect(await storage.check(config(bucket: 'nobucket'), 'topsecret'), contains('no bucket'));
      expect(await storage.check(const S3Config(endpoint: '', region: 'auto', bucket: 'b', accessKey: 'k'), 's'), contains('Fill in'));
    });

    test('a copy goes up under a random name, and the link downloads it without keys for a week', () async {
      await storage.save(config(), 'topsecret');
      expect(storage.available, isTrue);
      final sealed = Uint8List.fromList(List.generate(300, (i) => i % 256));
      final url = await storage.upload(sealed);
      expect(s3.objects.keys.single, matches(RegExp(r'^shared/[0-9a-f]{24}\.uninote\.enc$')));
      expect(url.queryParameters['X-Amz-Expires'], '${7 * 24 * 3600}');
      expect(url.toString(), isNot(contains('topsecret')));

      final got = await HttpClient().getUrl(url).then((r) => r.close());
      expect(got.statusCode, 200);
      expect(await got.fold<List<int>>([], (a, b) => a..addAll(b)), sealed);

      // another address does not open the file
      final other = url.replace(queryParameters: {...url.queryParameters, 'X-Amz-Signature': '0' * 64});
      expect((await HttpClient().getUrl(other).then((r) => r.close())).statusCode, 403);
    });

    test('a stored file can be replaced under the same address', () async {
      await storage.save(config(), 'topsecret');
      final first = await storage.store(Uint8List.fromList([1, 2, 3]));
      await storage.replace(first.ref, Uint8List.fromList([9, 9]));
      expect(s3.objects[first.ref], [9, 9]);
      final got = await HttpClient().getUrl(first.url).then((r) => r.close());
      expect(await got.fold<List<int>>([], (a, b) => a..addAll(b)), [9, 9]);
    });

    test('copies past their time are removed from the bucket at the next share, and not before', () async {
      await storage.save(config(), 'topsecret');
      await storage.upload(Uint8List(10));
      clock = clock.add(const Duration(days: 3));
      await storage.upload(Uint8List(10));
      expect(s3.objects, hasLength(2));
      clock = clock.add(const Duration(days: 5)); // the first is 8 days old now
      await storage.upload(Uint8List(10));
      expect(s3.objects, hasLength(2), reason: 'the old one is gone, the new one came');
    });

    test('the account is kept, the secret in the keystore and not in the settings, and can be removed', () async {
      await storage.save(config(endpoint: 'https://acct.r2.cloudflarestorage.com'), 'topsecret');
      final again = S3Storage(settings, secret: secret);
      await again.load();
      expect(again.available, isTrue);
      expect(again.config!.endpoint, 'https://acct.r2.cloudflarestorage.com');
      expect(again.config!.bucket, 'bucket');
      for (final k in ['s3_endpoint', 's3_region', 's3_bucket', 's3_access_key', 's3_uploads']) {
        expect(await settings.get(k) ?? '', isNot(contains('topsecret')));
      }
      await again.remove();
      expect(again.available, isFalse);
      expect(secret.value, isNull);
      final third = S3Storage(settings, secret: secret);
      await third.load();
      expect(third.available, isFalse);
    });

    test('sharing without an account, and with keys the service refuses, says what is wrong', () async {
      await expectLater(storage.upload(Uint8List(1)), throwsA(predicate((e) => '$e'.contains('Set up S3'))));
      await storage.save(config(), 'wrong');
      await expectLater(storage.upload(Uint8List(1)), throwsA(predicate((e) => '$e'.contains('secret key'))));
    });

    test('addresses are tidied up', () {
      expect(S3Config.normalizeEndpoint('acct.r2.cloudflarestorage.com/'), 'https://acct.r2.cloudflarestorage.com');
      expect(S3Config.normalizeEndpoint('http://x.example.org'), isNull);
      expect(S3Config.normalizeEndpoint('http://127.0.0.1:9000', allowInsecure: true), 'http://127.0.0.1:9000');
      expect(S3Config.normalizeEndpoint('  '), isNull);
    });
  });
}
