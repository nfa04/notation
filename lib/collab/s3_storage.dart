import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../data/settings_repository.dart';
import '../l10n/language.dart';
import '../sync/caldav_service.dart' show SecretStore, KeystoreSecretStore;
import '../cloudsync/cloud_folder.dart';
import 'share_storage.dart';
import '../data/app_secure_storage.dart';

/// AWS Signature Version 4, the way of signing requests that S3 and everything that copies its interface
/// (Cloudflare R2, Backblaze B2, Wasabi, MinIO, ...) accepts. Only what is needed here: requests signed in
/// their headers, and addresses that are signed in their query ("presigned") so that anyone holding one can
/// download the file until it expires.
class SigV4 {
  final String accessKey;
  final String secretKey;
  final String region;
  final String service;

  const SigV4({required this.accessKey, required this.secretKey, required this.region, this.service = 's3'});

  static String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String sha256Hex(List<int> bytes) => hex(sha256.convert(bytes).bytes);

  /// "20130524T000000Z".
  static String stamp(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  /// Percent-encoding as the signature wants it: only letters, digits and `-_.~` stay as they are.
  static String encode(String s, {bool keepSlash = false}) {
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final c = String.fromCharCode(b);
      if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c) || (keepSlash && c == '/')) {
        out.write(c);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  List<int> _hmac(List<int> key, String data) => Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  String _signature(String date, String stringToSign) {
    final kDate = _hmac(utf8.encode('AWS4$secretKey'), date);
    final kRegion = _hmac(kDate, region);
    final kService = _hmac(kRegion, service);
    final kSigning = _hmac(kService, 'aws4_request');
    return hex(_hmac(kSigning, stringToSign));
  }

  String _canonicalQuery(Map<String, String> query) {
    final keys = query.keys.toList()..sort();
    return [for (final k in keys) '${encode(k)}=${encode(query[k]!)}',].join('&');
  }

  String _scope(String date) => '$date/$region/$service/aws4_request';

  String _stringToSign(String time, String date, String canonicalRequest) =>
      'AWS4-HMAC-SHA256\n$time\n${_scope(date)}\n${sha256Hex(utf8.encode(canonicalRequest))}';

  /// The headers to send with a request: [headers] (which must include `host`) plus `x-amz-date`,
  /// `x-amz-content-sha256` and `Authorization`. [path] is the path as it goes on the wire, already encoded.
  Map<String, String> sign({
    required String method,
    required String path,
    required Map<String, String> headers,
    required String payloadHash,
    required DateTime now,
    Map<String, String> query = const {},
  }) {
    final time = stamp(now);
    final date = time.substring(0, 8);
    final all = {
      for (final e in headers.entries) e.key.toLowerCase(): e.value.trim(),
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': time,
    };
    final names = all.keys.toList()..sort();
    final canonical = [
      method,
      path,
      _canonicalQuery(query),
      [for (final n in names) '$n:${all[n]}\n'].join(),
      names.join(';'),
      payloadHash,
    ].join('\n');
    final signature = _signature(date, _stringToSign(time, date, canonical));
    return {
      ...all,
      'Authorization': 'AWS4-HMAC-SHA256 Credential=$accessKey/${_scope(date)},SignedHeaders=${names.join(';')},Signature=$signature',
    };
  }

  /// A query that makes [method] on [path] allowed for [expires] (at most 7 days) without any keys.
  Map<String, String> presignedQuery({
    required String method,
    required String host,
    required String path,
    required Duration expires,
    required DateTime now,
  }) {
    final time = stamp(now);
    final date = time.substring(0, 8);
    final query = {
      'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
      'X-Amz-Credential': '$accessKey/${_scope(date)}',
      'X-Amz-Date': time,
      'X-Amz-Expires': '${expires.inSeconds}',
      'X-Amz-SignedHeaders': 'host',
    };
    final canonical = [method, path, _canonicalQuery(query), 'host:$host\n', 'host', 'UNSIGNED-PAYLOAD'].join('\n');
    return {...query, 'X-Amz-Signature': _signature(date, _stringToSign(time, date, canonical))};
  }
}

/// Where a bucket on an S3-compatible service is, and the keys to use it.
class S3Config {
  /// The service address, `https://<account>.r2.cloudflarestorage.com` or `https://s3.eu-central-1.amazonaws.com`.
  final String endpoint;

