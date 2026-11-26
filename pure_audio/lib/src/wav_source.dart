import 'dart:typed_data';

import 'bits.dart';
import 'byte_source.dart';
import 'pcm.dart';

/// A RIFF/WAVE file with PCM (8, 16, 24, 32 bit) or float (32, 64 bit) samples.
class WavSource implements PcmSource {
  final ByteSource _source;
  @override
  final int sampleRate, channels;
  final int _bits, _dataStart, _dataLength;
  final bool _float;
  final int _law;

  WavSource._(this._source, this.sampleRate, this.channels, this._bits, this._float, this._law, this._dataStart, this._dataLength);

  static Future<WavSource> open(ByteSource source) async {
    var pos = 12;
    int? rate, channels, bits;
    var isFloat = false;
    var law = 0; // 6: A-law, 7: mu-law
    while (pos + 8 <= source.length) {
      final head = await source.read(pos, 8);
      if (head.length < 8) break;
      final d = ByteData.sublistView(head);
      final id = String.fromCharCodes(head.sublist(0, 4));
      final size = d.getUint32(4, Endian.little);
      if (id == 'fmt ') {
        final f = await source.read(pos + 8, size < 40 ? size : 40);
        final fd = ByteData.sublistView(f);
        var tag = fd.getUint16(0, Endian.little);
        channels = fd.getUint16(2, Endian.little);
        rate = fd.getUint32(4, Endian.little);
        bits = fd.getUint16(14, Endian.little);
        if (tag == 0xFFFE && f.length >= 26) tag = fd.getUint16(24, Endian.little);
        if (tag == 3) {
          isFloat = true;
        } else if (tag == 6 || tag == 7) {
          law = tag;
        } else if (tag != 1) {
          throw AudioFormatException('This WAV file is compressed (format $tag); only plain PCM is supported.');
        }
      } else if (id == 'data') {
        if (rate == null || channels == null || bits == null) throw const AudioFormatException('This WAV file has no format description.');
        if (channels < 1) throw const AudioFormatException('This WAV file has no channels.');
        if (law != 0 ? bits != 8 : !(isFloat ? (bits == 32 || bits == 64) : (bits == 8 || bits == 16 || bits == 24 || bits == 32))) {
          throw AudioFormatException('This WAV file has $bits bits per sample, which is not supported.');
        }
        var length = size;
        if (pos + 8 + length > source.length || length == 0xFFFFFFFF) length = source.length - pos - 8;
        return WavSource._(source, rate, channels, bits, isFloat, law, pos + 8, length);
      }
      pos += 8 + size + (size & 1);
    }
    throw const AudioFormatException('This WAV file has no sound in it.');
  }

  @override
  String get codec => 'pcm';

  @override
  double? get seconds => _dataLength / (channels * _bits ~/ 8) / sampleRate;

  @override
  Stream<List<Float64List>> blocks() async* {
    final frameBytes = channels * _bits ~/ 8;
    final framesPerBlock = 16384;
    var at = 0;
    while (at + frameBytes <= _dataLength) {
      final want = (framesPerBlock * frameBytes).clamp(0, _dataLength - at);
      final bytes = await _source.read(_dataStart + at, want);
      final frames = bytes.length ~/ frameBytes;
      if (frames == 0) break;
      final d = ByteData.sublistView(bytes);
      final out = [for (var c = 0; c < channels; c++) Float64List(frames)];
      final width = _bits ~/ 8;
      for (var f = 0; f < frames; f++) {
        for (var c = 0; c < channels; c++) {
          final o = f * frameBytes + c * width;
          double v;
          if (_float) {
            v = _bits == 32 ? d.getFloat32(o, Endian.little) : d.getFloat64(o, Endian.little);
          } else if (_law == 7) {
            v = _muLaw(bytes[o]) / 32768;
          } else if (_law == 6) {
            v = _aLaw(bytes[o]) / 32768;
          } else if (_bits == 8) {
            v = (bytes[o] - 128) / 128;
          } else if (_bits == 16) {
            v = d.getInt16(o, Endian.little) / 32768;
          } else if (_bits == 24) {
            var n = bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16);
            if (n >= 0x800000) n -= 0x1000000;
            v = n / 8388608;
          } else {
            v = d.getInt32(o, Endian.little) / 2147483648;
          }
          out[c][f] = v;
        }
      }
      yield out;
      at += frames * frameBytes;
    }
  }
}

int _muLaw(int byte) {
  final u = ~byte & 0xFF;
  final t = (((u & 0x0F) << 3) + 0x84) << ((u & 0x70) >> 4);
  return (u & 0x80) != 0 ? 0x84 - t : t - 0x84;
}

int _aLaw(int byte) {
  final a = byte ^ 0x55;
  var t = (a & 0x0F) << 4;
  final seg = (a & 0x70) >> 4;
  switch (seg) {
    case 0:
      t += 8;
    case 1:
      t += 0x108;
    default:
      t += 0x108;
      t <<= seg - 1;
  }
  return (a & 0x80) != 0 ? t : -t;
}
