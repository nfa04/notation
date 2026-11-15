import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;

import '../web/web_files.dart';
import 'download.dart';
import 'model_pins.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ink/ink_recognizer.dart';

/// A downloaded file that is not the published one.
class _NotPublished implements Exception {
  final String name;
  _NotPublished(this.name);

  @override
  String toString() => 'The downloaded file $name is not the one that was published (its checksum differs). Try again.';
}

/// A model that is a few files in one folder, downloaded on request, with a
/// status and progress the Settings screen shows.
abstract class ModelFilesService extends DownloadableModel {
  /// File name -> where it comes from and about how big it is.
  Map<String, ({String url, int megabytes})> files;

  /// File name -> the SHA-256 the published file has, for the files of ours that are pinned (a file of another publisher's `main` is
  /// not: it may change). A file that arrives with another hash (cut short, or not the one that was published) is thrown away and the
  /// download fails, so a model is never half there. Names that are not in [files] are ignored (a service that has several file sets
  /// keeps all its checks in one place).
  Map<String, String> checksums;
  final Future<Directory> Function() _modelDirectory;
  final Future<void> Function(String url, String path, void Function(double) progress) _download;

  /// Whether the files of other publishers are fetched from a fixed commit and checked (see `model_pins.dart`); not when a test brings
  /// its own download.
  final bool _pinned;

  ModelFilesService({
    required this.files,
    required String folderName,
    this.checksums = const {},
    Future<Directory> Function()? modelDirectory,
    Future<void> Function(String, String, void Function(double))? download,
  })  : _modelDirectory = modelDirectory ??
            (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'models', folderName))),
        _pinned = download == null,
        _download = download ?? _downloadWithDio;

  HandwritingStatus _status = HandwritingStatus.notInstalled;
  @override
  HandwritingStatus get status => _status;

  @override
  double progress = 0;

  @override
  String? error;

  @override
  int get sizeMb => files.values.fold<int>(0, (sum, f) => sum + f.megabytes);

  bool get installed => _status == HandwritingStatus.installed;

  /// The folder of the files; a service with several models can say another.
  Future<Directory> directory() => _modelDirectory();

  Future<File> file(String name) async => File(p.join((await directory()).path, name));

  @override
  Future<void> load() async {
    var ready = true;
    for (final name in files.keys) {
      ready = ready && await (await file(name)).exists();
    }
    _status = ready ? HandwritingStatus.installed : HandwritingStatus.notInstalled;
    notifyListeners();
  }

  static Future<void> _downloadWithDio(String url, String path, void Function(double) progress) => downloadToFile(url, path, progress);

  @override
  Future<void> install() async {
    if (_status == HandwritingStatus.downloading) return;
    _status = HandwritingStatus.downloading;
    progress = 0;
    error = null;
    notifyListeners();
    final dir = await directory();
    try {
      await dir.create(recursive: true);
      final total = sizeMb;
      var done = 0;
      for (final entry in files.entries) {
        final target = p.join(dir.path, entry.key);
        final pin = _pinned ? pinnedDownload(entry.value.url) : (url: entry.value.url, sha256: null);
        if (pin.sha256 != null) _pins[entry.key] = pin.sha256!;
        if (keepExisting && await File(target).exists()) {
          // (a file is only in its place once all of it came: see the .part below)
          if (await _isPublished(entry.key, target)) {
            done += entry.value.megabytes;
            continue;
          }
          await File(target).delete(); // (not the published file: fetched again)
        }
        final partial = '$target.part'; // a half download must not look like a model
        final before = done;
        await _download(pin.url, partial, (v) {
          progress = (before + v * entry.value.megabytes) / total;
          notifyListeners();
        });
        if (!await _isPublished(entry.key, partial)) {
          throw _NotPublished(entry.key);
        }
        await File(partial).rename(target);
        done += entry.value.megabytes;
      }
      _status = HandwritingStatus.installed;
    } catch (e) {
      error = '$e';
      _status = HandwritingStatus.notInstalled;
      for (final f in await dir.exists() ? await dir.list().toList() : <FileSystemEntity>[]) {
        if (f.path.endsWith('.part')) await f.delete();
      }
    } finally {
      notifyListeners();
    }
  }

  /// What the files of other publishers have to hash to (from `model_pins.dart`), by the name they are kept under.
  final Map<String, String> _pins = {};

  /// True when [name] has no pinned checksum, or the file at [path] has it.
  Future<bool> _isPublished(String name, String path) async {
    final want = checksums[name] ?? _pins[name];
    if (want == null) return true;
    await ensureWebFile(path); // (in a browser a model's file may be left empty until it is needed)
    final f = File(path);
    return await f.exists() && (await sha256.bind(f.openRead()).first).toString() == want;
  }

  /// Whether [install] leaves the files that are already there alone (a service whose files change one at a time says yes).
  bool get keepExisting => false;

  /// Lets go of what is loaded in memory; [remove] does this first.
  Future<void> unload();

  @override
  Future<void> remove() async {
    await unload();
    final dir = await directory();
    if (await dir.exists()) await dir.delete(recursive: true);
    _status = HandwritingStatus.notInstalled;
    notifyListeners();
  }
}