  /// The region the service wants in signatures (`auto` for Cloudflare R2, else like `eu-central-1`).
  final String region;
  final String bucket;
  final String accessKey;

  const S3Config({required this.endpoint, required this.region, required this.bucket, required this.accessKey});

  bool get isComplete => endpoint.isNotEmpty && region.isNotEmpty && bucket.isNotEmpty && accessKey.isNotEmpty;

  /// [typed] as an address with a scheme and no closing slash; null if it is none.
  static String? normalizeEndpoint(String typed, {bool allowInsecure = false}) {
    var u = typed.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isEmpty) return null;
    if (!u.contains('://')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && !(allowInsecure && uri.scheme == 'http')) return null;
    return u;
  }
}

/// Shares through a bucket on an S3-compatible service the person has an account with. A sealed copy goes in
/// with one signed request; the link is an address signed for 7 days, which is a plain download. Copies that
/// are past their time are removed from the bucket the next time something is shared.
class S3Storage extends ShareStorage {
  static const _kEndpoint = 's3_endpoint';
  static const _kRegion = 's3_region';
  static const _kBucket = 's3_bucket';
  static const _kAccess = 's3_access_key';
  static const _kUploads = 's3_uploads';

  /// S3 signs addresses for 7 days at most.
  static const lifetime = Duration(days: 7);

  final SettingsRepository? _settings;
  final SecretStore _secret;
  final Dio? _dio;
  final DateTime Function() _now;

  late final UploadLedger _ledger = UploadLedger(_settings, _kUploads, now: _now);
  S3Config? _config;
  String? _secretKey;

  /// [dio] and [now] are for tests against a local server.
  S3Storage(this._settings, {SecretStore? secret, Dio? dio, DateTime Function()? now})
      : _secret = secret ?? const KeystoreSecretStore(appSecureStorage, 's3_secret_key'),
        _dio = dio,
        _now = now ?? DateTime.now;

  S3Config? get config => _config;

  /// The secret key of the account (for handing the account to another device of the person).
  String? get secretKey => _secretKey;

  @override
  String get label => tr('S3 storage');

  /// A folder (a key prefix) of the bucket for the sync of the library (see `FolderSync`).
  CloudFolder folderFor(String name) => _S3Folder(this, name);

  @override
  bool get available => _config != null && _secretKey != null;

  @override
  String? get unavailableReason => available ? null : tr('Set up S3 storage in the settings first.');

  @override
  Duration get keeps => lifetime;

  Future<void> load() async {
    final s = _settings;
    if (s == null) return;
    final endpoint = await s.get(_kEndpoint), bucket = await s.get(_kBucket), access = await s.get(_kAccess);
    if (endpoint == null || bucket == null || access == null) return;
    _config = S3Config(endpoint: endpoint, region: await s.get(_kRegion) ?? 'auto', bucket: bucket, accessKey: access);
    _secretKey = await _secret.read();
    notifyListeners();
  }

  /// Keeps the account of a bucket (after [check] found it works).
  Future<void> save(S3Config config, String secretKey) async {
    final s = _settings;
    if (s != null) {
      await s.set(_kEndpoint, config.endpoint);
      await s.set(_kRegion, config.region);
      await s.set(_kBucket, config.bucket);
      await s.set(_kAccess, config.accessKey);
    }
    await _secret.write(secretKey);
    _config = config;
    _secretKey = secretKey;
    notifyListeners();
  }

  Future<void> remove() async {
    final s = _settings;
    if (s != null) {
      for (final k in [_kEndpoint, _kRegion, _kBucket, _kAccess]) {
        await s.remove(k);
      }
      await _ledger.clear();
    }
    await _secret.delete();
    _config = null;
    _secretKey = null;
    notifyListeners();
  }

