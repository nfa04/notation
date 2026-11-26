import 'dart:math' as math;
import 'dart:typed_data';

import '../bits.dart';
import 'range_decoder.dart';
import 'silk_tables.dart';

// ---- the fixed point macros of SILK (libopus silk/macros.h, SigProc_FIX.h, Inlines.h) ----

int _smulwb(int a, int b) => (a * b.toSigned(16)) >> 16;
int _smlawb(int a, int b, int c) => (a + ((b * c.toSigned(16)) >> 16)).toSigned(32);
int _smulww(int a, int b) => ((a * b) >> 16).toSigned(32);
int _smlaww(int a, int b, int c) => (a + ((b * c) >> 16)).toSigned(32);
int _smmul(int a, int b) => ((a * b) >> 32).toSigned(32);
int _smulbb(int a, int b) => a.toSigned(16) * b.toSigned(16);
int _smlabb(int a, int b, int c) => (a + b.toSigned(16) * c.toSigned(16)).toSigned(32);
int _rshiftRound(int a, int s) => s == 1 ? (a >> 1) + (a & 1) : ((a >> (s - 1)) + 1) >> 1;
int _sat16(int a) => a > 32767 ? 32767 : (a < -32768 ? -32768 : a);
int _limit(int a, int l1, int l2) => l1 > l2 ? (a > l1 ? l1 : (a < l2 ? l2 : a)) : (a > l2 ? l2 : (a < l1 ? l1 : a));
int _clz32(int a) {
  final v = a & 0xFFFFFFFF;
  if (v == 0) return 32;
  return 32 - v.bitLength;
}

int _addSat32(int a, int b) {
  final s = a + b;
  return s > 0x7FFFFFFF ? 0x7FFFFFFF : (s < -0x80000000 ? -0x80000000 : s);
}

int _lshiftSat32(int a, int s) {
  final lo = -0x80000000 >> s, hi = 0x7FFFFFFF >> s;
  return _limit(a, lo, hi) << s;
}

int _rand(int seed) => (907633515 + seed * 196314165).toSigned(32);

int _div32_16(int a, int b) => a ~/ b;

int _inverse32VarQ(int b32, int qres) {
  final bHeadrm = _clz32(b32.abs()) - 1;
  final b32Nrm = (b32 << bHeadrm).toSigned(32);
  final b32Inv = _div32_16(0x7FFFFFFF >> 2, b32Nrm >> 16);
  var result = (b32Inv << 16).toSigned(32);
  final err = ((((1 << 29) - _smulwb(b32Nrm, b32Inv))) << 3).toSigned(32);
  result = _smlaww(result, err, b32Inv);
  final lshift = 61 - bHeadrm - qres;
  if (lshift <= 0) return _lshiftSat32(result, -lshift);
  if (lshift < 32) return result >> lshift;
  return 0;
}

int _div32VarQ(int a32, int b32, int qres) {
  final aHeadrm = _clz32(a32.abs()) - 1;
  var a32Nrm = (a32 << aHeadrm).toSigned(32);
  final bHeadrm = _clz32(b32.abs()) - 1;
  final b32Nrm = (b32 << bHeadrm).toSigned(32);
  final b32Inv = _div32_16(0x7FFFFFFF >> 2, b32Nrm >> 16);
  var result = _smulwb(a32Nrm, b32Inv);
  a32Nrm = (a32Nrm - ((_smmul(b32Nrm, result)) << 3).toSigned(32)).toSigned(32);
  result = _smlawb(result, a32Nrm, b32Inv);
  final lshift = 29 + aHeadrm - bHeadrm - qres;
  if (lshift < 0) return _lshiftSat32(result, -lshift);
  if (lshift < 32) return result >> lshift;
  return 0;
}

int _log2lin(int inLogQ7) {
  if (inLogQ7 < 0) return 0;
  if (inLogQ7 >= 3967) return 0x7FFFFFFF;
  var out = 1 << (inLogQ7 >> 7);
  final fracQ7 = inLogQ7 & 0x7F;
  if (inLogQ7 < 2048) {
    out = out + ((out * _smlawb(fracQ7, _smulbb(fracQ7, 128 - fracQ7), -174)) >> 7);
  } else {
    out = out + (out >> 7) * _smlawb(fracQ7, _smulbb(fracQ7, 128 - fracQ7), -174);
  }
  return out.toSigned(32);
}

// ---- the codebooks of the line spectral frequencies ----

class _NlsfCb {
  final int nVectors, order, quantStep;
  final List<int> cb1, wght, cb1Icdf, pred, ecSel, ecIcdf, deltaMin;
  const _NlsfCb(this.nVectors, this.order, this.quantStep, this.cb1, this.wght, this.cb1Icdf, this.pred, this.ecSel, this.ecIcdf, this.deltaMin);
}

final _cbNbMb = _NlsfCb(32, 10, (0.18 * 65536 + 0.5).toInt(), silkNLSFCB1NBMBQ8, silkNLSFCB1WghtQ9, silkNLSFCB1ICDFNBMB, silkNLSFPREDNBMBQ8, silkNLSFCB2SELECTNBMB, silkNLSFCB2ICDFNBMB, silkNLSFDELTAMINNBMBQ15);
final _cbWb = _NlsfCb(32, 16, (0.15 * 65536 + 0.5).toInt(), silkNLSFCB1WBQ8, silkNLSFCB1WBWghtQ9, silkNLSFCB1ICDFWB, silkNLSFPREDWBQ8, silkNLSFCB2SELECTWB, silkNLSFCB2ICDFWB, silkNLSFDELTAMINWBQ15);

const _nlsfQuantMax = 4;
const _maxLpc = 16;
const _ltpOrder = 5;
const _typeNoVoice = 0, _typeVoiced = 2;
const _codeIndependently = 0, _codeIndependentlyNoLtp = 1, _codeConditionally = 2;
const _quantOffset10 = 80;

final _ltpVq = [silkLTPGainVq0, silkLTPGainVq1, silkLTPGainVq2];
final _ltpGainIcdf = [silkLTPGainICDF0, silkLTPGainICDF1, silkLTPGainICDF2];

// ---- the resampler from the SILK rate to the output rate ----

const _up2Hq0 = [1746, 14986, 39083 - 65536];
const _up2Hq1 = [6854, 25769, 55542 - 65536];
const _delayDec = [
  [4, 0, 2, 0, 0],
  [0, 9, 4, 7, 4],
  [0, 3, 12, 7, 7],
];

int _rateId(int r) => ((((r >> 12) - (r > 16000 ? 1 : 0)) >> (r > 24000 ? 1 : 0))) - 1;

