import 'dart:typed_data';

import 'package:archive/archive.dart';

/// [packed] (zlib) inflated, giving up with a [FormatException] as soon as more than [limit] bytes have come out (they are counted as
/// they are produced, so the memory is never taken). Pure Dart, so that it works on the web too (dart:io has no zlib there). The
/// Adler-32 at the end is not checked: the message was sealed, so it is the one that was sent.
Uint8List inflateCapped(Uint8List packed, int limit) {
  // the zlib header: deflate (method 8), a check that makes the two bytes a multiple of 31, no preset dictionary
  if (packed.length < 2 || packed[0] & 0x0F != 8 || ((packed[0] << 8) | packed[1]) % 31 != 0 || packed[1] & 0x20 != 0) {
    throw const FormatException('not a packed message');
  }
  final out = _Capped(limit);
  try {
    Inflate(Uint8List.sublistView(packed, 2), output: out);
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('not a packed message: $e'); // (the decoder says a damaged stream with its own exceptions)
  }
  return Uint8List.fromList(out.getBytes());
}

/// An output that refuses to grow past a limit.
class _Capped extends OutputMemoryStream {
  final int _limit;
  _Capped(this._limit);

  void _room(int more) {
    if (length + more > _limit) throw const FormatException('the message unpacks to too much');
  }

  @override
  void writeByte(int value) {
    _room(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _room(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _room(stream.length);
    super.writeStream(stream);
  }
}
