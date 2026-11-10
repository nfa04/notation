import 'dart:async';
import 'dart:typed_data';

import 'cloud_folder.dart';

/// A cloud folder that does not read again what has not changed.
///
/// A service that keeps a stamp for every entry of a directory (a Nextcloud: the ETag of a directory follows everything below it, see
/// [CloudFolder.stamps]) can say in one request which of the files at the top of the folder - the manifest of each device, the
/// participants of a share, the files of a sign-in - changed. This keeps what was read of them and hands it out again while the stamp is
/// the same, so that every part of the sync gets it - a full run, the look when a note is opened, the sign-in, the shares - without each
/// having its own rules.
///
/// What counts, and what does not:
/// * only files of one directory level ("device/manifest", "participants/name") and the listing of one directory, and files up to
///   [maxFileBytes]: the notes, pictures and attachments are named by version and read once, and deeper listings are made just
///   after writes;
/// * the stamps are asked once for [stampsFor] and shared by all that read meanwhile, so a file another device changed is seen up to
///   that long late (the runs that a person asks for - "Sync now" - call [invalidate] first and are not late);
/// * a kept file is dropped after [maxAge] whatever the stamps say (a safety net for a service whose stamps are wrong), and one that
///   this device writes or removes is dropped at once;
/// * a service that cannot give stamps is not cached at all: every read goes through.
class CachingFolder implements CloudFolder {
  /// The folder that is read from and written to. A new one may be put here for each run (the account may have changed): what is kept
  /// stays, and holds only while the stamps say so.
  CloudFolder inner;

  final Duration stampsFor, maxAge;
  final int maxFileBytes, maxTotalBytes;
  final DateTime Function() clock;

  CachingFolder(
    this.inner, {
    this.stampsFor = const Duration(seconds: 15),
    this.maxAge = const Duration(minutes: 10),
    this.maxFileBytes = 1 << 20,
    this.maxTotalBytes = 16 << 20,
    this.clock = DateTime.now,
  });

  @override
  String get label => inner.label;

  /// Counts up whenever what is kept is dropped, so that a read that began before does not keep what it read.
  int _generation = 0;

  Map<String, String>? _stamps;
  DateTime? _stampsAt; // (set also when the service could not say: that is not asked again at once either)
  Future<Map<String, String>?>? _asking;

  final _files = <String, ({Uint8List bytes, String token, DateTime at})>{};
  final _lists = <String, ({List<String> names, String token, DateTime at})>{};
  int _bytes = 0;

  /// How many files and listings were handed out from what was kept (for tests and the log).
  int hits = 0;

  /// Forgets everything: the next reads ask the service.
  void invalidate() {
    _generation++;
    _stamps = null;
    _stampsAt = null;
    _files.clear();
    _lists.clear();
    _bytes = 0;
  }

  // ---- what the service says changed

  Future<Map<String, String>?> _look() {
    final at = _stampsAt;
    if (at != null && clock().difference(at) < stampsFor) return Future.value(_stamps);
    return _asking ??= _ask();
  }

  Future<Map<String, String>?> _ask() async {
    final generation = _generation;
    try {
      final stamps = await inner.stamps('');
      if (generation == _generation) {
        _stamps = stamps;
        _stampsAt = clock();
      }
      return stamps;
    } catch (_) {
      return null; // (the read itself will tell what is wrong)
    } finally {
      _asking = null;
    }
  }

  static String _first(String path) => path.contains('/') ? path.substring(0, path.indexOf('/')) : path;

  /// Whether a file at [path] may be kept: at most one directory down.
  static bool _kept(String path) => '/'.allMatches(path).length <= 1;

  /// A change of a file or a directory here: what depends on it, and what is known of the stamps, is no longer good.
  void _changed(String path) {
    _generation++;
    _stampsAt = null;
    final old = _files.remove(path);
    if (old != null) _bytes -= old.bytes.length;
    _lists.remove(_first(path));
  }

  // ---- reading

  @override
  Future<Uint8List?> read(String path) async {
    if (!_kept(path)) return inner.read(path);
    final token = (await _look())?[_first(path)];
    if (token == null) return inner.read(path);
    final kept = _files[path];
    if (kept != null && kept.token == token && clock().difference(kept.at) < maxAge) {
      hits++;
      return Uint8List.fromList(kept.bytes);
    }
    final generation = _generation;
    final bytes = await inner.read(path);
    if (generation == _generation) {
      final old = _files.remove(path);
      if (old != null) _bytes -= old.bytes.length;
      if (bytes != null && bytes.length <= maxFileBytes) {
        if (_bytes + bytes.length > maxTotalBytes) {
          _files.clear();
          _bytes = 0;
        }
        _files[path] = (bytes: Uint8List.fromList(bytes), token: token, at: clock());
        _bytes += bytes.length;
      }
    }
    return bytes;
  }

  @override
  Future<List<String>> list(String dir) async {
    if (dir.isEmpty || dir.contains('/')) return inner.list(dir);
    final token = (await _look())?[dir];
    if (token == null) return inner.list(dir);
    final kept = _lists[dir];
    if (kept != null && kept.token == token && clock().difference(kept.at) < maxAge) {
      hits++;
      return [...kept.names];
    }
    final generation = _generation;
    final names = await inner.list(dir);
    if (generation == _generation) _lists[dir] = (names: [...names], token: token, at: clock());
    return names;
  }

  @override
  Future<Map<String, String>?> stamps(String dir) async {
    final generation = _generation;
    final stamps = await inner.stamps(dir);
    // what the sync asked for itself is as good as what this would have asked: reads that follow use it
    if (dir.isEmpty && generation == _generation) {
      _stamps = stamps;
      _stampsAt = clock();
    }
    return stamps;
  }

  // ---- changing

  @override
  Future<void> write(String path, Uint8List bytes) async {
    try {
      await inner.write(path, bytes);
    } finally {
      _changed(path);
    }
  }

  @override
  Future<void> delete(String path) async {
    try {
      await inner.delete(path);
    } finally {
      _changed(path);
    }
  }
}