class _Resampler {
  final int fsIn, fsOut;
  final int inKHz, outKHz, inputDelay, batch;
  late final bool up2Only;
  late final int invRatio;
  final delayBuf = Int16List(96);
  final iir = Int32List(6);
  final fir = Int16List(8);

  _Resampler(this.fsIn, this.fsOut)
      : inKHz = fsIn ~/ 1000,
        outKHz = fsOut ~/ 1000,
        inputDelay = _delayDec[_rateId(fsIn)][_rateId(fsOut)],
        batch = (fsIn ~/ 1000) * 10 {
    if (fsOut <= fsIn) throw const AudioFormatException('Opus: this output rate is not supported for speech.');
    up2Only = fsOut == fsIn * 2;
    final up2x = up2Only ? 0 : 1;
    invRatio = ((((fsIn << (14 + up2x)) ~/ fsOut) << 2));
    var inv = invRatio;
    while (_smulww(inv, fsOut) < (fsIn << up2x)) {
      inv++;
    }
    _inv = inv;
  }
  late final int _inv;

  /// [out] gets inLen * outKHz / inKHz samples; [input] is read from [inOff].
  void process(Int16List out, Int16List input, int inOff, int inLen) {
    final nSamples = inKHz - inputDelay;
    for (var i = 0; i < nSamples; i++) {
      delayBuf[inputDelay + i] = input[inOff + i];
    }
    _run(out, 0, delayBuf, 0, inKHz);
    _run(out, outKHz, input, inOff + nSamples, inLen - inKHz);
    for (var i = 0; i < inputDelay; i++) {
      delayBuf[i] = input[inOff + inLen - inputDelay + i];
    }
  }

  void _run(Int16List out, int outOff, Int16List input, int inOff, int len) {
    if (up2Only) {
      _up2(out, outOff, input, inOff, len);
      return;
    }
    final buf = Int16List(2 * batch + 8);
    for (var i = 0; i < 8; i++) {
      buf[i] = fir[i];
    }
    var o = outOff;
    var inPos = inOff;
    var left = len;
    int nIn;
    while (true) {
      nIn = math.min(left, batch);
      final tmp = Int16List(2 * nIn);
      _up2(tmp, 0, input, inPos, nIn);
      buf.setRange(8, 8 + 2 * nIn, tmp);
      final maxIndex = nIn << 17;
      for (var index = 0; index < maxIndex; index += _inv) {
        final tableIndex = _smulwb(index & 0xFFFF, 12);
        final p = index >> 16;
        var res = _smulbb(buf[p], silkResamplerFracFIR12[tableIndex * 4]);
        res = _smlabb(res, buf[p + 1], silkResamplerFracFIR12[tableIndex * 4 + 1]);
        res = _smlabb(res, buf[p + 2], silkResamplerFracFIR12[tableIndex * 4 + 2]);
        res = _smlabb(res, buf[p + 3], silkResamplerFracFIR12[tableIndex * 4 + 3]);
        res = _smlabb(res, buf[p + 4], silkResamplerFracFIR12[(11 - tableIndex) * 4 + 3]);
        res = _smlabb(res, buf[p + 5], silkResamplerFracFIR12[(11 - tableIndex) * 4 + 2]);
        res = _smlabb(res, buf[p + 6], silkResamplerFracFIR12[(11 - tableIndex) * 4 + 1]);
        res = _smlabb(res, buf[p + 7], silkResamplerFracFIR12[(11 - tableIndex) * 4]);
        out[o++] = _sat16(_rshiftRound(res, 15));
      }
      inPos += nIn;
      left -= nIn;
      if (left > 0) {
        for (var i = 0; i < 8; i++) {
          buf[i] = buf[(nIn << 1) + i];
        }
      } else {
        break;
      }
    }
    for (var i = 0; i < 8; i++) {
      fir[i] = buf[(nIn << 1) + i];
    }
  }

  void _up2(Int16List out, int outOff, Int16List input, int inOff, int len) {
    final s = iir;
    for (var k = 0; k < len; k++) {
      final in32 = input[inOff + k] << 10;
      var y = in32 - s[0];
      var x = _smulwb(y, _up2Hq0[0]);
      var out1 = s[0] + x;
      s[0] = in32 + x;
      y = out1 - s[1];
      x = _smulwb(y, _up2Hq0[1]);
      var out2 = s[1] + x;
      s[1] = out1 + x;
      y = out2 - s[2];
      x = _smlawb(y, y, _up2Hq0[2]);
      out1 = s[2] + x;
      s[2] = out2 + x;
      out[outOff + 2 * k] = _sat16(_rshiftRound(out1, 10));
      y = in32 - s[3];
      x = _smulwb(y, _up2Hq1[0]);
      out1 = s[3] + x;
      s[3] = in32 + x;
      y = out1 - s[4];
      x = _smulwb(y, _up2Hq1[1]);
      out2 = s[4] + x;
      s[4] = out1 + x;
      y = out2 - s[5];
      x = _smlawb(y, y, _up2Hq1[2]);
      out1 = s[5] + x;
      s[5] = out2 + x;
      out[outOff + 2 * k + 1] = _sat16(_rshiftRound(out1, 10));
    }
  }
}

// ---- the state of one channel ----

class _Indices {
  int signalType = 0, quantOffsetType = 0;
  final gains = Int8List(4);
  final nlsf = Int8List(17);
  int nlsfInterp = 0, lagIndex = 0, contourIndex = 0, perIndex = 0, ltpScaleIndex = 0, seed = 0;
  final ltp = Int8List(4);
}

class _Channel {
  int prevGainQ16 = 65536;
  final exc = Int32List(320);
  final sLpc = Int32List(_maxLpc);
  final outBuf = Int16List(320 + 160);
  int lagPrev = 0, lastGainIndex = 0;
  _Indices indices = _Indices();
  int fsKHz = 0, fsApiHz = 0, nbSubfr = 0, frameLength = 0, subfrLength = 0, ltpMemLength = 0, lpcOrder = 0;
  _NlsfCb? cb;
  List<int> pitchContourIcdf = silkPitchContourICDF;
  List<int> pitchLowBitsIcdf = silkUniform8ICDF;
  final prevNlsf = Int16List(_maxLpc);
  int firstFrameAfterReset = 1;
  int prevSignalType = 0;
  int ecPrevSignalType = 0, ecPrevLagIndex = 0;
  final vad = List<int>.filled(3, 0);
  int lbrr = 0;
  final lbrrFlags = List<int>.filled(3, 0);
  int nFramesDecoded = 0, nFramesPerPacket = 0;
  _Resampler? resampler;
  // the parameters of the frame being decoded
  final gainsQ16 = Int32List(4);
  final predCoef = [Int16List(_maxLpc), Int16List(_maxLpc)];
  final pitchL = Int32List(4);
  final ltpCoef = Int16List(20);
  int ltpScaleQ14 = 0;

