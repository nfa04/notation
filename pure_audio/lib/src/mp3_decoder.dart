import 'dart:math' as math;
import 'dart:typed_data';

import 'bits.dart';
import 'byte_source.dart';
import 'mp3_tables.dart';
import 'pcm.dart';

// An MPEG audio Layer III decoder (MP3; MPEG-1, 2 and 2.5) in plain Dart. The structure follows the Layer III decoder of the Symphonia
// project (MPL-2.0), written again here. Not supported: Layers I and II, and intensity stereo (a band coded that way comes out with
// all of its sound on the left, which does not matter for speech that is mixed down to one channel).

class Mp3Header {
  final int version; // 1, 2 or 25 (2.5)
  final int layer;
  final int bitrate; // bits per second
  final int sampleRate;
  final int rateIndex; // 0..8, into the band tables
  final int channelMode; // 0 stereo, 1 joint stereo, 2 dual channel, 3 mono
  final int modeExtension;
  final bool hasCrc;
  final int frameSize; // in bytes, with the header

  const Mp3Header(this.version, this.layer, this.bitrate, this.sampleRate, this.rateIndex, this.channelMode, this.modeExtension, this.hasCrc, this.frameSize);

  int get channels => channelMode == 3 ? 1 : 2;
  bool get isMpeg1 => version == 1;
  int get granules => isMpeg1 ? 2 : 1;
  int get sideInfoLength => isMpeg1 ? (channels == 1 ? 17 : 32) : (channels == 1 ? 9 : 17);
  bool get intensityStereo => channelMode == 1 && (modeExtension & 1) != 0;
  bool get midSide => channelMode == 1 && (modeExtension & 2) != 0;
  int get samplesPerFrame => 576 * granules;

  /// The header at [b] from [offset] on, or null when it is not a valid Layer I/II/III header.
  static Mp3Header? parse(Uint8List b, int offset) {
    if (offset + 4 > b.length) return null;
    if (b[offset] != 0xFF || (b[offset + 1] & 0xE0) != 0xE0) return null;
    final versionBits = (b[offset + 1] >> 3) & 3;
    final layerBits = (b[offset + 1] >> 1) & 3;
    if (versionBits == 1 || layerBits == 0) return null;
    final version = versionBits == 3 ? 1 : (versionBits == 2 ? 2 : 25);
    final layer = 4 - layerBits;
    final bitrateIndex = b[offset + 2] >> 4;
    final rateBits = (b[offset + 2] >> 2) & 3;
    if (bitrateIndex == 0 || bitrateIndex == 15 || rateBits == 3) return null;
    const v1l3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
    const v1l2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384];
    const v1l1 = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448];
    const v2l3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
    const v2l1 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256];
    final table = version == 1 ? (layer == 3 ? v1l3 : layer == 2 ? v1l2 : v1l1) : (layer == 1 ? v2l1 : v2l3);
    final bitrate = table[bitrateIndex] * 1000;
    const rates = [
      [44100, 48000, 32000],
      [22050, 24000, 16000],
      [11025, 12000, 8000],
    ];
    final group = version == 1 ? 0 : (version == 2 ? 1 : 2);
    final sampleRate = rates[group][rateBits];
    final padding = (b[offset + 2] >> 1) & 1;
    final mode = b[offset + 3] >> 6;
    final ext = (b[offset + 3] >> 4) & 3;
    final size = layer == 1
        ? (12 * bitrate ~/ sampleRate + padding) * 4
        : (layer == 3 && version != 1 ? 72 : 144) * bitrate ~/ sampleRate + padding;
    return Mp3Header(version, layer, bitrate, sampleRate, group * 3 + rateBits, mode, ext, (b[offset + 1] & 1) == 0, size);
  }
}

