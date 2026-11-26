import 'dart:math' as math;
import 'dart:typed_data';

import 'aac_tables.dart';
import 'bits.dart';
import 'mdct.dart';

// An AAC-LC decoder (ISO/IEC 13818-7, 14496-3) in plain Dart, one or two channels, no SBR (a file with SBR is decoded at the rate of
// its core, which is all Whisper needs: it listens up to 8 kHz). The structure follows the AAC decoder of the Symphonia project
// (MPL-2.0, itself from NihAV), written again here.

const _onlyLong = 0, _longStart = 1, _eightShort = 2, _longStop = 3;
const _maxWindows = 8, _maxSfbs = 64;
const _zeroBook = 0, _reservedBook = 12, _noiseBook = 13, _intensityBook2 = 14, _intensityBook = 15;

const _sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

const _long48 = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024];
const _short48 = [0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128];
const _long32 = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 960, 992, 1024];
const _long8 = [0, 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172, 188, 204, 220, 236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448, 476, 508, 544, 580, 620, 664, 712, 764, 820, 880, 944, 1024];
const _short8 = [0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128];
const _long16 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344, 368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024];
const _short16 = [0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128];
const _long24 = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220, 240, 260, 284, 308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704, 768, 832, 896, 960, 1024];
const _short24 = [0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128];
const _long64 = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 100, 112, 124, 140, 156, 172, 192, 216, 240, 268, 304, 344, 384, 424, 464, 504, 544, 584, 624, 664, 704, 744, 784, 824, 864, 904, 944, 984, 1024];
const _short64 = [0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128];
const _long96 = [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 156, 172, 188, 212, 240, 276, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960, 1024];

/// (long bands, short bands) for each sampling frequency index 0..11 (96 kHz down to 8 kHz).
const _bandTables = <(List<int>, List<int>)>[
  (_long96, _short64),
  (_long96, _short64),
  (_long64, _short64),
  (_long48, _short48),
  (_long48, _short48),
  (_long32, _short48),
  (_long24, _short24),
  (_long24, _short24),
  (_long16, _short16),
  (_long16, _short16),
  (_long16, _short16),
  (_long8, _short8),
];

const _tnsMaxLong = [31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39];
const _tnsMaxShort = [9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14];

final _scaleFactorVlc = Vlc(aacScaleFactorCodes, aacScaleFactorLengths);
final _spectrumVlc = [for (var i = 0; i < 11; i++) Vlc(aacSpectrumCodes[i], aacSpectrumLengths[i])];

/// The 81 groups of four numbers 0..2 of codebooks 1 to 4 (index = 27a + 9b + 3c + d).
int _quad(int index, int position) {
  switch (position) {
    case 0:
      return index ~/ 27;
    case 1:
      return (index ~/ 9) % 3;
    case 2:
      return (index ~/ 3) % 3;
    default:
      return index % 3;
  }
}

final Float64List _pow43 = Float64List.fromList([for (var i = 0; i < 8192; i++) math.pow(i, 4 / 3).toDouble()]);
final Float64List _normalScale = Float64List.fromList([for (var i = 0; i < 256; i++) math.pow(2, 0.25 * (i - 56 - 100)).toDouble()]);
final Float64List _intensityScale = Float64List.fromList([for (var i = 0; i < 256; i++) math.pow(0.5, 0.25 * (i - 155)).toDouble()]);

double _bessel0(double x) {
  var v = 1.0;
  for (var n = 63; n >= 1; n--) {
    v *= x / (n * n);
    v += 1;
  }
  return v;
}

Float64List _sineWindow(int size) => Float64List.fromList([for (var n = 0; n < size; n++) math.sin((n + 0.5) * math.pi / (2 * size))]);