  void setFs(int kHz, int apiHz) {
    subfrLength = 5 * kHz;
    final frame = nbSubfr * subfrLength;
    if (fsKHz != kHz || fsApiHz != apiHz) {
      resampler = _Resampler(kHz * 1000, apiHz);
      fsApiHz = apiHz;
    }
    if (fsKHz != kHz || frame != frameLength) {
      if (kHz == 8) {
        pitchContourIcdf = nbSubfr == 4 ? silkPitchContourNBICDF : silkPitchContour10MsNBICDF;
      } else {
        pitchContourIcdf = nbSubfr == 4 ? silkPitchContourICDF : silkPitchContour10MsICDF;
      }
      if (fsKHz != kHz) {
        ltpMemLength = 20 * kHz;
        if (kHz == 8 || kHz == 12) {
          lpcOrder = 10;
          cb = _cbNbMb;
        } else {
          lpcOrder = 16;
          cb = _cbWb;
        }
        pitchLowBitsIcdf = kHz == 16 ? silkUniform8ICDF : (kHz == 12 ? silkUniform6ICDF : silkUniform4ICDF);
        firstFrameAfterReset = 1;
        lagPrev = 100;
        lastGainIndex = 10;
        prevSignalType = _typeNoVoice;
        outBuf.fillRange(0, outBuf.length, 0);
        sLpc.fillRange(0, sLpc.length, 0);
      }
      fsKHz = kHz;
      frameLength = frame;
    }
  }

  // ---- decode_indices ----
  void decodeIndices(RangeDecoder rc, int frameIndex, bool decodeLbrr, int cond) {
    final ix = indices;
    int v;
    if (decodeLbrr || vad[frameIndex] != 0) {
      v = rc.icdf(silkTypeOffsetVADICDF, 8) + 2;
    } else {
      v = rc.icdf(silkTypeOffsetNoVADICDF, 8);
    }
    ix.signalType = v >> 1;
    ix.quantOffsetType = v & 1;
    if (cond == _codeConditionally) {
      ix.gains[0] = rc.icdf(silkDeltaGainICDF, 8);
    } else {
      ix.gains[0] = rc.icdf(silkGainICDF, 8, ix.signalType * 8) << 3;
      ix.gains[0] += rc.icdf(silkUniform8ICDF, 8);
    }
    for (var i = 1; i < nbSubfr; i++) {
      ix.gains[i] = rc.icdf(silkDeltaGainICDF, 8);
    }
    final c = cb!;
    ix.nlsf[0] = rc.icdf(c.cb1Icdf, 8, (ix.signalType >> 1) * c.nVectors);
    final ecIx = List<int>.filled(_maxLpc, 0);
    _nlsfUnpack(ecIx, null, c, ix.nlsf[0]);
    for (var i = 0; i < c.order; i++) {
      var q = rc.icdf(c.ecIcdf, 8, ecIx[i]);
      if (q == 0) {
        q -= rc.icdf(silkNLSFEXTICDF, 8);
      } else if (q == 2 * _nlsfQuantMax) {
        q += rc.icdf(silkNLSFEXTICDF, 8);
      }
      ix.nlsf[i + 1] = q - _nlsfQuantMax;
    }
    ix.nlsfInterp = nbSubfr == 4 ? rc.icdf(silkNLSFInterpolationFactorICDF, 8) : 4;
    if (ix.signalType == _typeVoiced) {
      var absolute = true;
      if (cond == _codeConditionally && ecPrevSignalType == _typeVoiced) {
        var delta = rc.icdf(silkPitchDeltaICDF, 8);
        if (delta > 0) {
          delta -= 9;
          ix.lagIndex = ecPrevLagIndex + delta;
          absolute = false;
        }
      }
      if (absolute) {
        ix.lagIndex = rc.icdf(silkPitchLagICDF, 8) * (fsKHz >> 1);
        ix.lagIndex += rc.icdf(pitchLowBitsIcdf, 8);
      }
      ecPrevLagIndex = ix.lagIndex;
      ix.contourIndex = rc.icdf(pitchContourIcdf, 8);
      ix.perIndex = rc.icdf(silkLTPPerIndexICDF, 8);
      for (var k = 0; k < nbSubfr; k++) {
        ix.ltp[k] = rc.icdf(_ltpGainIcdf[ix.perIndex], 8);
      }
      ix.ltpScaleIndex = cond == _codeIndependently ? rc.icdf(silkLTPscaleICDF, 8) : 0;
    }
    ecPrevSignalType = ix.signalType;
    ix.seed = rc.icdf(silkUniform4ICDF, 8);
  }

  void _nlsfUnpack(List<int> ecIx, List<int>? pred, _NlsfCb c, int cb1) {
    var sel = cb1 * c.order ~/ 2;
    for (var i = 0; i < c.order; i += 2) {
      final entry = c.ecSel[sel++];
      ecIx[i] = ((entry >> 1) & 7) * (2 * _nlsfQuantMax + 1);
      if (pred != null) pred[i] = c.pred[i + (entry & 1) * (c.order - 1)];
      ecIx[i + 1] = ((entry >> 5) & 7) * (2 * _nlsfQuantMax + 1);
      if (pred != null) pred[i + 1] = c.pred[i + ((entry >> 4) & 1) * (c.order - 1) + 1];
    }
  }