final Map<int, Vlc> _bigValueTables = {for (final t in mp3HuffmanCodes.keys) t: Vlc(mp3HuffmanCodes[t]!, mp3HuffmanLengths[t]!)};
final List<Vlc> _quadTables = [for (var i = 0; i < 2; i++) Vlc(mp3QuadCodes[i], mp3QuadLengths[i])];
final Float64List _pow43 = Float64List.fromList([for (var i = 0; i < 8207; i++) math.pow(i, 4 / 3).toDouble()]);

const _slen = [(0, 0), (0, 1), (0, 2), (0, 3), (3, 0), (1, 1), (1, 2), (1, 3), (2, 1), (2, 2), (2, 3), (3, 1), (3, 2), (3, 3), (4, 2), (4, 3)];
const _nsfb = [
  [[7, 7, 7, 0], [12, 12, 12, 0], [6, 15, 12, 0]],
  [[6, 6, 6, 3], [12, 9, 9, 6], [6, 12, 9, 6]],
  [[8, 8, 5, 0], [15, 12, 9, 0], [6, 18, 9, 0]],
  [[6, 5, 5, 5], [9, 9, 9, 9], [6, 9, 9, 9]],
  [[6, 5, 7, 3], [9, 9, 12, 6], [6, 9, 12, 6]],
  [[11, 10, 0, 0], [18, 18, 0, 0], [15, 18, 0, 0]],
];
const _preEmphasis = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0];
const _mixedLong = [8, 8, 8, 6, 6, 6, 6, 6, 3]; // the long bands of a mixed block, by rate index

/// One channel of one granule: what the side information says about it.
class _Granule {
  int part23 = 0, bigValues = 0, globalGain = 0, scalefacCompress = 0;
  int blockType = 0; // 0 normal, 1 start, 2 short, 3 stop
  bool mixed = false;
  final subblockGain = [0, 0, 0];
  final tableSelect = [0, 0, 0];
  int region1 = 0, region2 = 0;
  bool preflag = false, scalefacScale = false;
  int count1Table = 0;
  final scalefacs = Uint8List(39 + 3);
}

final List<Float64List> _imdctWindows = () {
  final w = [for (var i = 0; i < 4; i++) Float64List(36)];
  for (var i = 0; i < 36; i++) {
    w[0][i] = math.sin(math.pi / 36 * (i + 0.5));
  }
  for (var i = 0; i < 18; i++) {
    w[1][i] = math.sin(math.pi / 36 * (i + 0.5));
  }
  for (var i = 18; i < 24; i++) {
    w[1][i] = 1;
  }
  for (var i = 24; i < 30; i++) {
    w[1][i] = math.sin(math.pi / 12 * (i - 18 + 0.5));
  }
  for (var i = 0; i < 12; i++) {
    w[2][i] = math.sin(math.pi / 12 * (i + 0.5));
  }
  for (var i = 6; i < 12; i++) {
    w[3][i] = math.sin(math.pi / 12 * (i - 6 + 0.5));
  }
  for (var i = 12; i < 18; i++) {
    w[3][i] = 1;
  }
  for (var i = 18; i < 36; i++) {
    w[3][i] = math.sin(math.pi / 36 * (i + 0.5));
  }
  return w;
}();

final Float64List _cos36 = Float64List.fromList([for (var i = 0; i < 36; i++) for (var k = 0; k < 18; k++) math.cos(math.pi / 72 * (2 * i + 1 + 18) * (2 * k + 1))]);
final Float64List _cos12 = Float64List.fromList([for (var i = 0; i < 12; i++) for (var k = 0; k < 6; k++) math.cos(math.pi / 24 * (2 * i + 1 + 6) * (2 * k + 1))]);
final Float64List _cos32 = Float64List.fromList([for (var m = 0; m < 32; m++) for (var k = 0; k < 32; k++) math.cos(m * (2 * k + 1) * math.pi / 64)]);
final List<double> _cs = [for (final c in const [-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037]) 1 / math.sqrt(1 + c * c)];
final List<double> _ca = [for (final c in const [-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037]) c / math.sqrt(1 + c * c)];