Float64List _kaiserBesselWindow(int size, double alpha) {
  final alpha2 = math.pow(alpha * math.pi / size, 2).toDouble();
  final kb = Float64List(size);
  var sum = 0.0;
  for (var n = 0; n < size; n++) {
    sum += _bessel0(n * (size - n) * alpha2);
    kb[n] = sum;
  }
  sum += 1;
  return Float64List.fromList([for (var n = 0; n < size; n++) math.sqrt(kb[n] / sum)]);
}

class _Windows {
  final kbdLong = _kaiserBesselWindow(1024, 4);
  final kbdShort = _kaiserBesselWindow(128, 6);
  final sineLong = _sineWindow(1024);
  final sineShort = _sineWindow(128);
  final imdctLong = Imdct(1024, 1 / 2048);
  final imdctShort = Imdct(128, 1 / 256);
  final pcmLong = Float64List(2048);
  final pcmShort = Float64List(1152);
}

final _windows = _Windows();

/// The settings of the "ics_info" of a channel (a stretch of its header).
class _IcsInfo {
  int windowSequence = 0, prevWindowSequence = 0;
  bool windowShape = false, prevWindowShape = false;
  final scaleFactorGrouping = List<bool>.filled(_maxWindows, false);
  final groupStart = List<int>.filled(_maxWindows, 0);
  int windowGroups = 0, numWindows = 0, maxSfb = 0;
  bool longWin = true;

  void read(BitReader bs) {
    prevWindowSequence = windowSequence;
    prevWindowShape = windowShape;
    if (bs.readBool()) throw const AudioFormatException('This AAC audio has a reserved bit set.');
    windowSequence = bs.readBits(2);
    windowShape = bs.readBool();
    windowGroups = 1;
    if (windowSequence == _eightShort) {
      longWin = false;
      numWindows = 8;
      maxSfb = bs.readBits(4);
      for (var i = 0; i < _maxWindows - 1; i++) {
        scaleFactorGrouping[i] = bs.readBool();
        if (!scaleFactorGrouping[i]) {
          groupStart[windowGroups] = i + 1;
          windowGroups++;
        }
      }
    } else {
      longWin = true;
      numWindows = 1;
      maxSfb = bs.readBits(6);
      if (bs.readBool()) throw const AudioFormatException('This AAC audio uses prediction (AAC Main or LTP), which is not supported.');
    }
  }

  void copyFromCommon(_IcsInfo o) {
    final prevSeq = windowSequence, prevShape = windowShape;
    windowSequence = o.windowSequence;
    windowShape = o.windowShape;
    for (var i = 0; i < _maxWindows; i++) {
      scaleFactorGrouping[i] = o.scaleFactorGrouping[i];
      groupStart[i] = o.groupStart[i];
    }
    windowGroups = o.windowGroups;
    numWindows = o.numWindows;
    maxSfb = o.maxSfb;
    longWin = o.longWin;
    prevWindowSequence = prevSeq;
    prevWindowShape = prevShape;
  }

  int groupStartOf(int g) {
    if (g == 0) return 0;
    if (g >= windowGroups) return longWin ? 1 : 8;
    return groupStart[g];
  }
}

class _Pulse {
  int count = 0, startSfb = 0;
  final offset = List<int>.filled(4, 0), amp = List<int>.filled(4, 0);
}

class _TnsFilter {
  int length = 0, order = 0;
  bool direction = false;
  final coef = Float64List(21);
}

class _Tns {
  final nFilt = List<int>.filled(_maxWindows, 0);
  final filters = [for (var w = 0; w < _maxWindows; w++) [for (var f = 0; f < 4; f++) _TnsFilter()]];
}

class _Lcg {
  int state = 0x1f2e3d4c;
  int next() {
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return state.toSigned(32);
  }
}

class _Ics {
  int globalGain = 0;
  final info = _IcsInfo();
  _Pulse? pulse;
  _Tns? tns;
  final sfbCb = [for (var w = 0; w < _maxWindows; w++) Uint8List(_maxSfbs)];
  final scales = [for (var w = 0; w < _maxWindows; w++) Float64List(_maxSfbs)];
  final coeffs = Float64List(1024);
  final delay = Float64List(1024);

