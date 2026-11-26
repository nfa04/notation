import 'dart:math' as math;
import 'dart:typed_data';

import 'celt_bands.dart';
import 'celt_math.dart';
import 'celt_tables.dart';
import 'range_decoder.dart';

const _decodeBuffer = 2048;
const _overlap = 120;
const _shortMdct = 120;
const _minPeriod = 15;

const _combGains = [
  [0.3066406250, 0.2170410156, 0.1296386719],
  [0.4638671875, 0.2680664062, 0.0],
  [0.7998046875, 0.1000976562, 0.0],
];

/// The CELT part of Opus (RFC 6716 section 4.3), decoding at 48 kHz: a port of libopus' float decoder without the packet loss concealment.
class CeltDecoder {
  /// The channels of the output.
  final int channels;
  int start = 0, end = nbEBands;
  final _mdct = CeltMdct();
  late final List<Float64List> _mem = [for (var c = 0; c < channels; c++) Float64List(_decodeBuffer + _overlap)];
  final _oldBandE = Float64List(2 * nbEBands);
  final _oldLogE = Float64List(2 * nbEBands);
  final _oldLogE2 = Float64List(2 * nbEBands);
  final _preemph = Float64List(2);
  int _rng = 0;
  int _period = 0, _periodOld = 0, _tapset = 0, _tapsetOld = 0;
  double _gain = 0, _gainOld = 0;

  CeltDecoder(this.channels) {
    reset();
  }

  void reset() {
    for (final m in _mem) {
      m.fillRange(0, m.length, 0);
    }
    _oldBandE.fillRange(0, 2 * nbEBands, 0);
    _oldLogE.fillRange(0, 2 * nbEBands, -28);
    _oldLogE2.fillRange(0, 2 * nbEBands, -28);
    _preemph.fillRange(0, 2, 0);
    _rng = 0;
    _period = _periodOld = _tapset = _tapsetOld = 0;
    _gain = _gainOld = 0;
    start = 0;
    end = nbEBands;
  }