class Mp3Decoder {
  // the bit reservoir
  final Uint8List _reservoir = Uint8List(4096);
  int _resLen = 0, _resConsumed = 0;
  final _samples = [for (var g = 0; g < 2; g++) [Float64List(576), Float64List(576)]];
  final _overlap = [Float64List(32 * 18), Float64List(32 * 18)];
  final _v = [Float64List(1024), Float64List(1024)];
  final _vOffset = [0, 0];
  final _scfsi = [List<bool>.filled(4, false), List<bool>.filled(4, false)];

  /// Decodes one whole frame (header included) of Layer III: a list with one list of samples (-1..1) per channel.
  List<Float64List> decodeFrame(Uint8List frame, Mp3Header header) {
    if (header.layer != 3) throw AudioFormatException('This MP3 file uses MPEG Layer ${header.layer}, which is not supported (only Layer III).');
    final ch = header.channels;
    final out = [for (var c = 0; c < ch; c++) Float64List(576 * header.granules)];
    var at = 4 + (header.hasCrc ? 2 : 0);
    final bs = BitReader(frame, at);
    // side information
    final granules = [for (var g = 0; g < 2; g++) [_Granule(), _Granule()]];
    int mainDataBegin;
    if (header.isMpeg1) {
      mainDataBegin = bs.readBits(9);
      bs.skip(ch == 1 ? 5 : 3);
      for (var c = 0; c < ch; c++) {
        for (var b = 0; b < 4; b++) {
          _scfsi[c][b] = bs.readBool();
        }
      }
    } else {
      mainDataBegin = bs.readBits(8);
      bs.skip(ch == 1 ? 1 : 2);
    }
    for (var g = 0; g < header.granules; g++) {
      for (var c = 0; c < ch; c++) {
        _readGranule(bs, granules[g][c], header);
      }
    }
    at += header.sideInfoLength;
    // the bit reservoir: this frame's main data goes after what earlier frames left that this one needs
    final mainData = Uint8List.sublistView(frame, at);
    final underflow = _fill(mainData, mainDataBegin);
    final consumed = _readMainData(header, underflow * 8, granules);
    _resConsumed = math.min(_resLen, _resConsumed + consumed);
    for (var g = 0; g < header.granules; g++) {
      final gr = granules[g];
      for (var c = 0; c < ch; c++) {
        _requantize(header, gr[c], _samples[g][c]);
      }
      if (ch == 2 && header.midSide) {
        final l = _samples[g][0], r = _samples[g][1];
        final k = math.sqrt1_2;
        for (var i = 0; i < 576; i++) {
          final m = l[i], s = r[i];
          l[i] = (m + s) * k;
          r[i] = (m - s) * k;
        }
      }
      for (var c = 0; c < ch; c++) {
        final s = _samples[g][c];
        _reorder(header, gr[c], s);
        _antialias(gr[c], s);
        _hybrid(gr[c], _overlap[c], s);
        _frequencyInversion(s);
        _synthesize(c, s, out[c], g * 576);
      }
    }
    return out;
  }

  int _fill(Uint8List data, int begin) {
    final end = begin + data.length;
    if (end > _reservoir.length) throw const AudioFormatException('This MP3 frame asks for more reservoir than it can have.');
    final unread = _resLen - _resConsumed;
    int underflow;
    if (begin <= unread) {
      _reservoir.setRange(0, begin, _reservoir.sublist(_resLen - begin, _resLen));
      _reservoir.setRange(begin, end, data);
      _resLen = end;
      underflow = 0;
    } else {
      _reservoir.setRange(0, unread, _reservoir.sublist(_resLen - unread, _resLen));
      _reservoir.setRange(unread, unread + data.length, data);
      _resLen = unread + data.length;
      underflow = begin - unread;
    }
    _resConsumed = 0;
    return underflow;
  }

