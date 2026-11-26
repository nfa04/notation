import 'dart:typed_data';

import '../bits.dart';
import 'dart:math' as math;

import 'celt_decoder.dart';
import 'range_decoder.dart';
import 'silk_decoder.dart';

/// The parts of an Opus packet (RFC 6716 section 3): the frames in it and what the table of contents says about them.
class OpusPacket {
  final int config;
  final bool stereo;
  final List<(int, int)> frames; // (offset, length) in the packet
  OpusPacket(this.config, this.stereo, this.frames);

  /// 0 SILK, 1 hybrid, 2 CELT
  int get mode => config < 12 ? 0 : (config < 16 ? 1 : 2);

  /// The samples at 48 kHz of one frame.
  int get frameSamples {
    if (config < 12) return const [480, 960, 1920, 2880][config & 3];
    if (config < 16) return (config & 1) == 0 ? 480 : 960;
    return const [120, 240, 480, 960][config & 3];
  }

  /// 0 narrow, 1 medium, 2 wide, 3 super wide, 4 full band
  int get bandwidth {
    if (config < 12) return config >> 2;
    if (config < 16) return config < 14 ? 3 : 4;
    final b = (config - 16) >> 2;
    return b == 0 ? 0 : b + 1;
  }

  static OpusPacket parse(Uint8List p) {
    if (p.isEmpty) throw const AudioFormatException('An Opus packet is empty.');
    final toc = p[0];
    final code = toc & 3;
    var pos = 1;
    final frames = <(int, int)>[];
    int size() {
      if (pos >= p.length) throw const AudioFormatException('An Opus packet is cut short.');
      final b = p[pos++];
      if (b < 252) return b;
      if (pos >= p.length) throw const AudioFormatException('An Opus packet is cut short.');
      return 4 * p[pos++] + b;
    }

    switch (code) {
      case 0:
        frames.add((1, p.length - 1));
      case 1:
        final each = (p.length - 1) ~/ 2;
        frames.add((1, each));
        frames.add((1 + each, each));
      case 2:
        final first = size();
        if (pos + first > p.length) throw const AudioFormatException('An Opus packet is cut short.');
        frames.add((pos, first));
        frames.add((pos + first, p.length - pos - first));
      default:
        if (pos >= p.length) throw const AudioFormatException('An Opus packet is cut short.');
        final b = p[pos++];
        final count = b & 0x3F;
        final vbr = (b & 0x80) != 0;
        var pad = 0;
        if ((b & 0x40) != 0) {
          while (pos < p.length) {
            final v = p[pos++];
            if (v == 255) {
              pad += 254;
            } else {
              pad += v;
              break;
            }
          }
        }
        if (count == 0) throw const AudioFormatException('An Opus packet has no frames.');
        final end = p.length - pad;
        if (vbr) {
          final sizes = <int>[];
          for (var i = 0; i < count - 1; i++) {
            sizes.add(size());
          }
          var at = pos;
          for (final s in sizes) {
            frames.add((at, s));
            at += s;
          }
          frames.add((at, end - at));
        } else {
          final each = (end - pos) ~/ count;
          for (var i = 0; i < count; i++) {
            frames.add((pos + i * each, each));
          }
        }
    }
    for (final f in frames) {
      if (f.$2 < 0 || f.$1 + f.$2 > p.length) throw const AudioFormatException('An Opus packet is cut short.');
    }
    return OpusPacket(toc >> 3, (toc & 4) != 0, frames);
  }
}

/// Opus (RFC 6716) to samples at 48 kHz, packet by packet (a port of libopus' `opus_decode_frame` without the repair of lost packets
/// and without the short cross fades at a change of mode).
class OpusDecoder {
  final int channels;
  late final CeltDecoder celt = CeltDecoder(channels);
  final SilkDecoder _silk = SilkDecoder();
  int _prevMode = 0; // 0 nothing yet, 1 SILK, 2 hybrid, 3 CELT
  bool _prevRedundancy = false;
  OpusDecoder(this.channels);

  /// The samples (one list per channel) of a packet. A packet that cannot be read throws an [AudioFormatException].
  List<Float64List> decodePacket(Uint8List data) {
    final packet = OpusPacket.parse(data);
    final parts = <List<Float64List>>[];
    for (final (offset, length) in packet.frames) {
      try {
        parts.add(_frame(packet, data, offset, length));
      } on RangeError {
        throw const AudioFormatException('An Opus frame is damaged.');
      }
    }
    return _join(parts);
  }

