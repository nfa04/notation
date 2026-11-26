import 'dart:typed_data';

import 'bits.dart';
import 'byte_source.dart';
import 'pcm.dart';

/// A native FLAC file (fLaC): decoded frame by frame.
class FlacSource implements PcmSource {
  final ByteSource _source;
  @override
  final int sampleRate, channels;
  final int _bits, _total, _framesStart;

  FlacSource._(this._source, this.sampleRate, this.channels, this._bits, this._total, this._framesStart);

  static Future<FlacSource> open(ByteSource source) async {
    var pos = 4;
    int? rate, channels, bits, total;
    while (pos + 4 <= source.length) {
      final h = await source.read(pos, 4);
      final last = h[0] & 0x80 != 0;
      final type = h[0] & 0x7F;
      final size = (h[1] << 16) | (h[2] << 8) | h[3];
      if (type == 0) {
        final b = await source.read(pos + 4, 34);
        final r = BitReader(b, 10);
        rate = r.readBits(20);
        channels = r.readBits(3) + 1;
        bits = r.readBits(5) + 1;
        total = (r.readBits(4) << 32) | r.readBits(32);
      }
      pos += 4 + size;
      if (last) break;
    }
    if (rate == null || channels == null || bits == null || rate == 0) throw const AudioFormatException('This FLAC file has no stream information.');
    return FlacSource._(source, rate, channels, bits, total ?? 0, pos);
  }

  @override
  String get codec => 'flac';

  @override
  double? get seconds => _total == 0 ? null : _total / sampleRate;

  @override
  Stream<List<Float64List>> blocks() async* {
    // the frames are read from the file in pieces of 1 MB; a frame that is cut by the end of a piece waits for the next
    var fileAt = _framesStart;
    var buffer = Uint8List(0);
    var done = false;
    while (true) {
      if (buffer.length < 200000 && !done) {
        final more = await _source.read(fileAt, 1 << 20);
        fileAt += more.length;
        if (more.isEmpty) done = true;
        final joined = Uint8List(buffer.length + more.length)
          ..setAll(0, buffer)
          ..setAll(buffer.length, more);
        buffer = joined;
      }
      if (buffer.isEmpty) return;
      // frames are decoded while there is more than the longest frame in the buffer (or nothing more will come)
      final reader = BitReader(buffer);
      var consumedTo = 0;
      final out = <List<Float64List>>[];
      while (reader.bitsLeft > 64 && (done || reader.bitsLeft > 8 * 120000)) {
        final startBit = reader.position;
        try {
          final frame = _frame(reader);
          if (frame == null) {
            // not a frame header here: search the next sync code
            reader.position = startBit + 8;
            final sync = _findSync(buffer, (startBit ~/ 8) + 1);
            if (sync < 0) {
              reader.position = buffer.length * 8;
            } else {
              reader.position = sync * 8;
            }
            consumedTo = reader.position ~/ 8;
            continue;
          }
          out.add(frame);
          reader.alignToByte();
          reader.skip(16); // frame CRC
          consumedTo = reader.position ~/ 8;
        } on AudioFormatException {
          if (done) return;
          break;
        }
      }
      for (final f in out) {
        yield f;
      }
      if (consumedTo == 0 && done) return;
      buffer = Uint8List.sublistView(buffer, consumedTo);
      if (buffer.length < 16 && done) return;
    }
  }

  static int _findSync(Uint8List b, int from) {
    for (var i = from; i + 1 < b.length; i++) {
      if (b[i] == 0xFF && (b[i + 1] & 0xFE) == 0xF8) return i;
    }
    return -1;
  }