  void _readGranule(BitReader bs, _Granule g, Mp3Header h) {
    g.part23 = bs.readBits(12);
    g.bigValues = bs.readBits(9);
    if (g.bigValues > 288) throw const AudioFormatException('This MP3 has an invalid granule.');
    g.globalGain = bs.readBits(8);
    g.scalefacCompress = bs.readBits(h.isMpeg1 ? 4 : 9);
    final windowSwitching = bs.readBool();
    final bands = mp3LongBands[h.rateIndex];
    if (windowSwitching) {
      final type = bs.readBits(2);
      if (type == 0) throw const AudioFormatException('This MP3 has an invalid block type.');
      g.mixed = bs.readBool();
      g.blockType = type;
      if (type != 2) g.mixed = false;
      for (var i = 0; i < 2; i++) {
        g.tableSelect[i] = bs.readBits(5);
      }
      for (var i = 0; i < 3; i++) {
        g.subblockGain[i] = bs.readBits(3);
      }
      if (h.version == 25) {
        g.region1 = bands[(type == 2 && !g.mixed) ? 6 : 8];
      } else if (h.isMpeg1 || type == 2) {
        g.region1 = 36;
      } else {
        g.region1 = 54;
      }
      g.region2 = 576;
    } else {
      g.blockType = 0;
      g.mixed = false;
      for (var i = 0; i < 3; i++) {
        g.tableSelect[i] = bs.readBits(5);
      }
      final r0 = bs.readBits(4) + 1;
      final r01 = bs.readBits(3) + r0 + 1;
      g.region1 = bands[r0];
      g.region2 = r01 <= 22 ? bands[r01] : 576;
    }
    g.preflag = h.isMpeg1 ? bs.readBool() : false;
    g.scalefacScale = bs.readBool();
    g.count1Table = bs.readBit();
  }

  int _readMainData(Mp3Header h, int underflowBits, List<List<_Granule>> granules) {
    final data = Uint8List.sublistView(_reservoir, _resConsumed, _resLen);
    var begin = 0;
    var skipped = 0;
    for (var g = 0; g < h.granules; g++) {
      if (skipped < underflowBits) {
        for (var c = 0; c < h.channels; c++) {
          _samples[g][c].fillRange(0, 576, 0);
          granules[g][c].part23 = granules[g][c].part23;
          skipped += granules[g][c].part23;
          granules[g][c].bigValues = 0;
          granules[g][c].globalGain = 0;
        }
        if (skipped > underflowBits) begin = skipped - underflowBits;
        continue;
      }
      for (var c = 0; c < h.channels; c++) {
        final gr = granules[g][c];
        final byteIndex = begin >> 3;
        if (byteIndex >= data.length) throw const AudioFormatException('This MP3 frame points outside its data.');
        final bs = BitReader(data, byteIndex);
        final bit = begin & 7;
        if (bit > 0) bs.skip(bit);
        final part2 = h.isMpeg1 ? _scalefactorsMpeg1(bs, g, c, granules, h) : _scalefactorsMpeg2(bs, c > 0 && h.intensityStereo, gr);
        if (part2 > gr.part23) throw const AudioFormatException('This MP3 has an invalid part length.');
        _huffman(bs, gr, gr.part23 - part2, _samples[g][c]);
        begin += gr.part23;
      }
    }
    return (begin + 7) >> 3;
  }

  int _scalefactorsMpeg1(BitReader bs, int g, int c, List<List<_Granule>> granules, Mp3Header h) {
    final gr = granules[g][c];
    final (slen1, slen2) = _slen[gr.scalefacCompress];
    var read = 0;
    if (gr.blockType == 2) {
      final n = gr.mixed ? 8 + 3 * 3 : 6 * 3;
      if (slen1 > 0) {
        for (var i = 0; i < n; i++) {
          gr.scalefacs[i] = bs.readBits(slen1);
        }
        read += n * slen1;
      }
      if (slen2 > 0) {
        for (var i = n; i < n + 18; i++) {
          gr.scalefacs[i] = bs.readBits(slen2);
        }
        read += 18 * slen2;
      }
    } else {
      const ranges = [(0, 6), (6, 11), (11, 16), (16, 21)];
      for (var i = 0; i < 4; i++) {
        final (start, end) = ranges[i];
        final slen = i < 2 ? slen1 : slen2;
        if (g > 0 && _scfsi[c][i]) {
          for (var s = start; s < end; s++) {
            gr.scalefacs[s] = granules[0][c].scalefacs[s];
          }
        } else if (slen > 0) {
          for (var s = start; s < end; s++) {
            gr.scalefacs[s] = bs.readBits(slen);
          }
          read += slen * (end - start);
        }
      }
    }
    return read;
  }