  // ---- decode_pulses ----
  void decodePulses(RangeDecoder rc, Int16List pulses, int signalType, int quantOffsetType, int frameLen) {
    final rateLevel = rc.icdf(silkRateLevelsICDF, 8, (signalType >> 1) * 9);
    var iter = frameLen >> 4;
    if (iter * 16 < frameLen) iter++;
    final sums = List<int>.filled(20, 0), shifts = List<int>.filled(20, 0);
    for (var i = 0; i < iter; i++) {
      shifts[i] = 0;
      sums[i] = rc.icdf(silkPulsesPerBlockICDF, 8, rateLevel * 18);
      while (sums[i] == 17) {
        shifts[i]++;
        sums[i] = rc.icdf(silkPulsesPerBlockICDF, 8, 9 * 18 + (shifts[i] == 10 ? 1 : 0));
      }
    }
    for (var i = 0; i < iter; i++) {
      if (sums[i] > 0) {
        _shell(pulses, i * 16, rc, sums[i]);
      } else {
        pulses.fillRange(i * 16, i * 16 + 16, 0);
      }
    }
    for (var i = 0; i < iter; i++) {
      if (shifts[i] > 0) {
        final n = shifts[i];
        for (var k = 0; k < 16; k++) {
          var a = pulses[i * 16 + k];
          for (var j = 0; j < n; j++) {
            a <<= 1;
            a += rc.icdf(silkLsbICDF, 8);
          }
          pulses[i * 16 + k] = a;
        }
        sums[i] |= n << 5;
      }
    }
    // signs
    var base = 7 * ((quantOffsetType) + (signalType << 1));
    final blocks = (frameLen + 8) >> 4;
    final icdf = [0, 0];
    for (var i = 0; i < blocks; i++) {
      final p = sums[i];
      if (p > 0) {
        icdf[0] = silkSignICDF[base + math.min(p & 0x1F, 6)];
        for (var j = 0; j < 16; j++) {
          if (pulses[i * 16 + j] > 0) {
            pulses[i * 16 + j] *= (rc.icdf(icdf, 8) << 1) - 1;
          }
        }
      }
    }
  }

  void _shell(Int16List p0, int o, RangeDecoder rc, int total) {
    final p3 = Int16List(2), p2 = Int16List(4), p1 = Int16List(8);
    void sp(Int16List out, int a, int b, int parent, Uint8List t, [int off = 0]) {
      // (children are stored in [out] at a and b)
      if (parent > 0) {
        final x = rc.icdf(t, 8, silkShellCodeTableOffsets[parent]);
        out[a] = x;
        out[b] = parent - x;
      } else {
        out[a] = 0;
        out[b] = 0;
      }
    }

    sp(p3, 0, 1, total, silkShellCodeTable3);
    sp(p2, 0, 1, p3[0], silkShellCodeTable2);
    sp(p1, 0, 1, p2[0], silkShellCodeTable1);
    sp(p0, o + 0, o + 1, p1[0], silkShellCodeTable0);
    sp(p0, o + 2, o + 3, p1[1], silkShellCodeTable0);
    sp(p1, 2, 3, p2[1], silkShellCodeTable1);
    sp(p0, o + 4, o + 5, p1[2], silkShellCodeTable0);
    sp(p0, o + 6, o + 7, p1[3], silkShellCodeTable0);
    sp(p2, 2, 3, p3[1], silkShellCodeTable2);
    sp(p1, 4, 5, p2[2], silkShellCodeTable1);
    sp(p0, o + 8, o + 9, p1[4], silkShellCodeTable0);
    sp(p0, o + 10, o + 11, p1[5], silkShellCodeTable0);
    sp(p1, 6, 7, p2[3], silkShellCodeTable1);
    sp(p0, o + 12, o + 13, p1[6], silkShellCodeTable0);
    sp(p0, o + 14, o + 15, p1[7], silkShellCodeTable0);
  }

  // ---- decode_parameters ----
  void decodeParameters(int cond) {
    final ix = indices;
    // gains
    for (var k = 0; k < nbSubfr; k++) {
      if (k == 0 && cond != _codeConditionally) {
        lastGainIndex = math.max(ix.gains[k], lastGainIndex - 16);
      } else {
        final tmp = ix.gains[k] - 4;
        final thr = 2 * 36 - 64 + lastGainIndex;
        if (tmp > thr) {
          lastGainIndex += (tmp << 1) - thr;
        } else {
          lastGainIndex += tmp;
        }
      }
      lastGainIndex = _limit(lastGainIndex, 0, 63);
      gainsQ16[k] = _log2lin(math.min(_smulwb(_invScaleQ16, lastGainIndex) + _gainOffset, 3967));
    }
    final nlsf = Int16List(_maxLpc);
    _nlsfDecode(nlsf);
    _nlsf2a(predCoef[1], nlsf, lpcOrder);
    if (firstFrameAfterReset == 1) ix.nlsfInterp = 4;
    if (ix.nlsfInterp < 4) {
      final n0 = Int16List(_maxLpc);
      for (var i = 0; i < lpcOrder; i++) {
        n0[i] = prevNlsf[i] + ((ix.nlsfInterp * (nlsf[i] - prevNlsf[i])) >> 2);
      }
      _nlsf2a(predCoef[0], n0, lpcOrder);
    } else {
      predCoef[0].setRange(0, lpcOrder, predCoef[1]);
    }
    prevNlsf.setRange(0, lpcOrder, nlsf);
    if (ix.signalType == _typeVoiced) {
      _decodePitch();
      final vq = _ltpVq[ix.perIndex];
      for (var k = 0; k < nbSubfr; k++) {
        final id = ix.ltp[k];
        for (var i = 0; i < _ltpOrder; i++) {
          ltpCoef[k * _ltpOrder + i] = vq[id * _ltpOrder + i] << 7;
        }
      }
      ltpScaleQ14 = silkLTPScalesTableQ14[ix.ltpScaleIndex];
    } else {
      pitchL.fillRange(0, 4, 0);
      ltpCoef.fillRange(0, 20, 0);
      ix.perIndex = 0;
      ltpScaleQ14 = 0;
    }
  }

  static final int _gainOffset = (2 * 128) ~/ 6 + 16 * 128;
  static final int _invScaleQ16 = (65536 * (((88 - 2) * 128) ~/ 6)) ~/ 63;

  void _decodePitch() {
    final ix = indices;
    final List<int> table;
    final int size;
    if (fsKHz == 8) {
      if (nbSubfr == 4) {
        table = silkCBLagsStage2;
        size = 11;
      } else {
        table = silkCBLagsStage210Ms;
        size = 3;
      }
    } else if (nbSubfr == 4) {
      table = silkCBLagsStage3;
      size = 34;
    } else {
      table = silkCBLagsStage310Ms;
      size = 12;
    }
    final minLag = 2 * fsKHz, maxLag = 18 * fsKHz;
    final lag = minLag + ix.lagIndex;
    for (var k = 0; k < nbSubfr; k++) {
      pitchL[k] = _limit(lag + table[k * size + ix.contourIndex], minLag, maxLag);
    }
  }

