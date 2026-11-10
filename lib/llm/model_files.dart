import 'dart:io';

import 'download.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ink/ink_recognizer.dart';

/// A model that is a few files in one folder, downloaded on request, with a
/// status and progress the Settings screen shows.
abstract class ModelFilesService extends DownloadableModel {
  /// File name -> where it comes from and about how big it is.
  Map<String, ({String url, int megabytes})> files;
  final Future<Directory> Function() _modelDirectory;
  final Future<void> Function(String url, String path, void Function(double) progress) _download;

  ModelFilesService({
    required this.files,
    required String folderName,
    Future<Directory> Function()? modelDirectory,
    Future<void> Function(String, String, void Function(double))? download,
  })  : _modelDirectory = modelDirectory ??
            (() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'models', folderName))),
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
        final partial = '$target.part'; // a half download must not look like a model
        final before = done;
        await _download(entry.value.url, partial, (v) {
          progress = (before + v * entry.value.megabytes) / total;
          notifyListeners();
        });
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
