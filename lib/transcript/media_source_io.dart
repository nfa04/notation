import 'dart:io';
import 'dart:typed_data';

import 'package:pure_audio/pure_audio.dart';

/// A file on disk, read in pieces (a video of many gigabytes is never loaded as a whole).
Future<ByteSource> openFileSource(String path) async {
  final file = await File(path).open();
  return _FileSource(file, await file.length());
}

class _FileSource implements ByteSource {
  final RandomAccessFile _file;
  @override
  final int length;
  int _at = -1;
  Uint8List _cache = Uint8List(0);
  _FileSource(this._file, this.length);

  @override
  Future<Uint8List> read(int offset, int count) async {
    // small reads (the parts of a container) come from a cache of 256 KB
    if (count < 64 * 1024) {
      if (_at < 0 || offset < _at || offset + count > _at + _cache.length) {
        await _file.setPosition(offset);
        _cache = await _file.read(256 * 1024);
        _at = offset;
      }
      final from = offset - _at;
      final to = (from + count).clamp(0, _cache.length);
      return Uint8List.sublistView(_cache, from.clamp(0, to), to);
    }
    await _file.setPosition(offset);
    return _file.read(count);
  }

  @override
  Future<void> close() => _file.close();
}