  int _scalefactorsMpeg2(BitReader bs, bool intensity, _Granule gr) {
    final block = gr.blockType == 2 ? (gr.mixed ? 2 : 1) : 0;
    List<int> slens;
    List<int> counts;
    if (intensity) {
      final sfc = gr.scalefacCompress >> 1;
      if (sfc < 180) {
        slens = [sfc ~/ 36, (sfc % 36) ~/ 6, (sfc % 36) % 6, 0];
        counts = _nsfb[0][block];
      } else if (sfc < 244) {
        slens = [((sfc - 180) % 64) >> 4, ((sfc - 180) % 16) >> 2, (sfc - 180) % 4, 0];
        counts = _nsfb[1][block];
      } else {
        slens = [(sfc - 244) ~/ 3, (sfc - 244) % 3, 0, 0];
        counts = _nsfb[2][block];
      }
    } else {
      final sfc = gr.scalefacCompress;
      gr.preflag = sfc >= 500;
      if (sfc < 400) {
        slens = [(sfc >> 4) ~/ 5, (sfc >> 4) % 5, (sfc % 16) >> 2, sfc % 4];
        counts = _nsfb[3][block];
      } else if (sfc < 500) {
        slens = [((sfc - 400) >> 2) ~/ 5, ((sfc - 400) >> 2) % 5, (sfc - 400) % 4, 0];
        counts = _nsfb[4][block];
      } else {
        slens = [(sfc - 500) ~/ 3, (sfc - 500) % 3, 0, 0];
        counts = _nsfb[5][block];
      }
    }
    var start = 0, read = 0;
    for (var i = 0; i < 4; i++) {
      if (slens[i] > 0) {
        for (var s = start; s < start + counts[i]; s++) {
          gr.scalefacs[s] = bs.readBits(slens[i]);
        }
        read += slens[i] * counts[i];
      }
      start += counts[i];
    }
    return read;
  }

  void _huffman(BitReader bs, _Granule gr, int part3Bits, Float64List buf) {
    buf.fillRange(0, 576, 0);
    if (part3Bits <= 0) return;
    var bitsRead = 0;
    var i = 0;
    final bigLen = 2 * gr.bigValues;
    final regions = [math.min(gr.region1, bigLen), math.min(gr.region2, bigLen), math.min(576, bigLen)];
    final startBit = bs.position;
    for (var r = 0; r < 3; r++) {
      final select = gr.tableSelect[r];
      final tableNumber = select <= 15 ? select : (select <= 23 ? 16 : 24);
      final linbits = mp3Linbits[select];
      final end = regions[r];
      if (tableNumber == 0) {
        while (i < end) {
          i += 2;
        }
        continue;
      }
      final vlc = _bigValueTables[tableNumber];
      if (vlc == null) throw const AudioFormatException('This MP3 uses a table that does not exist.');
      final wrap = mp3HuffmanWrap[tableNumber]!;
      while (i < end && bitsRead < part3Bits) {
        final symbol = vlc.read(bs);
        var x = symbol ~/ wrap, y = symbol % wrap;
        bitsRead = bs.position - startBit;
        if (x > 0) {
          if (x == 15 && linbits > 0) x += bs.readBits(linbits);
          buf[i] = (1.0 - 2.0 * bs.readBit()) * _pow43[x];
        }
        i++;
        if (y > 0) {
          if (y == 15 && linbits > 0) y += bs.readBits(linbits);
          buf[i] = (1.0 - 2.0 * bs.readBit()) * _pow43[y];
        }
        i++;
        bitsRead = bs.position - startBit;
      }
    }
    final quads = _quadTables[gr.count1Table];
    while (i <= 572 && bitsRead < part3Bits) {
      final v = quads.read(bs);
      var ones = 0;
      for (var b = 0; b < 4; b++) {
        if (v & (1 << b) != 0) ones++;
      }
      var signs = bs.readBits(ones);
      bitsRead = bs.position - startBit;
      // bit 3 is the first value, bit 0 the last; signs come in that order, the first sign in the highest bit
      for (var k = 0; k < 4; k++) {
        if (v & (8 >> k) != 0) {
          ones--;
          buf[i + k] = 1.0 - 2.0 * ((signs >> ones) & 1);
        }
      }
      signs = 0;
      i += 4;
    }
    if (bitsRead < part3Bits) {
      bs.skip(math.min(part3Bits - bitsRead, bs.bitsLeft));
    } else if (bitsRead > part3Bits && i > bigLen) {
      i -= 4;
    }
    for (var k = i; k < 576; k++) {
      buf[k] = 0;
    }
  }