  /// One client for all requests: a new one for each would open a new connection (and TLS handshake) every time, where a sync is hundreds
  /// of small requests that can share a few.
  Dio? _made;
  Dio get _client =>
      _dio ??
      (_made ??= Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 2),
        sendTimeout: const Duration(minutes: 5),
        validateStatus: (s) => s != null && s < 500,
      )));

  // ---- requests

  Uri _objectUri(S3Config c, String key) {
    final base = Uri.parse(c.endpoint);
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(path: '$prefix/${c.bucket}/$key', query: '');
  }

  String _wirePath(Uri uri) => SigV4.encode(Uri.decodeFull(uri.path), keepSlash: true); // (the path as it is signed and as it goes on the wire)

  String _hostHeader(Uri uri) => uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80) ? '${uri.host}:${uri.port}' : uri.host;

  Future<Response<List<int>>> _send(S3Config c, String secretKey, String method, String key, {Uint8List? body}) {
    final uri = _objectUri(c, key);
    final signer = SigV4(accessKey: c.accessKey, secretKey: secretKey, region: c.region);
    final headers = signer.sign(
      method: method,
      path: _wirePath(uri),
      headers: {'host': _hostHeader(uri), if (body != null) 'content-length': '${body.length}'},
      payloadHash: SigV4.sha256Hex(body ?? const []),
      now: _now(),
    )..remove('host')..remove('content-length');
    return _client.requestUri<List<int>>(
      Uri.parse('${uri.scheme}://${_hostHeader(uri)}${_wirePath(uri)}'),
      data: body == null ? null : Stream.fromIterable([body]),
      options: Options(
        method: method,
        headers: {...headers, if (body != null) ...{'Content-Length': '${body.length}', 'Content-Type': 'application/octet-stream'}},
        responseType: ResponseType.bytes,
      ),
    );
  }

  /// What the service said was wrong, from its error document (`<Code>AccessDenied</Code>`).
  String _why(Response<List<int>> r) {
    final text = utf8.decode(r.data ?? const [], allowMalformed: true);
    final code = RegExp(r'<Code>([^<]+)</Code>').firstMatch(text)?.group(1);
    switch (code) {
      case 'SignatureDoesNotMatch':
        return tr('The secret key is not right.');
      case 'InvalidAccessKeyId':
        return tr('The access key ID is not known to the service.');
      case 'NoSuchBucket':
        return tr('There is no bucket with that name.');
      case 'AccessDenied':
        return tr('These keys may not write to that bucket.');
    }
    return code ?? tr('The service answered with an error ({code}).', {'code': r.statusCode});
  }

  /// A signed address that downloads [key] without keys until [lifetime] has passed.
  Uri presignedUrl(S3Config c, String secretKey, String key) {
    final uri = _objectUri(c, key);
    final signer = SigV4(accessKey: c.accessKey, secretKey: secretKey, region: c.region);
    final query = signer.presignedQuery(method: 'GET', host: _hostHeader(uri), path: _wirePath(uri), expires: lifetime, now: _now());
    final q = (query.keys.toList()..sort()).map((k) => '${SigV4.encode(k)}=${SigV4.encode(query[k]!)}').join('&');
    return Uri.parse('${uri.scheme}://${_hostHeader(uri)}${_wirePath(uri)}?$q');
  }

  /// Tries the account: puts a small file in the bucket, downloads it through a signed address, and removes it.
  /// Null if everything works, else what is wrong.
  Future<String?> check(S3Config c, String secretKey) async {
    if (!c.isComplete || secretKey.isEmpty) return tr('Fill in every field.');
    final key = 'notation-check-${_random()}.txt';
    final body = Uint8List.fromList(utf8.encode('Notation'));
    try {
      final put = await _send(c, secretKey, 'PUT', key, body: body);
      if (put.statusCode != 200) return _why(put);
      try {
        final url = presignedUrl(c, secretKey, key);
        final got = await _client.getUri<List<int>>(url, options: Options(responseType: ResponseType.bytes));
        if (got.statusCode != 200 || utf8.decode(got.data ?? const [], allowMalformed: true) != 'Notation') {
          return tr('The file was stored but cannot be downloaded through a signed link ({code}). Is the region right?', {'code': got.statusCode});
        }
      } finally {
        await _send(c, secretKey, 'DELETE', key);
      }
      return null;
    } on DioException catch (e) {
      return tr('Could not reach {host}: {error}', {'host': Uri.tryParse(c.endpoint)?.host ?? c.endpoint, 'error': e.message ?? e.type.name});
    }
  }

  static String _random() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  // ---- ShareStorage

  @override
  Future<StoredFile> store(Uint8List sealed) async {
    final c = _config, secretKey = _secretKey;
    if (c == null || secretKey == null) throw StateError(tr('Set up S3 storage in the settings first.'));
    await _ledger.sweep(lifetime + const Duration(hours: 1), (key) async {
      final r = await _send(c, secretKey, 'DELETE', key);
      return r.statusCode == 204 || r.statusCode == 200 || r.statusCode == 404;
    });
    final key = 'shared/${_random()}.uninote.enc';
    final put = await _send(c, secretKey, 'PUT', key, body: sealed);
    if (put.statusCode != 200) throw StateError(_why(put));
    await _ledger.add(key);
    return StoredFile(presignedUrl(c, secretKey, key), key);
  }

  @override
  Future<void> replace(String ref, Uint8List sealed) async {
    final c = _config, secretKey = _secretKey;
    if (c == null || secretKey == null) throw StateError(tr('Set up S3 storage in the settings first.'));
    final put = await _send(c, secretKey, 'PUT', ref, body: sealed);
    if (put.statusCode != 200) throw StateError(_why(put));
  }
}