  bool isZero(int g, int sfb) => sfbCb[g][sfb] == _zeroBook;
  bool isIntensity(int g, int sfb) => sfbCb[g][sfb] == _intensityBook || sfbCb[g][sfb] == _intensityBook2;
  bool isNoise(int g, int sfb) => sfbCb[g][sfb] == _noiseBook;
  bool intensityDirection(int g, int sfb) => sfbCb[g][sfb] == _intensityBook;
}

/// The decoder of one stream: made from the "AudioSpecificConfig" of an MP4 file (or the header of an ADTS frame), fed one access unit
/// at a time.
class AacDecoder {
  final int sampleRate, channels, _rateIndex;
  final List<_Ics> _ics;
  final _Lcg _lcg = _Lcg();
  final List<int> _long, _short;

  AacDecoder._(this.sampleRate, this.channels, this._rateIndex, this._long, this._short) : _ics = [for (var i = 0; i < channels; i++) _Ics()];

  /// From the AudioSpecificConfig bytes of an MP4 'esds' box.
  factory AacDecoder.fromConfig(Uint8List config) {
    if (config.length < 2) throw const AudioFormatException('The AAC settings of this file are too short.');
    final bs = BitReader(config);
    int objectType() {
      final t = bs.readBits(5);
      return t == 31 ? bs.readBits(6) + 32 : t;
    }

    int rate() {
      final i = bs.readBits(4);
      return i == 15 ? bs.readBits(24) : (i < _sampleRates.length ? _sampleRates[i] : 0);
    }

    var type = objectType();
    var sampleRate = rate();
    if (sampleRate <= 0) throw const AudioFormatException('The AAC settings of this file have no sampling rate.');
    var channelConfig = bs.readBits(4);
    if (type == 5 || type == 29) {
      // explicit SBR / PS: the real type follows (the sampling rate before it is the core's, the one we decode at)
      rate();
      type = objectType();
    }
    if (type != 2) {
      throw AudioFormatException('This AAC audio is of a kind that is not supported (object type $type); only AAC-LC is.');
    }
    final shortFrame = bs.readBool();
    if (shortFrame) throw const AudioFormatException('AAC with frames of 960 samples is not supported.');
    if (channelConfig == 0) throw const AudioFormatException('AAC with its own channel layout is not supported.');
    const counts = [0, 1, 2, 3, 4, 5, 6, 8];
    final channels = channelConfig < counts.length ? counts[channelConfig] : 0;
    if (channels < 1 || channels > 2) throw AudioFormatException('This audio has $channels channels; only mono and stereo AAC are supported.');
    var index = 11;
    for (var i = 0; i < _sampleRates.length - 1; i++) {
      // (the same way the reference decoders choose: the first table whose lower limit the rate reaches)
      const limits = [92017, 75132, 55426, 46009, 37566, 27713, 23004, 18783, 13856, 11502, 9391, 0];
      if (sampleRate >= limits[i]) {
        index = i;
        break;
      }
    }
    final tables = _bandTables[index];
    return AacDecoder._(sampleRate, channels, index, tables.$1, tables.$2);
  }

  /// A decoder for the AAC-LC stream of ADTS frames that starts with [firstFrame] (a raw .aac file).
  factory AacDecoder.fromAdts(Uint8List firstFrame) {
    if (firstFrame.length < 7 || firstFrame[0] != 0xFF || (firstFrame[1] & 0xF0) != 0xF0) {
      throw const AudioFormatException('This is not AAC in ADTS frames.');
    }
    final profile = (firstFrame[2] >> 6) & 3; // 1 = LC
    final rateIndex = (firstFrame[2] >> 2) & 15;
    final ch = ((firstFrame[2] & 1) << 2) | (firstFrame[3] >> 6);
    // (as an AudioSpecificConfig: 5 bits type, 4 bits rate, 4 bits channels, then three zero bits)
    final type = profile + 1;
    final bits = (type << 11) | (rateIndex << 7) | (ch << 3);
    return AacDecoder.fromConfig(Uint8List.fromList([bits >> 8, bits & 0xFF]));
  }

