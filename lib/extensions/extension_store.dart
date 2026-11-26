import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../net/extra_roots.dart';
import 'store_defaults.dart';

/// Why the store could not be used (the text is shown to the person).
class StoreException implements Exception {
  final String message;
  const StoreException(this.message);

  @override
  String toString() => message;
}

/// An extension as the store's catalogue lists it. These are claims: the zip's own manifest is what counts when it is installed.
class StoreEntry {
  static final idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{1,62}[a-z0-9]$');
  final String id, name, version, author, summary, description, category, updated, sha256, logoSha256;
  final List<String> tags, permissions, hosts;
  final int size;

  const StoreEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.summary,
    required this.description,
    required this.category,
    required this.updated,
    required this.sha256,
    required this.logoSha256,
    required this.tags,
    required this.permissions,
    required this.hosts,
    required this.size,
  });

  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  factory StoreEntry.fromJson(Object? json) {
    if (json is! Map) throw const StoreException('The store sent an entry that is not an object.');
    String text(String key, {int max = 4000, bool required = false}) {
      final v = json[key];
      if (v == null && !required) return '';
      if (v is! String || v.length > max || (required && v.isEmpty)) throw StoreException('The store sent a bad "$key".');
      return v;
    }

    List<String> list(String key, int max) {
      final v = json[key] ?? const [];
      if (v is! List || v.length > max || v.any((e) => e is! String || e.length > 253)) throw StoreException('The store sent a bad "$key".');
      return v.cast<String>();
    }

    final id = text('id', max: 64, required: true);
    if (!idPattern.hasMatch(id) || id.contains('..')) throw const StoreException('The store sent an entry with a bad id.');
    final size = json['size'];
    if (size is! int || size <= 0 || size > maxZipBytes) throw const StoreException('The store sent a bad size.');
    final sha = text('sha256', max: 64, required: true), logoSha = text('logoSha256', max: 64, required: true);
    if (!_hash.hasMatch(sha) || !_hash.hasMatch(logoSha)) throw const StoreException('The store sent a bad hash.');
    return StoreEntry(
      id: id,
      name: text('name', max: 60, required: true),
      version: text('version', max: 20, required: true),
      author: text('author', max: 80),
      summary: text('summary', max: 140, required: true),
      description: text('description'),
      category: text('category', max: 20),
      updated: text('updated', max: 10),
      sha256: sha,
      logoSha256: logoSha,
      tags: list('tags', 8),
      permissions: list('permissions', 40),
      hosts: list('hosts', 10),
      size: size,
    );
  }

  static const maxZipBytes = 2 << 20;
  static const maxLogoBytes = 200 << 10;
}

/// The catalogue: its entries and the number that only goes up.
class StoreCatalogue {
  final int sequence;
  final String generated;
  final List<StoreEntry> entries;
  const StoreCatalogue(this.sequence, this.generated, this.entries);
}

/// Remembers the highest catalogue number seen, so that an old (once genuine) catalogue cannot be played back.
abstract class StoreMemory {
  Future<int> lastSequence(String store);
  Future<void> remember(String store, int sequence);
}

class MemoryStoreMemory implements StoreMemory {
  final Map<String, int> _seen = {};
  @override
  Future<int> lastSequence(String store) async => _seen[store] ?? 0;
  @override
  Future<void> remember(String store, int sequence) async => _seen[store] = sequence;
}

/// Keeps the number in a small file in the app's folder.
class FileStoreMemory implements StoreMemory {
  Future<File> _file() async => File(p.join((await getApplicationSupportDirectory()).path, 'extension_store.json'));

  Future<Map<String, Object?>> _read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      return (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
    } catch (_) {
      return {};
    }
  }

  @override
  Future<int> lastSequence(String store) async => (await _read())[store] as int? ?? 0;

  @override
  Future<void> remember(String store, int sequence) async {
    final all = await _read();
    all[store] = sequence;
    await (await _file()).writeAsString(jsonEncode(all), flush: true);
  }
}

