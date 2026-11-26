import 'dart:typed_data';

/// A file or stream the app cannot read: the message says why, in a plain sentence for the person.
class AudioFormatException implements Exception {
  final String message;
  const AudioFormatException(this.message);
  @override
  String toString() => message;
}

/// Reads bits from bytes, the most significant bit of each byte first (the order of AAC, MP3, FLAC, MPEG and most others).
class BitReader {
  final Uint8List data;
  /// Where the next bit is, counted in bits from the start of [data].
  int position;
  final int _end;

  BitReader(this.data, [int start = 0, int? end])
      : position = start * 8,
        _end = (end ?? data.length) * 8;

  int get bitsLeft => _end - position;

  int readBit() {
    if (position >= _end) throw const AudioFormatException('The audio ends in the middle of a frame.');
    final b = (data[position >> 3] >> (7 - (position & 7))) & 1;
    position++;
    return b;
  }

  bool readBool() => readBit() == 1;

  /// [n] bits (0..32) as an unsigned number.
  int readBits(int n) {
    if (n == 0) return 0;
    if (position + n > _end) throw const AudioFormatException('The audio ends in the middle of a frame.');
    var v = 0;
    var left = n;
    while (left > 0) {
      final byte = data[position >> 3];
      final inByte = 8 - (position & 7);
      final take = left < inByte ? left : inByte;
      v = (v << take) | ((byte >> (inByte - take)) & ((1 << take) - 1));
      position += take;
      left -= take;
    }
    return v;
  }

  /// [n] bits as a two's complement number.
  int readSigned(int n) {
    final v = readBits(n);
    return v >= (1 << (n - 1)) ? v - (1 << n) : v;
  }

  void skip(int n) {
    if (position + n > _end) throw const AudioFormatException('The audio ends in the middle of a frame.');
    position += n;
  }

  void alignToByte() => position = (position + 7) & ~7;

  /// The number of 1 bits before the next 0 bit (the 0 is read too).
  int readUnary() {
    var n = 0;
    while (readBit() == 1) {
      n++;
    }
    return n;
  }
}

/// A table of variable length codes: [codes] and [lengths] give the code (as a number) and its length in bits for each symbol;
/// [read] reads one code and gives the symbol's index. The codes are put in a binary tree.
class Vlc {
  // node n has its children at _tree[2n] and _tree[2n+1]: a value >= 0 is another node, a value < 0 is the symbol -(value+1), 0 is "none"
  // (the root is node 0, so no node points to 0)
  final List<int> _tree = [0, 0];

  Vlc(List<int> codes, List<int> lengths) {
    assert(codes.length == lengths.length);
    for (var s = 0; s < codes.length; s++) {
      final len = lengths[s];
      if (len == 0) continue;
      var node = 0;
      for (var i = len - 1; i >= 0; i--) {
        final bit = (codes[s] >> i) & 1;
        final slot = node * 2 + bit;
        if (i == 0) {
          _tree[slot] = -(s + 1);
        } else {
          var next = _tree[slot];
          if (next <= 0) {
            next = _tree.length ~/ 2;
            _tree.addAll([0, 0]);
            _tree[slot] = next;
          }
          node = next;
        }
      }
    }
  }

  int read(BitReader r) {
    var node = 0;
    while (true) {
      final v = _tree[node * 2 + r.readBit()];
      if (v < 0) return -v - 1;
      if (v == 0) throw const AudioFormatException('The audio has an invalid code in it.');
      node = v;
    }
  }
}