  /// The samples of one access unit: a list of [channels] lists of 1024 numbers (-1..1).
  List<Float64List> decode(Uint8List frame) {
    final bs = BitReader(frame);
    var channel = 0;
    final out = [for (var c = 0; c < channels; c++) Float64List(1024)];
    final done = <(int, bool)>[];
    while (bs.bitsLeft > 3) {
      final id = bs.readBits(3);
      if (id == 0 || id == 3) {
        // single channel element, low frequency element
        bs.skip(4);
        if (channel >= channels) throw const AudioFormatException('This AAC frame has more channels than the file says.');
        _decodeChannel(bs, _ics[channel], false);
        done.add((channel, false));
        channel++;
      } else if (id == 1) {
        bs.skip(4);
        if (channel + 1 >= channels) throw const AudioFormatException('This AAC frame has more channels than the file says.');
        _decodePair(bs, _ics[channel], _ics[channel + 1]);
        done.add((channel, true));
        channel += 2;
      } else if (id == 2) {
        throw const AudioFormatException('AAC coupling channels are not supported.');
      } else if (id == 4) {
        bs.skip(4);
        final align = bs.readBool();
        var count = bs.readBits(8);
        if (count == 255) count += bs.readBits(8);
        if (align) bs.alignToByte();
        bs.skip(count * 8);
      } else if (id == 5) {
        throw const AudioFormatException('AAC program config elements are not supported.');
      } else if (id == 6) {
        var count = bs.readBits(4);
        if (count == 15) count += bs.readBits(8) - 1;
        bs.skip(count * 8); // fill bytes or the SBR data: not used
      } else {
        break; // end
      }
    }
    for (final (first, isPair) in done) {
      _synth(_ics[first], out[first]);
      if (isPair) _synth(_ics[first + 1], out[first + 1]);
    }
    return out;
  }

  void _decodePair(BitReader bs, _Ics a, _Ics b) {
    final common = bs.readBool();
    final msUsed = [for (var w = 0; w < _maxWindows; w++) List<bool>.filled(_maxSfbs, false)];
    var msMask = 0;
    if (common) {
      a.info.read(bs);
      msMask = bs.readBits(2);
      switch (msMask) {
        case 0:
        case 2:
          for (var g = 0; g < a.info.windowGroups; g++) {
            for (var s = 0; s < a.info.maxSfb; s++) {
              msUsed[g][s] = msMask == 2;
            }
          }
        case 1:
          for (var g = 0; g < a.info.windowGroups; g++) {
            for (var s = 0; s < a.info.maxSfb; s++) {
              msUsed[g][s] = bs.readBool();
            }
          }
        default:
          throw const AudioFormatException('This AAC audio has an invalid stereo mask.');
      }
      b.info.copyFromCommon(a.info);
    }
    _decodeChannel(bs, a, common);
    _decodeChannel(bs, b, common);
    if (!common) return;
    final bands = a.info.longWin ? _long : _short;
    var g = 0;
    for (var w = 0; w < a.info.numWindows; w++) {
      if (w > 0 && !a.info.scaleFactorGrouping[w - 1]) g++;
      for (var sfb = 0; sfb < a.info.maxSfb; sfb++) {
        final start = w * 128 + bands[sfb], end = w * 128 + bands[sfb + 1];
        if (b.isIntensity(g, sfb)) {
          final invert = msMask == 1 && msUsed[g][sfb];
          final dir = b.intensityDirection(g, sfb) ? 1.0 : -1.0;
          final scale = dir * (invert ? -1.0 : 1.0) * b.scales[g][sfb];
          for (var i = start; i < end; i++) {
            b.coeffs[i] = scale * a.coeffs[i];
          }
        } else if (a.isNoise(g, sfb) || b.isNoise(g, sfb)) {
          // noise substitution: no stereo decoding
        } else if (msUsed[g][sfb]) {
          for (var i = start; i < end; i++) {
            final m = a.coeffs[i], s = b.coeffs[i];
            a.coeffs[i] = m + s;
            b.coeffs[i] = m - s;
          }
        }
      }
    }
  }