  static const _celtEnds = [13, 17, 17, 19, 21];

  List<Float64List> _frame(OpusPacket packet, Uint8List data, int offset, int length) {
    final n = packet.frameSamples;
    final streamChannels = packet.stereo ? 2 : 1;
    final mode = packet.mode == 0 ? 1 : (packet.mode == 1 ? 2 : 3);
    final bandwidth = packet.bandwidth;
    if (length <= 1) {
      // an empty frame (discontinuous transmission): silence
      _prevMode = mode;
      return [for (var c = 0; c < channels; c++) Float64List(n)];
    }
    final rc = RangeDecoder(Uint8List.sublistView(data, offset, offset + length));
    var len = length;
    List<Float64List>? silkPcm;
    if (mode != 3) {
      if (_prevMode == 3) _silk.reset();
      final payloadMs = math.max(10, 1000 * n ~/ 48000);
      final rate = mode == 1 ? const [8000, 12000, 16000][math.min(bandwidth, 2)] : 16000;
      final pcm = [for (var c = 0; c < channels; c++) Int16List(n)];
      var done = 0;
      while (done < n) {
        final out = _silk.decode(rc, apiRate: 48000, nApi: channels, nInternal: streamChannels, internalRate: rate, payloadMs: payloadMs, newPacket: done == 0);
        for (var c = 0; c < channels; c++) {
          pcm[c].setRange(done, done + out[c].length, out[c]);
        }
        done += out[0].length;
      }
      silkPcm = [
        for (final c in pcm) Float64List.fromList([for (final v in c) v / 32768])
      ];
    }
    var redundancy = false, celtToSilk = false;
    var redundancyBytes = 0;
    if (mode != 3 && rc.tell() + 17 + (mode == 2 ? 20 : 0) <= 8 * len) {
      redundancy = mode == 2 ? rc.bitLogp(12) == 1 : true;
      if (redundancy) {
        celtToSilk = rc.bitLogp(1) == 1;
        redundancyBytes = mode == 2 ? rc.uint(256) + 2 : len - ((rc.tell() + 7) >> 3);
        len -= redundancyBytes;
        if (len * 8 < rc.tell()) {
          len = 0;
          redundancyBytes = 0;
          redundancy = false;
        }
        rc.storage -= redundancyBytes;
      }
    }
    if (bandwidth >= 0) celt.end = _celtEnds[bandwidth];
    List<Float64List> pcm;
    if (redundancy && celtToSilk) {
      celt.start = 0;
      celt.decode(data, offset + len, redundancyBytes, null, 120, streamChannels);
    }
    celt.start = mode != 3 ? 17 : 0;
    if (mode != 1) {
      if (mode != _prevMode && _prevMode > 0 && !_prevRedundancy) celt.reset();
      celt.start = mode != 3 ? 17 : 0;
      if (bandwidth >= 0) celt.end = _celtEnds[bandwidth];
      pcm = celt.decode(data, offset, len, rc, math.min(960, n), streamChannels);
    } else {
      pcm = [for (var c = 0; c < channels; c++) Float64List(n)];
      if (_prevMode == 2 && !(redundancy && celtToSilk && _prevRedundancy)) {
        celt.start = 0;
        final tail = celt.decode(Uint8List.fromList(const [0xFF, 0xFF]), 0, 2, null, 120, streamChannels);
        for (var c = 0; c < channels; c++) {
          pcm[c].setRange(0, 120, tail[c]);
        }
      }
    }
    if (silkPcm != null) {
      for (var c = 0; c < channels; c++) {
        final a = pcm[c], b = silkPcm[c];
        for (var i = 0; i < n; i++) {
          a[i] += b[i];
        }
      }
    }
    if (redundancy && !celtToSilk) {
      celt.reset();
      celt.start = 0;
      celt.decode(data, offset + len, redundancyBytes, null, 120, streamChannels);
    }
    _prevMode = mode;
    _prevRedundancy = redundancy && !celtToSilk;
    return pcm;
  }

  List<Float64List> _join(List<List<Float64List>> parts) {
    if (parts.length == 1) return parts.first;
    return [
      for (var c = 0; c < channels; c++)
        () {
          var total = 0;
          for (final p in parts) {
            total += p[c].length;
          }
          final one = Float64List(total);
          var at = 0;
          for (final p in parts) {
            one.setAll(at, p[c]);
            at += p[c].length;
          }
          return one;
        }()
    ];
  }
}