  void _nlsfDecode(Int16List out) {
    final c = cb!;
    final ix = indices;
    final pred = List<int>.filled(_maxLpc, 0), ecIx = List<int>.filled(_maxLpc, 0);
    _nlsfUnpack(ecIx, pred, c, ix.nlsf[0]);
    final res = Int16List(_maxLpc);
    var outQ10 = 0;
    for (var i = c.order - 1; i >= 0; i--) {
      final predQ10 = _smulbb(outQ10, pred[i]) >> 8;
      outQ10 = ix.nlsf[i + 1] << 10;
      if (outQ10 > 0) {
        outQ10 -= 102;
      } else if (outQ10 < 0) {
        outQ10 += 102;
      }
      outQ10 = _smlawb(predQ10, outQ10, c.quantStep);
      res[i] = outQ10;
    }
    final b = ix.nlsf[0] * c.order;
    for (var i = 0; i < c.order; i++) {
      final tmp = _div32_16(res[i] << 14, c.wght[b + i]) + (c.cb1[b + i] << 7);
      out[i] = _limit(tmp, 0, 32767);
    }
    _nlsfStabilize(out, c.deltaMin, c.order);
  }

  void _nlsfStabilize(Int16List nlsf, List<int> dm, int l) {
    var loops = 0;
    for (; loops < 20; loops++) {
      var minDiff = nlsf[0] - dm[0];
      var idx = 0;
      for (var i = 1; i <= l - 1; i++) {
        final diff = nlsf[i] - (nlsf[i - 1] + dm[i]);
        if (diff < minDiff) {
          minDiff = diff;
          idx = i;
        }
      }
      final diff = (1 << 15) - (nlsf[l - 1] + dm[l]);
      if (diff < minDiff) {
        minDiff = diff;
        idx = l;
      }
      if (minDiff >= 0) return;
      if (idx == 0) {
        nlsf[0] = dm[0];
      } else if (idx == l) {
        nlsf[l - 1] = (1 << 15) - dm[l];
      } else {
        var minCenter = 0;
        for (var k = 0; k < idx; k++) {
          minCenter += dm[k];
        }
        minCenter += dm[idx] >> 1;
        var maxCenter = 1 << 15;
        for (var k = l; k > idx; k--) {
          maxCenter -= dm[k];
        }
        maxCenter -= dm[idx] >> 1;
        final center = _limit(_rshiftRound(nlsf[idx - 1] + nlsf[idx], 1), minCenter, maxCenter);
        nlsf[idx - 1] = center - (dm[idx] >> 1);
        nlsf[idx] = nlsf[idx - 1] + dm[idx];
      }
    }
    // sort and force the spacing
    for (var i = 1; i < l; i++) {
      final v = nlsf[i];
      var j = i - 1;
      for (; j >= 0 && v < nlsf[j]; j--) {
        nlsf[j + 1] = nlsf[j];
      }
      nlsf[j + 1] = v;
    }
    nlsf[0] = math.max(nlsf[0], dm[0]);
    for (var i = 1; i < l; i++) {
      nlsf[i] = math.max(nlsf[i], _sat16(nlsf[i - 1] + dm[i]));
    }
    nlsf[l - 1] = math.min(nlsf[l - 1], (1 << 15) - dm[l]);
    for (var i = l - 2; i >= 0; i--) {
      nlsf[i] = math.min(nlsf[i], nlsf[i + 1] - dm[i + 1]);
    }
  }

  // ---- NLSF2A ----
  static const _ordering16 = [0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1];
  static const _ordering10 = [0, 9, 6, 3, 4, 5, 8, 1, 2, 7];

  void _findPoly(List<int> out, List<int> c, int cOff, int dd) {
    out[0] = 1 << 16;
    out[1] = -c[cOff];
    for (var k = 1; k < dd; k++) {
      final ftmp = c[cOff + 2 * k];
      out[k + 1] = ((out[k - 1] << 1) - _rshiftRound(ftmp * out[k], 16)).toSigned(32);
      for (var n = k; n > 1; n--) {
        out[n] = (out[n] + out[n - 2] - _rshiftRound(ftmp * out[n - 1], 16)).toSigned(32);
      }
      out[1] = (out[1] - ftmp).toSigned(32);
    }
  }

  void _nlsf2a(Int16List a, Int16List nlsf, int d) {
    final ordering = d == 16 ? _ordering16 : _ordering10;
    final cosQa = List<int>.filled(24, 0);
    for (var k = 0; k < d; k++) {
      final fInt = nlsf[k] >> 8;
      final fFrac = nlsf[k] - (fInt << 8);
      final cosVal = silkLSFCosTabFIXQ12[fInt];
      final delta = silkLSFCosTabFIXQ12[fInt + 1] - cosVal;
      cosQa[ordering[k]] = _rshiftRound((cosVal << 8) + delta * fFrac, 4);
    }
    final dd = d >> 1;
    final p = List<int>.filled(13, 0), q = List<int>.filled(13, 0);
    _findPoly(p, cosQa, 0, dd);
    _findPoly(q, cosQa, 1, dd);
    final a32 = List<int>.filled(24, 0);
    for (var k = 0; k < dd; k++) {
      final ptmp = p[k + 1] + p[k];
      final qtmp = q[k + 1] - q[k];
      a32[k] = (-qtmp - ptmp).toSigned(32);
      a32[d - k - 1] = (qtmp - ptmp).toSigned(32);
    }
    _lpcFit(a, a32, 12, 17, d);
    for (var i = 0; _lpcInversePredGain(a, d) == 0 && i < 16; i++) {
      _bwexpander32(a32, d, 65536 - (2 << i));
      for (var k = 0; k < d; k++) {
        a[k] = _rshiftRound(a32[k], 17 - 12);
      }
    }
  }

  void _bwexpander32(List<int> ar, int d, int chirp) {
    final minusOne = chirp - 65536;
    for (var i = 0; i < d - 1; i++) {
      ar[i] = _smulww(chirp, ar[i]);
      chirp += _rshiftRound(chirp * minusOne, 16);
    }
    ar[d - 1] = _smulww(chirp, ar[d - 1]);
  }

  void _lpcFit(Int16List out, List<int> aIn, int qOut, int qIn, int d) {
    var i = 0, idx = 0;
    for (; i < 10; i++) {
      var maxabs = 0;
      for (var k = 0; k < d; k++) {
        final v = aIn[k].abs();
        if (v > maxabs) {
          maxabs = v;
          idx = k;
        }
      }
      maxabs = _rshiftRound(maxabs, qIn - qOut);
      if (maxabs > 32767) {
        maxabs = math.min(maxabs, 163838);
        final chirp = (0.999 * 65536 + 0.5).toInt() - (((maxabs - 32767) << 14) ~/ ((maxabs * (idx + 1)) >> 2));
        _bwexpander32(aIn, d, chirp);
      } else {
        break;
      }
    }
    if (i == 10) {
      for (var k = 0; k < d; k++) {
        out[k] = _sat16(_rshiftRound(aIn[k], qIn - qOut));
        aIn[k] = out[k] << (qIn - qOut);
      }
    } else {
      for (var k = 0; k < d; k++) {
        out[k] = _rshiftRound(aIn[k], qIn - qOut);
      }
    }
  }