/// Which store the person uses: the built-in one, or one they chose (an address and the public key its catalogue is signed with).
/// A chosen store has to bring its own key: the built-in key says nothing about someone else's catalogue, and without a key there would be nothing
/// to tell a real catalogue from a forged one.
class StoreSource {
  final String address;
  final String publicKey;
  const StoreSource(this.address, this.publicKey);

  static const builtIn = StoreSource('', '');

  bool get isBuiltIn => address.isEmpty;

  Uri get uri => Uri.parse(isBuiltIn ? extensionStoreAddress : address);
  List<String> get keys => isBuiltIn ? extensionStorePublicKeys : [publicKey];

  /// Null when [address] and [key] are fine to use, otherwise what is wrong (in words for the person).
  static String? problem(String address, String key) {
    final u = Uri.tryParse(address.trim());
    if (u == null || u.scheme != 'https' || u.host.isEmpty || u.hasQuery || u.hasFragment || u.userInfo.isNotEmpty || (u.path.isNotEmpty && u.path != '/')) {
      return 'The address must be like https://store.example.org (https, no path).';
    }
    try {
      if (base64.decode(key.trim()).length != 32) return 'The public key must be the 32 bytes of an Ed25519 key, in base64.';
    } catch (_) {
      return 'The public key must be the 32 bytes of an Ed25519 key, in base64.';
    }
    return null;
  }

  static Future<File> _file() async => File(p.join((await getApplicationSupportDirectory()).path, 'extension_store_source.json'));

  static Future<StoreSource> load() async {
    if (kIsWeb) return builtIn;
    try {
      final f = await _file();
      if (!await f.exists()) return builtIn;
      final m = jsonDecode(await f.readAsString()) as Map;
      final a = '${m['address']}', k = '${m['key']}';
      return problem(a, k) == null ? StoreSource(a.trim(), k.trim()) : builtIn;
    } catch (_) {
      return builtIn;
    }
  }

  /// Saves [source]; the built-in one removes the file.
  static Future<void> save(StoreSource source) async {
    final f = await _file();
    if (source.isBuiltIn) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.writeAsString(jsonEncode({'address': source.address, 'key': source.publicKey}), flush: true);
  }
}

/// Gets [url] and at most [maxBytes] of it. Only https, no redirects (the store's own addresses never redirect, and one that did could
/// send the app somewhere the signature says nothing about), and an answer bigger than allowed is cut off rather than read to the end.
typedef StoreFetch = Future<Uint8List> Function(Uri url, int maxBytes);

Future<Uint8List> fetchLimited(Uri url, int maxBytes) async {
  if (url.scheme != 'https') throw const StoreException('The store must be reached over https.');
  await trustBundledRoots();
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    followRedirects: false,
    validateStatus: (s) => s == 200,
    responseType: ResponseType.stream,
    headers: {'User-Agent': 'Notation'},
  ));
  if (!kIsWeb) {
    dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
      if (extensionStoreCertFile.isEmpty) return HttpClient()..autoUncompress = true;
      return HttpClient(context: SecurityContext(withTrustedRoots: true)..setTrustedCertificates(extensionStoreCertFile));
    });
  }
  try {
    final r = await dio.getUri<ResponseBody>(url);
    final length = int.tryParse(r.headers.value('content-length') ?? '');
    if (length != null && length > maxBytes) throw const StoreException('The store sent more than it should.');
    final out = BytesBuilder(copy: false);
    await for (final chunk in r.data!.stream) {
      out.add(chunk);
      if (out.length > maxBytes) throw const StoreException('The store sent more than it should.');
    }
    return out.takeBytes();
  } on DioException catch (e) {
    final code = e.response?.statusCode;
    throw StoreException(code == null ? 'The store could not be reached.' : 'The store answered with error $code.');
  }
}

/// Talks to a store: reads the catalogue, checks its signature, and fetches logos and zips, checking each against the catalogue.
class ExtensionStoreClient {
  /// What is mixed into what is signed (the store's `Catalogue::DOMAIN`).
  static const domain = 'notation-extension-store-v1\n';
  static const maxCatalogueBytes = 2 << 20;