  void _requantize(Mp3Header h, _Granule gr, Float64List buf) {
    final shift = gr.scalefacScale ? 2 : 1;
    final gain = gr.globalGain - 210;
    if (gr.blockType == 2) {
      final shortBands = mp3ShortBands[h.rateIndex];
      final a = [for (var w = 0; w < 3; w++) gain - 8 * gr.subblockGain[w]];
      var firstShort = 0;
      var switchBands = 0;
      if (gr.mixed) {
        switchBands = _mixedLong[h.rateIndex];
        final longBands = mp3LongBands[h.rateIndex];
        for (var i = 0; i < switchBands; i++) {
          final b = (gr.scalefacs[i] + (gr.preflag ? _preEmphasis[i] : 0)) << shift;
          final f = math.pow(2, 0.25 * (gain - b)).toDouble();
          for (var k = longBands[i]; k < longBands[i + 1]; k++) {
            buf[k] *= f;
          }
        }
        firstShort = 9; // (36 lines: three short bands in each of three windows)
      }
      for (var i = firstShort; i + 1 < shortBands.length; i++) {
        final b = gr.scalefacs[switchBands + i - firstShort] << shift;
        final f = math.pow(2, 0.25 * (a[i % 3] - b)).toDouble();
        for (var k = shortBands[i]; k < shortBands[i + 1]; k++) {
          buf[k] *= f;
        }
      }
    } else {
      final longBands = mp3LongBands[h.rateIndex];
      for (var i = 0; i + 1 < longBands.length; i++) {
        final b = (gr.scalefacs[i] + (gr.preflag ? _preEmphasis[i] : 0)) << shift;
        final f = math.pow(2, 0.25 * (gain - b)).toDouble();
        for (var k = longBands[i]; k < longBands[i + 1]; k++) {
          buf[k] *= f;
        }
      }
    }
  }

  void _reorder(Mp3Header h, _Granule gr, Float64List buf) {
    if (gr.blockType != 2) return;
    final shortBands = mp3ShortBands[h.rateIndex];
    final from = gr.mixed ? 9 : 0;
    final start = shortBands[from];
    final tmp = Float64List(576);
    var i = start;
    for (var b = from; b + 3 < shortBands.length; b += 3) {
      final s0 = shortBands[b], s1 = shortBands[b + 1], s2 = shortBands[b + 2], s3 = shortBands[b + 3];
      for (var k = 0; k < s1 - s0; k++) {
        tmp[i] = buf[s0 + k];
        tmp[i + 1] = buf[s1 + k];
        tmp[i + 2] = buf[s2 + k];
        i += 3;
      }
      // (s3 is where the next band starts)
      assert(s3 - s2 == s1 - s0);
    }
    for (var k = start; k < i; k++) {
      buf[k] = tmp[k];
    }
  }

