import 'dart:typed_data';

/// Where the bytes of a media file come from: read at any place, so that a big video is never held in memory as a whole.
abstract class ByteSource {
  int get length;

  /// [count] bytes from [offset] on (fewer at the end of the file).
  Future<Uint8List> read(int offset, int count);
  Future<void> close();
}

/// A [ByteSource] over bytes already in memory (the web, tests, small files).
class MemoryByteSource implements ByteSource {
  final Uint8List bytes;
  MemoryByteSource(this.bytes);

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (offset >= bytes.length || offset < 0) return Uint8List(0);
    final end = offset + count > bytes.length ? bytes.length : offset + count;
    return Uint8List.sublistView(bytes, offset, end);
  }

  @override
  Future<void> close() async {}
}