  void _decodeChannel(BitReader bs, _Ics ics, bool common) {
    final info = ics.info;
    ics.globalGain = bs.readBits(8);
    if (!common) info.read(bs);
    // section data
    final sectBits = info.longWin ? 5 : 3;
    final escape = (1 << sectBits) - 1;
    for (var g = 0; g < info.windowGroups; g++) {
      var k = 0;
      while (k < info.maxSfb) {
        final book = bs.readBits(4);
        if (book == _reservedBook) throw const AudioFormatException('This AAC audio has an invalid band type.');
        var length = 0;
        while (true) {
          final inc = bs.readBits(sectBits);
          length += inc;
          if (inc < escape) break;
        }
        if (k + length > info.maxSfb) throw const AudioFormatException('This AAC audio has an invalid section.');
        for (var s = k; s < k + length; s++) {
          ics.sfbCb[g][s] = book;
        }
        k += length;
      }
    }
    // scale factors
    var noisePcm = true;
    var scfIntensity = 155;
    var scfNoise = ics.globalGain - 90 + 100;
    var scfNormal = ics.globalGain;
    for (var g = 0; g < info.windowGroups; g++) {
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        if (ics.isZero(g, sfb)) {
          ics.scales[g][sfb] = 0;
        } else if (ics.isIntensity(g, sfb)) {
          scfIntensity += _scaleFactorVlc.read(bs) - 60;
          if (scfIntensity < 0 || scfIntensity >= 256) throw const AudioFormatException('This AAC audio has an invalid scale factor.');
          ics.scales[g][sfb] = _intensityScale[scfIntensity];
        } else if (ics.isNoise(g, sfb)) {
          if (noisePcm) {
            noisePcm = false;
            scfNoise += bs.readBits(9) - 256;
          } else {
            scfNoise += _scaleFactorVlc.read(bs) - 60;
          }
          if (scfNoise < 0 || scfNoise >= 256) throw const AudioFormatException('This AAC audio has an invalid scale factor.');
          ics.scales[g][sfb] = _normalScale[scfNoise];
        } else {
          scfNormal += _scaleFactorVlc.read(bs) - 60;
          if (scfNormal < 0 || scfNormal >= 256) throw const AudioFormatException('This AAC audio has an invalid scale factor.');
          ics.scales[g][sfb] = _normalScale[scfNormal];
        }
      }
    }
    // pulse
    ics.pulse = null;
    if (bs.readBool()) {
      final p = _Pulse()
        ..count = bs.readBits(2) + 1
        ..startSfb = bs.readBits(6);
      for (var i = 0; i < p.count; i++) {
        p.offset[i] = bs.readBits(5);
        p.amp[i] = bs.readBits(4);
      }
      if (!info.longWin) throw const AudioFormatException('This AAC audio has pulses in short windows.');
      ics.pulse = p;
    }
    // temporal noise shaping
    ics.tns = null;
    if (bs.readBool()) ics.tns = _readTns(bs, info);
    if (bs.readBool()) throw const AudioFormatException('This AAC audio uses gain control (SSR), which is not supported.');
    _readSpectrum(bs, ics);
  }

  _Tns _readTns(BitReader bs, _IcsInfo info) {
    final tns = _Tns();
    final maxOrder = info.longWin ? 12 : 7;
    for (var w = 0; w < info.numWindows; w++) {
      tns.nFilt[w] = bs.readBits(info.longWin ? 2 : 1);
      final coefRes = tns.nFilt[w] != 0 && bs.readBool();
      for (var f = 0; f < tns.nFilt[w]; f++) {
        final c = tns.filters[w][f];
        c.length = bs.readBits(info.longWin ? 6 : 4);
        c.order = bs.readBits(info.longWin ? 5 : 3);
        if (c.order > maxOrder) throw const AudioFormatException('This AAC audio has a filter that is too long.');
        if (c.order > 0) {
          c.direction = bs.readBool();
          final compress = bs.readBool();
          var resBits = coefRes ? 4 : 3;
          if (compress) resBits--;
          final fac = coefRes ? 8.0 : 4.0;
          final iqfac = (fac - 0.5) / (math.pi / 2), iqfacM = (fac + 0.5) / (math.pi / 2);
          final tmp = Float64List(20);
          for (var i = 0; i < c.order; i++) {
            final v = bs.readSigned(resBits);
            tmp[i] = math.sin(v >= 0 ? v / iqfac : v / iqfacM);
          }
          final b = Float64List(21);
          c.coef.fillRange(0, 21, 0);
          for (var m = 1; m <= c.order; m++) {
            for (var i = 1; i < m; i++) {
              b[i] = c.coef[i - 1] + tmp[m - 1] * c.coef[m - i - 1];
            }
            for (var i = 0; i < m - 1; i++) {
              c.coef[i] = b[i + 1];
            }
            c.coef[m - 1] = tmp[m - 1];
          }
        }
      }
    }
    return tns;
  }

  void _readSpectrum(BitReader bs, _Ics ics) {
    final info = ics.info;
    final coeffs = ics.coeffs;
    coeffs.fillRange(0, 1024, 0);
    final bands = info.longWin ? _long : _short;
    for (var g = 0; g < info.windowGroups; g++) {
      final curW = info.groupStartOf(g), nextW = info.groupStartOf(g + 1);
      for (var sfb = 0; sfb < info.maxSfb; sfb++) {
        final start = bands[sfb], end = bands[sfb + 1];
        final book = ics.sfbCb[g][sfb];
        final scale = ics.scales[g][sfb];
        for (var w = curW; w < nextW; w++) {
          final from = start + w * 128, to = end + w * 128;
          switch (book) {
            case _zeroBook || _reservedBook || _intensityBook || _intensityBook2:
              break;
            case _noiseBook:
              _noise(scale, from, to, coeffs);
            case 1 || 2:
              _quads(bs, _spectrumVlc[book - 1], false, scale, from, to, coeffs);
            case 3 || 4:
              _quads(bs, _spectrumVlc[book - 1], true, scale, from, to, coeffs);
            case 5 || 6:
              _pairs(bs, _spectrumVlc[book - 1], 9, true, scale, from, to, coeffs);
            case 7 || 8:
              _pairs(bs, _spectrumVlc[book - 1], 8, false, scale, from, to, coeffs);
            case 9 || 10:
              _pairs(bs, _spectrumVlc[book - 1], 13, false, scale, from, to, coeffs);
            case 11:
              _escapePairs(bs, scale, from, to, coeffs);
          }
        }
      }
    }
  }

  void _noise(double scale, int from, int to, Float64List dst) {
    var energy = 0.0;
    for (var i = from; i < to; i++) {
      final v = (_lcg.next() >> 16).toDouble();
      dst[i] = v;
      energy += v * v;
    }
    final s = scale / math.sqrt(energy);
    for (var i = from; i < to; i++) {
      dst[i] *= s;
    }
  }

  static double _sign(int bit) => 1.0 - 2.0 * bit;

  void _quads(BitReader bs, Vlc vlc, bool unsigned, double scale, int from, int to, Float64List dst) {
    final unsignedValue = [0.0, scale, 2.51984209978974632953 * scale];
    for (var i = from; i < to; i += 4) {
      final index = vlc.read(bs);
      for (var k = 0; k < 4; k++) {
        final q = _quad(index, k);
        if (unsigned) {
          if (q != 0) dst[i + k] = _sign(bs.readBit()) * unsignedValue[q];
        } else {
          dst[i + k] = (q - 1) * scale;
        }
      }
    }
  }

  void _pairs(BitReader bs, Vlc vlc, int mod, bool signed, double scale, int from, int to, Float64List dst) {
    for (var i = from; i < to; i += 2) {
      final cw = vlc.read(bs);
      final a = cw ~/ mod, b = cw % mod;
      double x, y;
      if (signed) {
        final half = mod >> 1;
        x = a < half ? -_pow43[half - a] : _pow43[a - half];
        y = b < half ? -_pow43[half - b] : _pow43[b - half];
        dst[i] = x * scale;
        dst[i + 1] = y * scale;
      } else {
        x = _pow43[a];
        y = _pow43[b];
        final sx = a != 0 ? _sign(bs.readBit()) : 1.0;
        final sy = b != 0 ? _sign(bs.readBit()) : 1.0;
        dst[i] = sx * x * scale;
        dst[i + 1] = sy * y * scale;
      }
    }
  }

  int _escape(BitReader bs) {
    final n = bs.readUnary();
    if (n >= 9) throw const AudioFormatException('This AAC audio has an invalid escape code.');
    return (1 << (n + 4)) + bs.readBits(n + 4);
  }

  void _escapePairs(BitReader bs, double scale, int from, int to, Float64List dst) {
    final vlc = _spectrumVlc[10];
    for (var i = from; i < to; i += 2) {
      final cw = vlc.read(bs);
      final a = cw ~/ 17, b = cw % 17;
      final sx = a != 0 ? _sign(bs.readBit()) : 1.0;
      final sy = b != 0 ? _sign(bs.readBit()) : 1.0;
      final x = _pow43[a == 16 ? _escape(bs) : a];
      final y = _pow43[b == 16 ? _escape(bs) : b];
      dst[i] = sx * x * scale;
      dst[i + 1] = sy * y * scale;
    }
  }

  static double _iquant(double v) => v < 0 ? -math.pow(-v, 4 / 3).toDouble() : math.pow(v, 4 / 3).toDouble();
  static double _requant(double v, double scale) {
    if (scale == 0) return 0;
    return v >= 0 ? math.pow(v, 3 / 4).toDouble() : -math.pow(-v, 3 / 4).toDouble();
  }

  void _synth(_Ics ics, Float64List dst) {
    final info = ics.info;
    final bands = info.longWin ? _long : _short;
    final coeffs = ics.coeffs;
    final pulse = ics.pulse;
    if (pulse != null && pulse.startSfb < bands.length - 1) {
      var k = bands[pulse.startSfb];
      var band = pulse.startSfb;
      for (var p = 0; p < pulse.count; p++) {
        k += pulse.offset[p];
        if (k >= 1024) break;
        while (bands[band + 1] <= k) {
          band++;
        }
        final scale = ics.scales[0][band];
        var base = coeffs[k];
        if (base != 0) base = _requant(coeffs[k], scale);
        base = base > 0 ? base + pulse.amp[p] : base - pulse.amp[p];
        coeffs[k] = _iquant(base) * scale;
      }
    }
    final tns = ics.tns;
    if (tns != null) _applyTns(tns, info, bands, coeffs);
    _overlap(coeffs, ics.delay, info.windowSequence, info.windowShape, info.prevWindowShape, dst);
  }

  void _applyTns(_Tns tns, _IcsInfo info, List<int> bands, Float64List coeffs) {
    final maxBands = math.min(info.longWin ? _tnsMaxLong[_rateIndex] : _tnsMaxShort[_rateIndex], info.maxSfb);
    for (var w = 0; w < info.numWindows; w++) {
      var bottom = bands.length - 1;
      for (var f = 0; f < tns.nFilt[w]; f++) {
        final filter = tns.filters[w][f];
        final top = bottom;
        bottom = math.max(0, top - filter.length);
        final order = filter.order;
        if (order == 0) continue;
        final start = w * 128 + bands[math.min(bottom, maxBands)];
        final end = w * 128 + bands[math.min(top, maxBands)];
        if (!filter.direction) {
          for (var i = start, m = 0; i < end; i++, m++) {
            for (var j = 0; j < math.min(order, m); j++) {
              coeffs[i] -= coeffs[i - j - 1] * filter.coef[j];
            }
          }
        } else {
          for (var i = end - 1, m = 0; i >= start; i--, m++) {
            for (var j = 0; j < math.min(order, m); j++) {
              coeffs[i] -= coeffs[i + j + 1] * filter.coef[j];
            }
          }
        }
      }
    }
  }

  static const _shortPoint0 = 512 - 64, _shortPoint1 = 512 + 64;

  void _overlap(Float64List coeffs, Float64List delay, int seq, bool shape, bool prevShape, Float64List dst) {
    final w = _windows;
    final longWin = shape ? w.kbdLong : w.sineLong;
    final shortWin = shape ? w.kbdShort : w.sineShort;
    final prevLong = prevShape ? w.kbdLong : w.sineLong;
    final prevShort = prevShape ? w.kbdShort : w.sineShort;
    final pcmLong = w.pcmLong, pcmShort = w.pcmShort;
    if (seq != _eightShort) {
      w.imdctLong.run(coeffs, pcmLong);
    } else {
      final part = Float64List(128);
      for (var k = 0; k < 8; k++) {
        for (var i = 0; i < 128; i++) {
          part[i] = coeffs[k * 128 + i];
        }
        w.imdctShort.run(part, pcmLong, k * 256);
      }
      pcmShort.fillRange(0, pcmShort.length, 0);
      for (var k = 0; k < 8; k++) {
        final o = k * 256;
        if (k > 0) {
          for (var i = 0; i < 128; i++) {
            pcmShort[k * 128 + i] += pcmLong[o + i] * shortWin[i];
            pcmShort[k * 128 + i + 128] += pcmLong[o + i + 128] * shortWin[127 - i];
          }
        } else {
          for (var i = 0; i < 128; i++) {
            pcmShort[i] = pcmLong[o + i] * prevShort[i];
            pcmShort[i + 128] = pcmLong[o + i + 128] * shortWin[127 - i];
          }
        }
      }
    }
    switch (seq) {
      case _onlyLong || _longStart:
        for (var i = 0; i < 1024; i++) {
          dst[i] = delay[i] + pcmLong[i] * prevLong[i];
        }
      case _eightShort:
        for (var i = 0; i < _shortPoint0; i++) {
          dst[i] = delay[i];
        }
        for (var i = _shortPoint0; i < 1024; i++) {
          dst[i] = delay[i] + pcmShort[i - _shortPoint0];
        }
      case _longStop:
        for (var i = 0; i < _shortPoint0; i++) {
          dst[i] = delay[i];
        }
        for (var i = _shortPoint0; i < _shortPoint1; i++) {
          dst[i] = delay[i] + pcmLong[i] * prevShort[i - _shortPoint0];
        }
        for (var i = _shortPoint1; i < 1024; i++) {
          dst[i] = delay[i] + pcmLong[i];
        }
    }
    switch (seq) {
      case _onlyLong || _longStop:
        for (var i = 0; i < 1024; i++) {
          delay[i] = pcmLong[i + 1024] * longWin[1023 - i];
        }
      case _eightShort:
        for (var i = 0; i < _shortPoint1; i++) {
          delay[i] = pcmShort[i + 512 + 64];
        }
        for (var i = _shortPoint1; i < 1024; i++) {
          delay[i] = 0;
        }
      case _longStart:
        for (var i = 0; i < _shortPoint0; i++) {
          delay[i] = pcmLong[1024 + i];
        }
        for (var i = _shortPoint0; i < _shortPoint1; i++) {
          delay[i] = pcmLong[i + 1024] * shortWin[127 - (i - _shortPoint0)];
        }
        for (var i = _shortPoint1; i < 1024; i++) {
          delay[i] = 0;
        }
    }
  }
}