  void _antialias(_Granule gr, Float64List s) {
    if (gr.blockType == 2 && !gr.mixed) return;
    final limit = gr.blockType == 2 ? 2 : 32;
    for (var sb = 1; sb < limit; sb++) {
      final at = sb * 18;
      for (var i = 0; i < 8; i++) {
        final lo = s[at - 1 - i], up = s[at + i];
        s[at - 1 - i] = lo * _cs[i] - up * _ca[i];
        s[at + i] = up * _cs[i] + lo * _ca[i];
      }
    }
  }

  void _hybrid(_Granule gr, Float64List overlap, Float64List s) {
    final split = gr.blockType == 2 ? (gr.mixed ? 2 : 0) : 32;
    final long = gr.blockType == 1 ? _imdctWindows[1] : (gr.blockType == 3 ? _imdctWindows[3] : _imdctWindows[0]);
    final y = Float64List(36);
    for (var sb = 0; sb < 32; sb++) {
      final at = sb * 18;
      y.fillRange(0, 36, 0);
      if (sb < split) {
        for (var i = 0; i < 36; i++) {
          var acc = 0.0;
          for (var k = 0; k < 18; k++) {
            acc += s[at + k] * _cos36[i * 18 + k];
          }
          y[i] = acc * long[i];
        }
      } else {
        final win = _imdctWindows[2];
        for (var w = 0; w < 3; w++) {
          for (var i = 0; i < 12; i++) {
            var acc = 0.0;
            for (var k = 0; k < 6; k++) {
              acc += s[at + 3 * k + w] * _cos12[i * 6 + k];
            }
            y[6 + 6 * w + i] += acc * win[i];
          }
        }
      }
      for (var i = 0; i < 18; i++) {
        s[at + i] = y[i] + overlap[at + i];
        overlap[at + i] = y[18 + i];
      }
    }
  }

  void _frequencyInversion(Float64List s) {
    for (var sb = 1; sb < 32; sb += 2) {
      for (var i = 1; i < 18; i += 2) {
        s[sb * 18 + i] = -s[sb * 18 + i];
      }
    }
  }

  /// The polyphase synthesis: 18 slots of 32 subband samples become 576 samples.
  void _synthesize(int channel, Float64List s, Float64List out, int outStart) {
    final v = _v[channel];
    final x = Float64List(32), c = Float64List(32);
    for (var t = 0; t < 18; t++) {
      for (var sb = 0; sb < 32; sb++) {
        x[sb] = s[sb * 18 + t];
      }
      for (var m = 0; m < 32; m++) {
        var acc = 0.0;
        for (var k = 0; k < 32; k++) {
          acc += x[k] * _cos32[m * 32 + k];
        }
        c[m] = acc;
      }
      _vOffset[channel] = (_vOffset[channel] + 1024 - 64) & 1023;
      final o = _vOffset[channel];
      for (var i = 0; i < 64; i++) {
        final m = 16 + i;
        double value;
        if (m < 32) {
          value = c[m];
        } else if (m == 32) {
          value = 0;
        } else if (m < 64) {
          value = -c[64 - m];
        } else if (m == 64) {
          value = -c[0];
        } else {
          value = -c[m - 64];
        }
        v[(o + i) & 1023] = value;
      }
      for (var j = 0; j < 32; j++) {
        var acc = 0.0;
        for (var i = 0; i < 8; i++) {
          acc += v[(o + i * 128 + j) & 1023] * mp3SynthesisWindow[i * 64 + j];
          acc += v[(o + i * 128 + 96 + j) & 1023] * mp3SynthesisWindow[i * 64 + 32 + j];
        }
        out[outStart + t * 32 + j] = acc;
      }
    }
  }
}

/// A raw MP3 file (with or without an ID3 tag).
class Mp3Source implements PcmSource {
  final ByteSource _source;
  @override
  final int sampleRate, channels;
  final int _firstFrame;

  Mp3Source._(this._source, this.sampleRate, this.channels, this._firstFrame);