  static final int _aLimit = (0.99975 * (1 << 24) + 0.5).toInt();

  int _lpcInversePredGain(Int16List a12, int order) {
    final a = List<int>.filled(24, 0);
    var dc = 0;
    for (var k = 0; k < order; k++) {
      dc += a12[k];
      a[k] = a12[k] << 12;
    }
    if (dc >= 4096) return 0;
    var inv = 1 << 30;
    int mulFrac(int x, int y) => _rshiftRound(x * y, 31);
    int k;
    for (k = order - 1; k > 0; k--) {
      if (a[k] > _aLimit || a[k] < -_aLimit) return 0;
      final rc = (-(a[k] << 7)).toSigned(32);
      final rcMult1 = (1 << 30) - _smmul(rc, rc);
      inv = (_smmul(inv, rcMult1) << 2).toSigned(32);
      if (inv < 107374) return 0;
      final mult2Q = 32 - _clz32(rcMult1.abs());
      final rcMult2 = _inverse32VarQ(rcMult1, mult2Q + 30);
      for (var n = 0; n < (k + 1) >> 1; n++) {
        final tmp1 = a[n], tmp2 = a[k - n - 1];
        var t64 = _rshiftRound((_subSat32(tmp1, mulFrac(tmp2, rc))) * rcMult2, mult2Q);
        if (t64 > 0x7FFFFFFF || t64 < -0x80000000) return 0;
        a[n] = t64;
        t64 = _rshiftRound((_subSat32(tmp2, mulFrac(tmp1, rc))) * rcMult2, mult2Q);
        if (t64 > 0x7FFFFFFF || t64 < -0x80000000) return 0;
        a[k - n - 1] = t64;
      }
    }
    if (a[k] > _aLimit || a[k] < -_aLimit) return 0;
    final rc = (-(a[0] << 7)).toSigned(32);
    final rcMult1 = (1 << 30) - _smmul(rc, rc);
    inv = (_smmul(inv, rcMult1) << 2).toSigned(32);
    if (inv < 107374) return 0;
    return inv;
  }

  int _subSat32(int a, int b) {
    final s = a - b;
    return s > 0x7FFFFFFF ? 0x7FFFFFFF : (s < -0x80000000 ? -0x80000000 : s);
  }

  // ---- decode_core ----
  void decodeCore(Int16List xq, int xqOff, Int16List pulses) {
    final ix = indices;
    final sLtp = Int16List(ltpMemLength);
    final sLtpQ15 = Int32List(ltpMemLength + frameLength);
    final res = Int32List(subfrLength);
    final sLpc = Int32List(subfrLength + _maxLpc);
    final offsetQ10 = silkQuantizationOffsetsQ10[(ix.signalType >> 1) * 2 + ix.quantOffsetType];
    final interp = ix.nlsfInterp < 4;
    var seed = ix.seed.toSigned(32);
    for (var i = 0; i < frameLength; i++) {
      seed = _rand(seed);
      var e = pulses[i] << 14;
      if (e > 0) {
        e -= _quantOffset10 << 4;
      } else if (e < 0) {
        e += _quantOffset10 << 4;
      }
      e += offsetQ10 << 4;
      if (seed < 0) e = -e;
      exc[i] = e;
      seed = (seed + pulses[i]).toSigned(32);
    }
    for (var i = 0; i < _maxLpc; i++) {
      sLpc[i] = this.sLpc[i];
    }
    var pexc = 0;
    var pxq = xqOff;
    var sLtpBufIdx = ltpMemLength;
    var lag = 0;
    for (var k = 0; k < nbSubfr; k++) {
      final a = predCoef[k >> 1];
      final bOff = k * _ltpOrder;
      final gainQ10 = gainsQ16[k] >> 6;
      var invGainQ31 = _inverse32VarQ(gainsQ16[k], 47);
      int gainAdj;
      if (gainsQ16[k] != prevGainQ16) {
        gainAdj = _div32VarQ(prevGainQ16, gainsQ16[k], 16);
        for (var i = 0; i < _maxLpc; i++) {
          sLpc[i] = _smulww(gainAdj, sLpc[i]);
        }
      } else {
        gainAdj = 1 << 16;
      }
      prevGainQ16 = gainsQ16[k];
      final signalType = ix.signalType;
      List<int> pres;
      int presOff;
      if (signalType == _typeVoiced) {
        lag = pitchL[k];
        if (k == 0 || (k == 2 && interp)) {
          final startIdx = ltpMemLength - lag - lpcOrder - _ltpOrder ~/ 2;
          if (k == 2) {
            for (var i = 0; i < 2 * subfrLength; i++) {
              outBuf[ltpMemLength + i] = xq[xqOff + i];
            }
          }
          _lpcAnalysis(sLtp, startIdx, outBuf, startIdx + k * subfrLength, a, ltpMemLength - startIdx, lpcOrder);
          if (k == 0) {
            invGainQ31 = (_smulwb(invGainQ31, ltpScaleQ14) << 2).toSigned(32);
          }
          for (var i = 0; i < lag + _ltpOrder ~/ 2; i++) {
            sLtpQ15[sLtpBufIdx - i - 1] = _smulwb(invGainQ31, sLtp[ltpMemLength - i - 1]);
          }
        } else if (gainAdj != 1 << 16) {
          for (var i = 0; i < lag + _ltpOrder ~/ 2; i++) {
            sLtpQ15[sLtpBufIdx - i - 1] = _smulww(gainAdj, sLtpQ15[sLtpBufIdx - i - 1]);
          }
        }
        var pred = sLtpBufIdx - lag + _ltpOrder ~/ 2;
        for (var i = 0; i < subfrLength; i++) {
          var ltp = 2;
          ltp = _smlawb(ltp, sLtpQ15[pred], ltpCoef[bOff]);
          ltp = _smlawb(ltp, sLtpQ15[pred - 1], ltpCoef[bOff + 1]);
          ltp = _smlawb(ltp, sLtpQ15[pred - 2], ltpCoef[bOff + 2]);
          ltp = _smlawb(ltp, sLtpQ15[pred - 3], ltpCoef[bOff + 3]);
          ltp = _smlawb(ltp, sLtpQ15[pred - 4], ltpCoef[bOff + 4]);
          pred++;
          res[i] = (exc[pexc + i] + (ltp << 1)).toSigned(32);
          sLtpQ15[sLtpBufIdx] = (res[i] << 1).toSigned(32);
          sLtpBufIdx++;
        }
        pres = res;
        presOff = 0;
      } else {
        pres = exc;
        presOff = pexc;
      }
      for (var i = 0; i < subfrLength; i++) {
        var p = lpcOrder >> 1;
        for (var j = 0; j < lpcOrder; j++) {
          p = _smlawb(p, sLpc[_maxLpc + i - 1 - j], a[j]);
        }
        sLpc[_maxLpc + i] = _addSat32(pres[presOff + i], _lshiftSat32(p, 4));
        xq[pxq + i] = _sat16(_rshiftRound(_smulww(sLpc[_maxLpc + i], gainQ10), 8));
      }
      for (var i = 0; i < _maxLpc; i++) {
        sLpc[i] = sLpc[subfrLength + i];
      }
      pexc += subfrLength;
      pxq += subfrLength;
    }
    for (var i = 0; i < _maxLpc; i++) {
      this.sLpc[i] = sLpc[i];
    }
  }