  /// Decodes one frame of [frameSize] samples (at 48 kHz: 120, 240, 480 or 960) from [len] bytes of [data] at [offset], or goes on in
  /// [dec] when the range decoder is shared with SILK (hybrid). [streamChannels] is what the packet holds (1 or 2). Returns one list
  /// per output channel with samples in -1..1.
  List<Float64List> decode(Uint8List data, int offset, int len, RangeDecoder? decIn, int frameSize, int streamChannels) {
    var lm = 0;
    while ((_shortMdct << lm) != frameSize) {
      lm++;
      if (lm > 3) throw const FormatException('Opus: bad CELT frame size.');
    }
    final n = frameSize;
    final c = streamChannels;
    final cc = channels;
    final out = [for (var i = 0; i < cc; i++) Float64List(n)];
    if (len <= 1 && decIn == null) {
      // (a lost or empty frame: silence, the memory moves on)
      for (var i = 0; i < cc; i++) {
        _mem[i].setRange(0, _decodeBuffer - n + _overlap, _mem[i], n);
        _mem[i].fillRange(_decodeBuffer - n + _overlap, _decodeBuffer + _overlap, 0);
      }
      return out;
    }
    final dec = decIn ?? RangeDecoder(Uint8List.sublistView(data, offset, offset + len));
    final totalBitsInit = len * 8;
    final effEnd = math.min(end, nbEBands);
    if (c == 1) {
      for (var i = 0; i < nbEBands; i++) {
        _oldBandE[i] = math.max(_oldBandE[i], _oldBandE[nbEBands + i]);
      }
    }
    var tell = dec.tell();
    var silence = false;
    if (tell >= totalBitsInit) {
      silence = true;
    } else if (tell == 1) {
      silence = dec.bitLogp(15) == 1;
    }
    if (silence) {
      tell = len * 8;
      dec.nbitsTotal += tell - dec.tell();
    }
    var postPitch = 0, postTapset = 0;
    var postGain = 0.0;
    if (start == 0 && tell + 16 <= totalBitsInit) {
      if (dec.bitLogp(1) == 1) {
        final octave = dec.uint(6);
        postPitch = (16 << octave) + dec.bits(4 + octave) - 1;
        final qg = dec.bits(3);
        if (dec.tell() + 2 <= totalBitsInit) postTapset = dec.icdf(tapsetIcdf, 2);
        postGain = .09375 * (qg + 1);
      }
      tell = dec.tell();
    }
    var isTransient = false;
    if (lm > 0 && tell + 3 <= totalBitsInit) {
      isTransient = dec.bitLogp(3) == 1;
      tell = dec.tell();
    }
    final intra = tell + 3 <= totalBitsInit ? dec.bitLogp(3) == 1 : false;
    unquantCoarseEnergy(start, end, _oldBandE, intra, dec, c, lm);
    final tfRes = List<int>.filled(nbEBands, 0);
    _tfDecode(start, end, isTransient, tfRes, lm, dec);
    tell = dec.tell();
    var spread = spreadNormal;
    if (tell + 4 <= totalBitsInit) spread = dec.icdf(spreadIcdf, 5);
    final cap = List<int>.filled(nbEBands, 0);
    initCaps(cap, lm, c);
    final offsets = List<int>.filled(nbEBands, 0);
    var dynallocLogp = 6;
    var totalBits = totalBitsInit << 3;
    var tellF = dec.tellFrac();
    for (var i = start; i < end; i++) {
      final width = (c * (celtEBands[i + 1] - celtEBands[i])) << lm;
      final quanta = math.min(width << 3, math.max(6 << 3, width));
      var loopLogp = dynallocLogp;
      var boost = 0;
      while (tellF + (loopLogp << 3) < totalBits && boost < cap[i]) {
        final flag = dec.bitLogp(loopLogp);
        tellF = dec.tellFrac();
        if (flag == 0) break;
        boost += quanta;
        totalBits -= quanta;
        loopLogp = 1;
      }
      offsets[i] = boost;
      if (boost > 0) dynallocLogp = math.max(2, dynallocLogp - 1);
    }
    final allocTrim = tellF + (6 << 3) <= totalBits ? dec.icdf(trimIcdf, 7) : 5;
    var bits = ((len * 8) << 3) - dec.tellFrac() - 1;
    final antiCollapseRsv = isTransient && lm >= 2 && bits >= ((lm + 2) << 3) ? (1 << 3) : 0;
    bits -= antiCollapseRsv;
    final pulses = List<int>.filled(nbEBands, 0);
    final fineQuant = List<int>.filled(nbEBands, 0);
    final finePriority = List<int>.filled(nbEBands, 0);
    final alloc = computeAllocation(start, end, offsets, cap, allocTrim, bits, pulses, fineQuant, finePriority, c, lm, dec);
    unquantFineEnergy(start, end, _oldBandE, fineQuant, dec, c);
    for (var i = 0; i < cc; i++) {
      _mem[i].setRange(0, _decodeBuffer - n + _overlap, _mem[i], n);
    }
    final x = Float64List(c * n);
    final collapse = List<int>.filled(c * nbEBands, 0);
    final bd = BandDecoder(dec, start, end, lm, spread, c == 1, _rng);
    bd.decode(x, c, collapse, pulses, isTransient, alloc.dualStereo, alloc.intensity, tfRes, len * (8 << 3) - antiCollapseRsv, alloc.balance, alloc.codedBands);
    var antiCollapseOn = false;
    if (antiCollapseRsv > 0) antiCollapseOn = dec.bits(1) == 1;
    unquantEnergyFinalise(start, end, _oldBandE, fineQuant, finePriority, len * 8 - dec.tell(), dec, c);
    if (antiCollapseOn) antiCollapse(x, collapse, lm, c, n, start, end, _oldBandE, _oldLogE, _oldLogE2, pulses, bd.seed);
    if (silence) _oldBandE.fillRange(0, c * nbEBands, -28);
    _synthesis(x, effEnd, c, cc, isTransient, lm, silence);
    for (var ch = 0; ch < cc; ch++) {
      _period = math.max(_period, _minPeriod);
      _periodOld = math.max(_periodOld, _minPeriod);
      final buf = _mem[ch];
      final o = _decodeBuffer - n;
      _comb(buf, o, _periodOld, _period, _shortMdct, _gainOld, _gain, _tapsetOld, _tapset);
      if (lm != 0) _comb(buf, o + _shortMdct, _period, postPitch, n - _shortMdct, _gain, postGain, _tapset, postTapset);
    }
    _periodOld = _period;
    _gainOld = _gain;
    _tapsetOld = _tapset;
    _period = postPitch;
    _gain = postGain;
    _tapset = postTapset;
    if (lm != 0) {
      _periodOld = _period;
      _gainOld = _gain;
      _tapsetOld = _tapset;
    }
    if (c == 1) _oldBandE.setRange(nbEBands, 2 * nbEBands, _oldBandE);
    if (!isTransient) {
      _oldLogE2.setRange(0, 2 * nbEBands, _oldLogE);
      _oldLogE.setRange(0, 2 * nbEBands, _oldBandE);
    } else {
      for (var i = 0; i < 2 * nbEBands; i++) {
        _oldLogE[i] = math.min(_oldLogE[i], _oldBandE[i]);
      }
    }
    for (var ch = 0; ch < 2; ch++) {
      for (var i = 0; i < start; i++) {
        _oldBandE[ch * nbEBands + i] = 0;
        _oldLogE[ch * nbEBands + i] = _oldLogE2[ch * nbEBands + i] = -28;
      }
      for (var i = end; i < nbEBands; i++) {
        _oldBandE[ch * nbEBands + i] = 0;
        _oldLogE[ch * nbEBands + i] = _oldLogE2[ch * nbEBands + i] = -28;
      }
    }
    _rng = dec.rng;
    // de-emphasis
    const coef = 0.8500061035;
    for (var ch = 0; ch < cc; ch++) {
      var mem = _preemph[ch];
      final src = _mem[ch];
      final o = _decodeBuffer - n;
      final y = out[ch];
      for (var j = 0; j < n; j++) {
        final tmp = src[o + j] + mem;
        mem = coef * tmp;
        y[j] = tmp * (1 / 32768);
      }
      _preemph[ch] = mem;
    }
    return out;
  }

