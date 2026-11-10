import 'dart:async';
import 'dart:typed_data';

import 'package:notes/cloudsync/cloud_folder.dart';

/// A cloud folder in memory, with a way to make writes fail (the network drops).
class MemoryCloudFolder implements CloudFolder {
  final Map<String, Uint8List> files = {};
  int writes = 0;

  /// When set, the n-th write from now on throws.
  int? failWriteAfter;

  /// While set, removing a file whose path starts with it throws.
  String? failDeletePrefix;

  /// While set, every read, write and listing waits for it (a slow or stalled service).
  Completer<void>? hold;

  /// How many reads, writes and listings there were.
  int calls = 0;

  /// How many times [stamps] was asked.
  int stampCalls = 0;

  /// When false the folder cannot say what changed ([stamps] answers null), like a service that has no ETags for directories.
  bool canStamp = true;

  /// The write (or removal) a file last had, to tell what changed.
  final Map<String, int> _version = {};
  int _tick = 0;

  /// How many listings there were, and how many requests were being waited for at once at most.
  int listings = 0;
  int inFlight = 0, maxInFlight = 0;

  /// How long every request takes (a service on the other side of the world).
  Duration latency = Duration.zero;

  Future<void> _wait() async {
    calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final h = hold;
      if (h != null) await h.future;
      if (latency > Duration.zero) await Future<void>.delayed(latency);
    } finally {
      inFlight--;
    }
  }

  @override
  String get label => 'Memory';

  @override
  Future<List<String>> list(String dir) async {
    listings++;
    await _wait();
    return [
      for (final p in files.keys)
        if (p.startsWith('$dir/') && !p.substring(dir.length + 1).contains('/')) p.substring(dir.length + 1),
    ];
  }

  @override
  Future<Uint8List?> read(String path) async {
    await _wait();
    return files[path];
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    await _wait();
    final left = failWriteAfter;
    if (left != null) {
      if (left <= 0) {
        failWriteAfter = null;
        throw const CloudFolderException('the network dropped');
      }
      failWriteAfter = left - 1;
    }
    writes++;
    files[path] = Uint8List.fromList(bytes);
    _version[path] = ++_tick;
  }

  @override
  Future<void> delete(String path) async {
    await _wait();
    final prefix = failDeletePrefix;
    if (prefix != null && path.startsWith(prefix)) throw const CloudFolderException('the service said no');
    files.remove(path);
  }

  /// A token for a directory that changes with anything below it, like the ETag of a Nextcloud.
  @override
  Future<Map<String, String>?> stamps(String dir) async {
    stampCalls++;
    await _wait();
    if (!canStamp) return null;
    final prefix = dir.isEmpty ? '' : '$dir/';
    final below = [for (final p in files.keys) if (p.startsWith(prefix)) p]..sort();
    if (below.isEmpty) return const {};
    String token(Iterable<String> paths) => '${[for (final p in paths) '$p@${_version[p]}'].join('|').hashCode}-${paths.length}';
    final out = <String, String>{'': token(below)};
    final entries = {for (final p in below) p.substring(prefix.length).split('/').first};
    for (final e in entries) {
      out[e] = token([for (final p in below) if (p.substring(prefix.length) == e || p.substring(prefix.length).startsWith('$e/')) p]);
    }
    return out;
  }
}