  final Uri base;
  final StoreFetch fetch;
  final List<String> publicKeys;
  final StoreMemory memory;

  ExtensionStoreClient({Uri? base, this.fetch = fetchLimited, this.publicKeys = extensionStorePublicKeys, StoreMemory? memory})
      : base = base ?? Uri.parse(extensionStoreAddress),
        memory = memory ?? (kIsWeb ? MemoryStoreMemory() : FileStoreMemory());

  /// A client for the store the person chose (or the built-in one).
  static Future<ExtensionStoreClient> forSettings() async {
    final s = await StoreSource.load();
    return ExtensionStoreClient(base: s.uri, publicKeys: s.keys);
  }

  /// Whether there is a store to talk to.
  bool get configured => base.scheme == 'https' && base.host.isNotEmpty;

  String get _store => base.host;

  Uri _url(String path) => base.replace(path: path, query: '', fragment: '');

  Future<StoreCatalogue> catalogue() async {
    if (!configured) throw const StoreException('No extension store is set up.');
    final json = await fetch(_url('/v1/index.json'), maxCatalogueBytes);
    final sig = await fetch(_url('/v1/index.json.sig'), 1024);
    if (!await verifies(json, sig)) throw const StoreException('The store\'s catalogue is not signed by the key this app trusts. Nothing was used.');
    final Object? doc;
    try {
      doc = jsonDecode(utf8.decode(json));
    } catch (_) {
      throw const StoreException('The store sent a catalogue that cannot be read.');
    }
    if (doc is! Map || doc['format'] != 1) throw const StoreException('This app is too old for this store (or the store is too new).');
    final sequence = doc['sequence'];
    if (sequence is! int || sequence < 1) throw const StoreException('The store sent a bad catalogue number.');
    if (sequence < await memory.lastSequence(_store)) {
      throw const StoreException('The store sent an older catalogue than one this app has seen: it was refused.');
    }
    final list = doc['extensions'];
    if (list is! List || list.length > 5000) throw const StoreException('The store sent a bad list.');
    final entries = [for (final e in list) StoreEntry.fromJson(e)];
    if (entries.map((e) => e.id).toSet().length != entries.length) throw const StoreException('The store lists an extension twice.');
    await memory.remember(_store, sequence);
    return StoreCatalogue(sequence, '${doc['generated'] ?? ''}', entries);
  }

  /// Whether [signature] (base64 of 64 bytes) is a signature of [catalogue] by one of the trusted keys.
  Future<bool> verifies(Uint8List catalogue, Uint8List signature) async {
    final List<int> sig;
    try {
      sig = base64.decode(utf8.decode(signature).trim());
    } catch (_) {
      return false;
    }
    if (sig.length != 64) return false;
    final message = [...utf8.encode(domain), ...catalogue];
    for (final k in publicKeys) {
      try {
        final key = base64.decode(k);
        if (key.length != 32) continue;
        if (await Ed25519().verify(message, signature: Signature(sig, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)))) return true;
      } catch (_) {}
    }
    return false;
  }

  /// The logo (a PNG, its hash as the catalogue says); null if it is wrong in any way (a missing logo is no reason to stop).
  Future<Uint8List?> logo(StoreEntry e) async {
    try {
      final bytes = await fetch(_url('/v1/extensions/${e.id}/logo.png'), StoreEntry.maxLogoBytes);
      if (_sha(bytes) != e.logoSha256) return null;
      if (bytes.length < 8 || bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4E || bytes[3] != 0x47) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// The zip, exactly the bytes the catalogue promised (size and SHA-256).
  Future<Uint8List> zip(StoreEntry e) async {
    final bytes = await fetch(_url('/v1/extensions/${e.id}/extension.zip'), e.size);
    if (bytes.length != e.size || _sha(bytes) != e.sha256) {
      throw const StoreException('The download is not what the store listed (damaged, or the store changed while you looked). Nothing was installed. Try again.');
    }
    return bytes;
  }

  static String _sha(List<int> bytes) => crypto.sha256.convert(bytes).toString();
}