  void _tfDecode(int start, int end, bool isTransient, List<int> tfRes, int lm, RangeDecoder dec) {
    var budget = dec.storage * 8;
    var tell = dec.tell();
    var logp = isTransient ? 2 : 4;
    final tr = isTransient ? 1 : 0;
    final selectRsv = lm > 0 && tell + logp + 1 <= budget ? 1 : 0;
    budget -= selectRsv;
    var changed = 0, curr = 0;
    for (var i = start; i < end; i++) {
      if (tell + logp <= budget) {
        curr ^= dec.bitLogp(logp);
        tell = dec.tell();
        changed |= curr;
      }
      tfRes[i] = curr;
      logp = isTransient ? 4 : 5;
    }
    var select = 0;
    if (selectRsv == 1 && tfSelectTable[lm][4 * tr + 0 + changed] != tfSelectTable[lm][4 * tr + 2 + changed]) {
      select = dec.bitLogp(1);
    }
    for (var i = start; i < end; i++) {
      tfRes[i] = tfSelectTable[lm][4 * tr + 2 * select + tfRes[i]];
    }
  }

  void _synthesis(Float64List x, int effEnd, int c, int cc, bool isTransient, int lm, bool silence) {
    final m = 1 << lm;
    final n = _shortMdct << lm;
    final int b, nb, shift;
    if (isTransient) {
      b = m;
      nb = _shortMdct;
      shift = 3;
    } else {
      b = 1;
      nb = _shortMdct << lm;
      shift = 3 - lm;
    }
    final freq = Float64List(n);
    final o = _decodeBuffer - n;
    void imdct(Float64List f, int ch) {
      for (var bi = 0; bi < b; bi++) {
        _mdct.backward(f, bi, _mem[ch], o + nb * bi, celtWindow, _overlap, shift, b);
      }
    }

    if (cc == 2 && c == 1) {
      denormaliseBands(x, 0, freq, _oldBandE, 0, start, effEnd, m, silence);
      imdct(freq, 0);
      imdct(freq, 1);
    } else if (cc == 1 && c == 2) {
      final f2 = Float64List(n);
      denormaliseBands(x, 0, freq, _oldBandE, 0, start, effEnd, m, silence);
      denormaliseBands(x, n, f2, _oldBandE, nbEBands, start, effEnd, m, silence);
      for (var i = 0; i < n; i++) {
        freq[i] = .5 * freq[i] + .5 * f2[i];
      }
      imdct(freq, 0);
    } else {
      for (var ch = 0; ch < cc; ch++) {
        denormaliseBands(x, ch * n, freq, _oldBandE, ch * nbEBands, start, effEnd, m, silence);
        imdct(freq, ch);
      }
    }
  }

  void _comb(Float64List x, int xo, int t0, int t1, int n, double g0, double g1, int tapset0, int tapset1) {
    if (g0 == 0 && g1 == 0) return;
    t0 = math.max(t0, _minPeriod);
    t1 = math.max(t1, _minPeriod);
    final g00 = g0 * _combGains[tapset0][0], g01 = g0 * _combGains[tapset0][1], g02 = g0 * _combGains[tapset0][2];
    final g10 = g1 * _combGains[tapset1][0], g11 = g1 * _combGains[tapset1][1], g12 = g1 * _combGains[tapset1][2];
    var x1 = x[xo - t1 + 1], x2 = x[xo - t1], x3 = x[xo - t1 - 1], x4 = x[xo - t1 - 2];
    var overlap = _overlap;
    if (g0 == g1 && t0 == t1 && tapset0 == tapset1) overlap = 0;
    if (overlap > n) overlap = n;
    var i = 0;
    for (; i < overlap; i++) {
      final x0 = x[xo + i - t1 + 2];
      final f = celtWindow[i] * celtWindow[i];
      x[xo + i] = x[xo + i] +
          (1 - f) * g00 * x[xo + i - t0] +
          (1 - f) * g01 * (x[xo + i - t0 + 1] + x[xo + i - t0 - 1]) +
          (1 - f) * g02 * (x[xo + i - t0 + 2] + x[xo + i - t0 - 2]) +
          f * g10 * x2 +
          f * g11 * (x1 + x3) +
          f * g12 * (x0 + x4);
      x4 = x3;
      x3 = x2;
      x2 = x1;
      x1 = x0;
    }
    if (g1 == 0) return;
    x4 = x[xo + i - t1 - 2];
    x3 = x[xo + i - t1 - 1];
    x2 = x[xo + i - t1];
    x1 = x[xo + i - t1 + 1];
    for (; i < n; i++) {
      final x0 = x[xo + i - t1 + 2];
      x[xo + i] = x[xo + i] + g10 * x2 + g11 * (x1 + x3) + g12 * (x0 + x4);
      x4 = x3;
      x3 = x2;
      x2 = x1;
      x1 = x0;
    }
  }
}