  void _lpcAnalysis(Int16List out, int outOff, Int16List input, int inOff, Int16List b, int len, int d) {
    for (var ix = d; ix < len; ix++) {
      final p = inOff + ix - 1;
      var acc = _smulbb(input[p], b[0]);
      for (var j = 1; j < d; j++) {
        acc = (acc + input[p - j] * b[j]).toSigned(32);
      }
      acc = ((input[p + 1] << 12) - acc).toSigned(32);
      out[outOff + ix] = _sat16(_rshiftRound(acc, 12));
    }
    out.fillRange(outOff, outOff + d, 0);
  }
}

// ---- the decoder over both channels ----

/// SILK (the speech part of Opus, RFC 6716 section 4.2): a port of libopus' decoder without the repair of lost packets.
class SilkDecoder {
  final _ch = [_Channel(), _Channel()];
  final _predPrev = [0, 0];
  final _sMid = Int16List(2), _sSide = Int16List(2);
  int _nApi = 0, _nInternal = 0, _prevOnlyMiddle = 0;

  void reset() {
    _ch[0] = _Channel();
    _ch[1] = _Channel();
    _predPrev.fillRange(0, 2, 0);
    _sMid.fillRange(0, 2, 0);
    _sSide.fillRange(0, 2, 0);
    _nApi = 0;
    _nInternal = 0;
    _prevOnlyMiddle = 0;
  }

  /// One call of `silk_Decode`: the next SILK frame (10 or 20 ms) of the packet. [payloadMs] is the length of the whole Opus frame,
  /// [internalRate] 8000, 12000 or 16000. Returns [nApi] lists of samples at [apiRate] (all the same length).
  List<Int16List> decode(RangeDecoder rc, {required int apiRate, required int nApi, required int nInternal, required int internalRate, required int payloadMs, required bool newPacket}) {
    if (newPacket) {
      for (var n = 0; n < nInternal; n++) {
        _ch[n].nFramesDecoded = 0;
      }
    }
    if (nInternal > _nInternal) _ch[1] = _Channel();
    final stereoToMono = nInternal == 1 && _nInternal == 2 && internalRate == 1000 * _ch[0].fsKHz;
    if (_ch[0].nFramesDecoded == 0) {
      for (var n = 0; n < nInternal; n++) {
        final c = _ch[n];
        switch (payloadMs) {
          case 10:
            c.nFramesPerPacket = 1;
            c.nbSubfr = 2;
          case 20:
            c.nFramesPerPacket = 1;
            c.nbSubfr = 4;
          case 40:
            c.nFramesPerPacket = 2;
            c.nbSubfr = 4;
          case 60:
            c.nFramesPerPacket = 3;
            c.nbSubfr = 4;
          default:
            throw const AudioFormatException('Opus: bad SILK frame size.');
        }
        final kHz = (internalRate >> 10) + 1;
        if (kHz != 8 && kHz != 12 && kHz != 16) throw const AudioFormatException('Opus: bad SILK rate.');
        c.setFs(kHz, apiRate);
      }
    }
    if (nApi == 2 && nInternal == 2 && (_nApi == 1 || _nInternal == 1)) {
      _predPrev.fillRange(0, 2, 0);
      _sSide.fillRange(0, 2, 0);
      final r = _ch[0].resampler!;
      final copy = _Resampler(r.fsIn, r.fsOut);
      copy.delayBuf.setAll(0, r.delayBuf);
      copy.iir.setAll(0, r.iir);
      copy.fir.setAll(0, r.fir);
      _ch[1].resampler = copy;
    }
    _nApi = nApi;
    _nInternal = nInternal;
    final msPred = [0, 0];
    var onlyMiddle = 0;
    if (_ch[0].nFramesDecoded == 0) {
      for (var n = 0; n < nInternal; n++) {
        final c = _ch[n];
        for (var i = 0; i < c.nFramesPerPacket; i++) {
          c.vad[i] = rc.bitLogp(1);
        }
        c.lbrr = rc.bitLogp(1);
      }
      for (var n = 0; n < nInternal; n++) {
        final c = _ch[n];
        c.lbrrFlags.fillRange(0, 3, 0);
        if (c.lbrr != 0) {
          if (c.nFramesPerPacket == 1) {
            c.lbrrFlags[0] = 1;
          } else {
            final table = c.nFramesPerPacket == 2 ? silkLBRRFlags2ICDF : silkLBRRFlags3ICDF;
            final symbol = rc.icdf(table, 8) + 1;
            for (var i = 0; i < c.nFramesPerPacket; i++) {
              c.lbrrFlags[i] = (symbol >> i) & 1;
            }
          }
        }
      }
      // (the redundant coding of lost packets is read and dropped)
      final scratch = Int16List(320);
      for (var i = 0; i < _ch[0].nFramesPerPacket; i++) {
        for (var n = 0; n < nInternal; n++) {
          final c = _ch[n];
          if (c.lbrrFlags[i] != 0) {
            if (nInternal == 2 && n == 0) {
              _stereoPred(rc, msPred);
              if (_ch[1].lbrrFlags[i] == 0) onlyMiddle = _stereoMidOnly(rc);
            }
            final cond = i > 0 && c.lbrrFlags[i - 1] != 0 ? _codeConditionally : _codeIndependently;
            c.decodeIndices(rc, i, true, cond);
            c.decodePulses(rc, scratch, c.indices.signalType, c.indices.quantOffsetType, c.frameLength);
          }
        }
      }
    }
    if (nInternal == 2) {
      _stereoPred(rc, msPred);
      if (_ch[1].vad[_ch[0].nFramesDecoded] == 0) {
        onlyMiddle = _stereoMidOnly(rc);
      } else {
        onlyMiddle = 0;
      }
    }
    if (nInternal == 2 && onlyMiddle == 0 && _prevOnlyMiddle == 1) {
      final c = _ch[1];
      c.outBuf.fillRange(0, c.outBuf.length, 0);
      c.sLpc.fillRange(0, c.sLpc.length, 0);
      c.lagPrev = 100;
      c.lastGainIndex = 10;
      c.prevSignalType = _typeNoVoice;
      c.firstFrameAfterReset = 1;
    }
    final frameLen = _ch[0].frameLength;
    final tmp = [Int16List(frameLen + 2), Int16List(frameLen + 2)];
    final hasSide = onlyMiddle == 0;
    for (var n = 0; n < nInternal; n++) {
      final c = _ch[n];
      if (n == 0 || hasSide) {
        final frameIndex = _ch[0].nFramesDecoded - n;
        int cond;
        if (frameIndex <= 0) {
          cond = _codeIndependently;
        } else if (n > 0 && _prevOnlyMiddle == 1) {
          cond = _codeIndependentlyNoLtp;
        } else {
          cond = _codeConditionally;
        }
        _decodeFrame(c, rc, tmp[n], 2, cond);
      }
      c.nFramesDecoded++;
    }
    if (nApi == 2 && nInternal == 2) {
      _msToLr(tmp[0], tmp[1], msPred, _ch[0].fsKHz, frameLen);
    } else {
      tmp[0][0] = _sMid[0];
      tmp[0][1] = _sMid[1];
      _sMid[0] = tmp[0][frameLen];
      _sMid[1] = tmp[0][frameLen + 1];
    }
    final nOut = frameLen * apiRate ~/ (_ch[0].fsKHz * 1000);
    final out = [for (var i = 0; i < nApi; i++) Int16List(nOut)];
    for (var n = 0; n < math.min(nApi, nInternal); n++) {
      _ch[n].resampler!.process(out[n], tmp[n], 1, frameLen);
    }
    if (nApi == 2 && nInternal == 1) {
      if (stereoToMono) {
        _ch[1].resampler!.process(out[1], tmp[0], 1, frameLen);
      } else {
        out[1].setAll(0, out[0]);
      }
    }
    _prevOnlyMiddle = onlyMiddle;
    return out;
  }