  List<Float64List>? _frame(BitReader r) {
    if (r.readBits(14) != 0x3FFE) return null;
    r.skip(1); // reserved
    r.skip(1); // fixed or variable block size
    final sizeCode = r.readBits(4);
    final rateCode = r.readBits(4);
    final channelCode = r.readBits(4);
    final bitsCode = r.readBits(3);
    r.skip(1);
    // the frame or sample number, in UTF-8 style
    final first = r.readBits(8);
    var extra = 0;
    if (first >= 0xFC) {
      extra = 5;
    } else if (first >= 0xF8) {
      extra = 4;
    } else if (first >= 0xF0) {
      extra = 3;
    } else if (first >= 0xE0) {
      extra = 2;
    } else if (first >= 0xC0) {
      extra = 1;
    }
    r.skip(extra * 8);
    final blockSize = switch (sizeCode) {
      1 => 192,
      2 || 3 || 4 || 5 => 576 << (sizeCode - 2),
      6 => r.readBits(8) + 1,
      7 => r.readBits(16) + 1,
      0 => 0,
      _ => 256 << (sizeCode - 8),
    };
    if (blockSize == 0) return null;
    if (rateCode == 12) {
      r.skip(8);
    } else if (rateCode == 13 || rateCode == 14) {
      r.skip(16);
    }
    r.skip(8); // header CRC
    final bits = switch (bitsCode) { 0 => _bits, 1 => 8, 2 => 12, 4 => 16, 5 => 20, 6 => 24, 7 => 32, _ => -1 };
    if (bits < 0) throw const AudioFormatException('This FLAC file has an invalid sample size.');
    int count;
    int assignment;
    if (channelCode < 8) {
      count = channelCode + 1;
      assignment = 0;
    } else if (channelCode <= 10) {
      count = 2;
      assignment = channelCode - 7; // 1 left+side, 2 side+right, 3 mid+side
    } else {
      throw const AudioFormatException('This FLAC file has an invalid channel assignment.');
    }
    final raw = <Int32List>[];
    for (var c = 0; c < count; c++) {
      var b = bits;
      if ((assignment == 1 && c == 1) || (assignment == 2 && c == 0) || (assignment == 3 && c == 1)) b++;
      raw.add(_subframe(r, blockSize, b));
    }
    if (assignment == 1) {
      for (var i = 0; i < blockSize; i++) {
        raw[1][i] = raw[0][i] - raw[1][i];
      }
    } else if (assignment == 2) {
      for (var i = 0; i < blockSize; i++) {
        raw[0][i] = raw[0][i] + raw[1][i];
      }
    } else if (assignment == 3) {
      for (var i = 0; i < blockSize; i++) {
        final side = raw[1][i];
        final mid = (raw[0][i] << 1) | (side & 1);
        raw[0][i] = (mid + side) >> 1;
        raw[1][i] = (mid - side) >> 1;
      }
    }
    final scale = 1.0 / (1 << (bits - 1));
    return [
      for (final c in raw) Float64List.fromList([for (var i = 0; i < blockSize; i++) c[i] * scale])
    ];
  }

  Int32List _subframe(BitReader r, int n, int bits) {
    r.skip(1);
    final type = r.readBits(6);
    var wasted = 0;
    if (r.readBit() == 1) {
      wasted = r.readUnary() + 1;
    }
    final b = bits - wasted;
    final out = Int32List(n);
    if (type == 0) {
      final v = r.readSigned(b);
      out.fillRange(0, n, v);
    } else if (type == 1) {
      for (var i = 0; i < n; i++) {
        out[i] = r.readSigned(b);
      }
    } else if (type >= 8 && type <= 12) {
      final order = type - 8;
      for (var i = 0; i < order; i++) {
        out[i] = r.readSigned(b);
      }
      _residual(r, n, order, out);
      const fixed = [
        <int>[],
        [1],
        [2, -1],
        [3, -3, 1],
        [4, -6, 4, -1],
      ];
      final co = fixed[order];
      for (var i = order; i < n; i++) {
        var p = 0;
        for (var k = 0; k < order; k++) {
          p += co[k] * out[i - 1 - k];
        }
        out[i] += p;
      }
    } else if (type >= 32) {
      final order = type - 31;
      for (var i = 0; i < order; i++) {
        out[i] = r.readSigned(b);
      }
      final precision = r.readBits(4) + 1;
      final shift = r.readSigned(5);
      final co = [for (var i = 0; i < order; i++) r.readSigned(precision)];
      _residual(r, n, order, out);
      for (var i = order; i < n; i++) {
        var p = 0;
        for (var k = 0; k < order; k++) {
          p += co[k] * out[i - 1 - k];
        }
        out[i] += shift >= 0 ? p >> shift : p << -shift;
      }
    } else {
      throw const AudioFormatException('This FLAC file has an invalid subframe.');
    }
    if (wasted > 0) {
      for (var i = 0; i < n; i++) {
        out[i] <<= wasted;
      }
    }
    return out;
  }

  void _residual(BitReader r, int n, int order, Int32List out) {
    final method = r.readBits(2);
    if (method > 1) throw const AudioFormatException('This FLAC file has an invalid residual.');
    final partitionOrder = r.readBits(4);
    final parameterBits = method == 0 ? 4 : 5;
    final escape = method == 0 ? 15 : 31;
    final partitions = 1 << partitionOrder;
    var i = order;
    for (var p = 0; p < partitions; p++) {
      final count = (n >> partitionOrder) - (p == 0 ? order : 0);
      final parameter = r.readBits(parameterBits);
      if (parameter == escape) {
        final bits = r.readBits(5);
        for (var k = 0; k < count; k++) {
          out[i++] = bits == 0 ? 0 : r.readSigned(bits);
        }
      } else {
        for (var k = 0; k < count; k++) {
          var q = 0;
          while (r.readBit() == 0) {
            q++;
          }
          final v = (q << parameter) | r.readBits(parameter);
          out[i++] = (v & 1) != 0 ? -((v + 1) >> 1) : v >> 1;
        }
      }
    }
  }
}