  static Future<Mp3Source> open(ByteSource source) async {
    var pos = 0;
    final head = await source.read(0, 10);
    if (head.length >= 10 && String.fromCharCodes(head.sublist(0, 3)) == 'ID3') {
      pos = 10 + ((head[6] & 0x7F) << 21 | (head[7] & 0x7F) << 14 | (head[8] & 0x7F) << 7 | (head[9] & 0x7F));
    }
    // look for the first run of frames that follow each other
    final window = await source.read(pos, 256 * 1024);
    for (var i = 0; i + 4 < window.length; i++) {
      final h = Mp3Header.parse(window, i);
      if (h == null) continue;
      final next = i + h.frameSize;
      final h2 = next + 4 <= window.length ? Mp3Header.parse(window, next) : null;
      if (h2 != null && h2.sampleRate == h.sampleRate && h2.layer == h.layer) {
        if (h.layer != 3) throw AudioFormatException('This MP3 file uses MPEG Layer ${h.layer}, which is not supported (only Layer III).');
        return Mp3Source._(source, h.sampleRate, h.channels, pos + i);
      }
    }
    throw const AudioFormatException('No MP3 audio was found in this file.');
  }

  @override
  String get codec => 'mp3';

  @override
  double? get seconds => null;

  @override
  Stream<List<Float64List>> blocks() async* {
    final decoder = Mp3Decoder();
    var fileAt = _firstFrame;
    var buffer = Uint8List(0);
    var done = false;
    var pending = <List<Float64List>>[];
    var first = true;
    while (true) {
      if (!done && buffer.length < 8192) {
        final more = await _source.read(fileAt, 512 * 1024);
        fileAt += more.length;
        if (more.isEmpty) done = true;
        buffer = Uint8List(buffer.length + more.length)
          ..setAll(0, buffer.sublist(0))
          ..setAll(buffer.length, more);
      }
      var at = 0;
      while (at + 4 <= buffer.length) {
        final h = Mp3Header.parse(buffer, at);
        if (h == null) {
          at++;
          continue;
        }
        if (at + h.frameSize > buffer.length) {
          if (!done) break;
          at = buffer.length;
          break;
        }
        final frame = Uint8List.sublistView(buffer, at, at + h.frameSize);
        at += h.frameSize;
        if (h.layer != 3 || h.sampleRate != sampleRate) continue;
        if (first) {
          first = false;
          // a Xing/Info/VBRI frame is the description of the file, not sound
          final tag = 4 + (h.hasCrc ? 2 : 0) + h.sideInfoLength;
          if (frame.length >= tag + 4) {
            final name = String.fromCharCodes(frame.sublist(tag, tag + 4));
            if (name == 'Xing' || name == 'Info') continue;
          }
          if (frame.length >= 40 && String.fromCharCodes(frame.sublist(36, 40)) == 'VBRI') continue;
        }
        try {
          final pcm = decoder.decodeFrame(frame, h);
          pending.add(pcm.length == channels ? pcm : [for (var c = 0; c < channels; c++) pcm[math.min(c, pcm.length - 1)]]);
        } on AudioFormatException {
          // a damaged frame is skipped: what is left of the sound goes on
          continue;
        }
        if (pending.length >= 40) {
          yield _join(pending);
          pending = [];
        }
      }
      buffer = Uint8List.sublistView(buffer, at);
      if (done && buffer.length < 4) break;
      if (done && at == 0) break;
    }
    if (pending.isNotEmpty) yield _join(pending);
  }

  List<Float64List> _join(List<List<Float64List>> frames) {
    final out = <Float64List>[];
    for (var c = 0; c < channels; c++) {
      var total = 0;
      for (final f in frames) {
        total += f[c].length;
      }
      final one = Float64List(total);
      var at = 0;
      for (final f in frames) {
        one.setAll(at, f[c]);
        at += f[c].length;
      }
      out.add(one);
    }
    return out;
  }
}
