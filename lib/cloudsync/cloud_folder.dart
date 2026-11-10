import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A folder on cloud storage the devices of one person can all reach, as the sync through a folder (see `FolderSync`) uses it:
/// named files in directories below a root, read, written and removed one at a time. Paths are written `dir/name` with `/`; the
/// root is the folder the person chose and is made when the first file is written.
abstract class CloudFolder {
  /// What the person calls it ("Nextcloud").
  String get label;

  /// The names of the files directly in [dir] (empty when there is no such directory).
  Future<List<String>> list(String dir);

  /// The file at [path], or null when there is none.
  Future<Uint8List?> read(String path);

  /// Writes [bytes] as the file at [path] (the directories on the way are made); an existing file is replaced.
  Future<void> write(String path, Uint8List bytes);

  /// Removes the file at [path]; nothing happens when there is none.
  Future<void> delete(String path);

  /// One request that says what changed without reading it: a token for [dir] itself (under the key `''`) and one for every entry
  /// directly in it (directories too), each changing whenever anything in that file or directory does. A service that keeps this for
  /// directories as well (a Nextcloud does: the ETag of a directory follows what is below it) lets a sync see that nothing changed
  /// in one request. Null when the service cannot say (then everything is asked, as before); an entry that is not in the map does
  /// not exist.
  Future<Map<String, String>?> stamps(String dir);
}

/// A cloud folder that did not do what was asked, with words for the person.
class CloudFolderException implements Exception {
  final String message;

  /// The HTTP status of the answer, when there was one.
  final int? status;

  const CloudFolderException(this.message, [this.status]);

  /// Whether trying again may help: the service is busy or had a hiccup, not "no" (login, full, not allowed).
  bool get transient => const {408, 429, 500, 502, 503, 504}.contains(status);

  @override
  String toString() => message;
}

/// The account the folder needs is not usable on this device (no login, no password in the keystore): every request would fail the same
/// way, so a run stops at the first one and says so once, instead of once for every file.
class CloudAccountMissing extends CloudFolderException {
  const CloudAccountMissing(super.message);
}

/// A folder that tries again when the service is busy or the connection hiccups (a big sync is many small requests, and a service
/// that answers "slow down" or a connection that drops for a second should not end it). Gives up after the [delays] have passed.
class RetryingFolder implements CloudFolder {
  final CloudFolder inner;
  final List<Duration> delays;

  const RetryingFolder(this.inner, {this.delays = const [Duration(seconds: 1), Duration(seconds: 4), Duration(seconds: 10)]});

  @override
  String get label => inner.label;

  static bool _again(Object e) {
    if (e is CloudFolderException) return e.transient;
    if (e is DioException) {
      return switch (e.type) {
        DioExceptionType.connectionError || DioExceptionType.connectionTimeout || DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout => true,
        DioExceptionType.badResponse => const {408, 429, 500, 502, 503, 504}.contains(e.response?.statusCode),
        _ => false,
      };
    }
    return e is TimeoutException;
  }

  Future<T> _try<T>(Future<T> Function() job) async {
    for (var i = 0;; i++) {
      try {
        return await job();
      } catch (e) {
        if (i >= delays.length || !_again(e)) rethrow;
        await Future<void>.delayed(delays[i]);
      }
    }
  }

  @override
  Future<List<String>> list(String dir) => _try(() => inner.list(dir));

  @override
  Future<Uint8List?> read(String path) => _try(() => inner.read(path));

  @override
  Future<void> write(String path, Uint8List bytes) => _try(() => inner.write(path, bytes));

  @override
  Future<void> delete(String path) => _try(() => inner.delete(path));

  @override
  Future<Map<String, String>?> stamps(String dir) =>
      _try(() => inner.stamps(dir));
}