  void _decodeFrame(_Channel c, RangeDecoder rc, Int16List out, int outOff, int cond) {
    final pulses = Int16List(336);
    c.decodeIndices(rc, c.nFramesDecoded, false, cond);
    c.decodePulses(rc, pulses, c.indices.signalType, c.indices.quantOffsetType, c.frameLength);
    c.decodeParameters(cond);
    c.decodeCore(out, outOff, pulses);
    final mv = c.ltpMemLength - c.frameLength;
    c.outBuf.setRange(0, mv, c.outBuf, c.frameLength);
    for (var i = 0; i < c.frameLength; i++) {
      c.outBuf[mv + i] = out[outOff + i];
    }
    c.prevSignalType = c.indices.signalType;
    c.firstFrameAfterReset = 0;
    c.lagPrev = c.pitchL[c.nbSubfr - 1];
  }

  void _stereoPred(RangeDecoder rc, List<int> pred) {
    var n = rc.icdf(silkStereoPredJointICDF, 8);
    final ix = [
      [0, 0, n ~/ 5],
      [0, 0, 0]
    ];
    ix[1][2] = n - 5 * ix[0][2];
    for (n = 0; n < 2; n++) {
      ix[n][0] = rc.icdf(silkUniform3ICDF, 8);
      ix[n][1] = rc.icdf(silkUniform5ICDF, 8);
    }
    for (n = 0; n < 2; n++) {
      ix[n][0] += 3 * ix[n][2];
      final low = silkStereoPredQuantQ13[ix[n][0]];
      final step = _smulwb(silkStereoPredQuantQ13[ix[n][0] + 1] - low, (0.5 / 5 * 65536 + 0.5).toInt());
      pred[n] = _smlabb(low, step, 2 * ix[n][1] + 1);
    }
    pred[0] -= pred[1];
  }

  int _stereoMidOnly(RangeDecoder rc) => rc.icdf(silkStereoOnlyCodeMidICDF, 8);

  void _msToLr(Int16List x1, Int16List x2, List<int> pred, int fsKHz, int frameLength) {
    x1[0] = _sMid[0];
    x1[1] = _sMid[1];
    x2[0] = _sSide[0];
    x2[1] = _sSide[1];
    _sMid[0] = x1[frameLength];
    _sMid[1] = x1[frameLength + 1];
    _sSide[0] = x2[frameLength];
    _sSide[1] = x2[frameLength + 1];
    var pred0 = _predPrev[0], pred1 = _predPrev[1];
    final denom = _div32_16(1 << 16, 8 * fsKHz);
    final delta0 = _rshiftRound(_smulbb(pred[0] - _predPrev[0], denom), 16);
    final delta1 = _rshiftRound(_smulbb(pred[1] - _predPrev[1], denom), 16);
    final interp = 8 * fsKHz;
    for (var n = 0; n < interp; n++) {
      pred0 += delta0;
      pred1 += delta1;
      var sum = (x1[n] + x1[n + 2] + (x1[n + 1] << 1)) << 9;
      sum = _smlawb(x2[n + 1] << 8, sum, pred0);
      sum = _smlawb(sum, x1[n + 1] << 11, pred1);
      x2[n + 1] = _sat16(_rshiftRound(sum, 8));
    }
    pred0 = pred[0];
    pred1 = pred[1];
    for (var n = interp; n < frameLength; n++) {
      var sum = (x1[n] + x1[n + 2] + (x1[n + 1] << 1)) << 9;
      sum = _smlawb(x2[n + 1] << 8, sum, pred0);
      sum = _smlawb(sum, x1[n + 1] << 11, pred1);
      x2[n + 1] = _sat16(_rshiftRound(sum, 8));
    }
    _predPrev[0] = pred[0];
    _predPrev[1] = pred[1];
    for (var n = 0; n < frameLength; n++) {
      final sum = x1[n + 1] + x2[n + 1];
      final diff = x1[n + 1] - x2[n + 1];
      x1[n + 1] = _sat16(sum);
      x2[n + 1] = _sat16(diff);
    }
  }
}
