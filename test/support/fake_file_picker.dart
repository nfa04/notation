import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A file on disk, as a picker hands it over.
base class FakePickedFile extends PlatformFile {
  FakePickedFile(this._path);
  final String _path;

  @override
  String get name => _path.split(Platform.pathSeparator).last;

  @override
  Uri get uri => Uri.file(_path);

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => File(_path).lengthSync();

  @override
  Future<int?> length() async => File(_path).length();

  @override
  Future<Uint8List> readAsBytes() => File(_path).readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() => File(_path).openRead().map(Uint8List.fromList);
}

/// Stands in for the system's file dialogs: it picks [pick] (files that exist) and saves to [savePath], writing the bytes there like
/// the real picker does. Install it with `FilePickerPlatform.instance = FakeFilePicker(...)`.
class FakeFilePicker extends FilePickerPlatform with MockPlatformInterfaceMixin {
  FakeFilePicker({this.pick = const [], this.savePath});

  final List<String> pick;
  final String? savePath;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      pick.isEmpty ? null : FakePickedFile(pick.first);

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      [for (final path in pick) FakePickedFile(path)];

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    final path = savePath;
    if (path == null) return null;
    await File(path).writeAsBytes(bytes);
    return Uri.file(path);
  }
}