/// The folder of the sync through a cloud folder: the keys below a prefix in the bucket.
class _S3Folder implements CloudFolder {
  @override
  Future<Map<String, String>?> stamps(String dir) async => null;
  final S3Storage _storage;
  final String _name;

  _S3Folder(this._storage, this._name);

  @override
  String get label => _storage.label;

  ({S3Config c, String secret}) _account() {
    final c = _storage._config, secret = _storage._secretKey;
    if (c == null || secret == null) throw CloudAccountMissing(tr('Set up S3 storage in the settings first.'));
    return (c: c, secret: secret);
  }

  CloudFolderException _fail(Response<List<int>> r) => CloudFolderException(_storage._why(r), r.statusCode);

  @override
  Future<List<String>> list(String dir) async {
    final a = _account();
    final prefix = '$_name/$dir/';
    final names = <String>[];
    String? token;
    do {
      final base = _storage._objectUri(a.c, '');
      final query = {'list-type': '2', 'prefix': prefix, 'delimiter': '/', 'continuation-token': ?token};
      final signer = SigV4(accessKey: a.c.accessKey, secretKey: a.secret, region: a.c.region);
      final host = _storage._hostHeader(base);
      final path = _storage._wirePath(base);
      final headers = signer.sign(method: 'GET', path: path, headers: {'host': host}, payloadHash: SigV4.sha256Hex(const []), now: _storage._now(), query: query)..remove('host');
      final q = (query.keys.toList()..sort()).map((k) => '${SigV4.encode(k)}=${SigV4.encode(query[k]!)}').join('&');
      final r = await _storage._client.getUri<List<int>>(Uri.parse('${base.scheme}://$host$path?$q'), options: Options(headers: headers, responseType: ResponseType.bytes));
      if (r.statusCode != 200) throw _fail(r);
      final text = utf8.decode(r.data ?? const [], allowMalformed: true);
      for (final m in RegExp(r'<Key>([^<]*)</Key>').allMatches(text)) {
        final key = _unescape(m.group(1)!);
        if (key.startsWith(prefix) && key.length > prefix.length) names.add(key.substring(prefix.length));
      }
      token = text.contains('<IsTruncated>true</IsTruncated>') ? RegExp(r'<NextContinuationToken>([^<]*)</NextContinuationToken>',).firstMatch(text)?.group(1) : null;
      if (token != null) token = _unescape(token);
    } while (token != null);
    return names;
  }

  static String _unescape(String s) => s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');

  @override
  Future<Uint8List?> read(String path) async {
    final a = _account();
    final r = await _storage._send(a.c, a.secret, 'GET', '$_name/$path');
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200 || r.data == null) throw _fail(r);
    return Uint8List.fromList(r.data!);
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final a = _account();
    final r = await _storage._send(a.c, a.secret, 'PUT', '$_name/$path', body: bytes);
    if (r.statusCode != 200) throw _fail(r);
  }

  @override
  Future<void> delete(String path) async {
    final a = _account();
    final r = await _storage._send(a.c, a.secret, 'DELETE', '$_name/$path');
    if (r.statusCode != 204 && r.statusCode != 200 && r.statusCode != 404) throw _fail(r);
  }
}
