import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../util/public_host.dart';

/// One extension in the gallery: what it is, and where its package is with the checksum it has to have.
class GalleryEntry {
  final String id, name, version, description, author, url, sha256;
  final List<String> permissions;
  final int size;
  const GalleryEntry({required this.id, required this.name, required this.version, required this.description, required this.author, required this.url, required this.sha256, required this.permissions, required this.size});

  static GalleryEntry? tryParse(Object? json) {
    if (json is! Map) return null;
    String text(String k) => json[k] is String ? json[k] as String : '';
    final perms = json['permissions'];
    final entry = GalleryEntry(
      id: text('id'),
      name: text('name'),
      version: text('version'),
      description: text('description'),
      author: text('author'),
      url: text('url'),
      sha256: text('sha256').toLowerCase(),
      permissions: perms is List ? [for (final p in perms) '$p'] : const [],
      size: json['size'] is int ? json['size'] as int : 0,
    );
    final valid = entry.id.isNotEmpty && entry.name.isNotEmpty && entry.version.isNotEmpty && Uri.tryParse(entry.url)?.scheme == 'https' && RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.sha256);
    return valid ? entry : null;
  }
}

/// Why the gallery could not be read or an extension could not be had from it, in words for a person.
class GalleryException implements Exception {
  final String message;
  GalleryException(this.message);
  @override
  String toString() => message;
}

/// Whether version [a] is newer than [b] (numbers separated by dots; what is not a number counts as 0).
bool versionIsNewer(String a, String b) {
  List<int> parts(String v) => [for (final p in v.split(RegExp(r'[.+-]'))) int.tryParse(p) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}

/// The gallery of extensions: a list (`index.json`) that lives in a repository as a plain file, no server of ours. Each entry names a
/// package and its SHA-256; what is downloaded is only used when it has exactly that checksum, and only from the host the list
/// itself came from. What it contains is then shown to the person (the permissions it asks for) before it is installed, like any
/// other extension, so the gallery adds a place to look, not any trust.
class ExtensionGallery {
  static const defaultIndex = 'https://raw.githubusercontent.com/nfa04/notation/main/extensions/index.json';

  final Uri index;
  final Future<List<int>> Function(Uri url, {int limit}) _get;

  ExtensionGallery({String? indexUrl, Future<List<int>> Function(Uri url, {int limit})? get})
      : index = Uri.parse(indexUrl ?? defaultIndex),
        _get = get ?? _download;

  static Future<List<int>> _download(Uri url, {int limit = 8 * 1024 * 1024}) async {
    if (url.scheme != 'https') throw GalleryException('Only https addresses are used.');
    try {
      await checkPublicHost(url);
    } on StateError catch (e) {
      throw GalleryException(e.message);
    }
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
    try {
      final response = await dio.get<ResponseBody>(
        url.toString(),
        options: Options(responseType: ResponseType.stream, followRedirects: false, validateStatus: (_) => true, receiveTimeout: const Duration(seconds: 30)),
      );
      if (response.statusCode != 200) throw GalleryException('The gallery answered with ${response.statusCode}.');
      final bytes = <int>[];
      await for (final chunk in response.data!.stream) {
        bytes.addAll(chunk);
        if (bytes.length > limit) throw GalleryException('The answer is too big.');
      }
      return bytes;
    } on DioException catch (e) {
      throw GalleryException('Could not reach the gallery: ${e.message ?? e.type.name}');
    } finally {
      dio.close(force: true);
    }
  }

  /// The extensions in the gallery, by name.
  Future<List<GalleryEntry>> list() async {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(await _get(index, limit: 1024 * 1024), allowMalformed: true));
    } on FormatException {
      throw GalleryException('The gallery is not a list of extensions.');
    }
    final raw = json is Map ? json['extensions'] : null;
    if (raw is! List) throw GalleryException('The gallery is not a list of extensions.');
    final out = <GalleryEntry>[];
    for (final e in raw) {
      final entry = GalleryEntry.tryParse(e);
      // a package from another host than the list is not taken: the list could otherwise point anywhere
      if (entry != null && Uri.parse(entry.url).host == index.host) out.add(entry);
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// The zip of [entry], checked against its checksum.
  Future<List<int>> download(GalleryEntry entry) async {
    final uri = Uri.parse(entry.url);
    if (uri.host != index.host) throw GalleryException('The package is not on the same website as the gallery.');
    final bytes = await _get(uri, limit: 8 * 1024 * 1024);
    if (sha256.convert(bytes).toString() != entry.sha256) throw GalleryException('The package does not match its checksum: it was not installed.');
    return bytes;
  }
}
