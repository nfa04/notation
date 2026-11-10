import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

/// [packed] (zlib) inflated by the system's zlib, giving up with a [FormatException] as soon as more than [limit] bytes have come out
/// (they are counted as they are produced, so the memory is never taken).
Uint8List inflateCapped(Uint8List packed, int limit) {
  final out = BytesBuilder(copy: false);
  final sink = ZLibDecoder().startChunkedConversion(_Capped(out, limit));
  try {
    sink.add(packed);
    sink.close();
  } on FormatException {
    rethrow;
  } on Exception catch (e) {
    throw FormatException('not a packed message: $e'); // (the decoder says a damaged stream with its own exceptions)
  }
  return out.takeBytes();
}

class _Capped implements Sink<List<int>> {
  final BytesBuilder _out;
  final int _limit;
  _Capped(this._out, this._limit);

  @override
  void add(List<int> chunk) {
    if (_out.length + chunk.length > _limit) throw const FormatException('the message unpacks to too much');
    _out.add(chunk);
  }

  @override
  void close() {}
}
