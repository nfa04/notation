import 'dart:math' as math;
import 'dart:typed_data';

import 'celt_math.dart';
import 'celt_tables.dart';
import 'range_decoder.dart';

const nbEBands = 21;
const _bitres = 3;
const _maxFineBits = 8;
const _fineOffset = 21;
const _qthetaOffset = 4, _qthetaOffsetTwophase = 16;
const _logMaxPseudo = 6;
const spreadNone = 0, spreadLight = 1, spreadNormal = 2, spreadAggressive = 3;

const trimIcdf = [126, 124, 119, 109, 87, 41, 19, 9, 4, 2, 0];
const spreadIcdf = [25, 23, 2, 0];
const tapsetIcdf = [2, 1, 0];
const tfSelectTable = [
  [0, -1, 0, -1, 0, -1, 0, -1],
  [0, -1, 0, -2, 1, 0, 1, -1],
  [0, -2, 0, -3, 2, 0, 1, -1],
  [0, -2, 0, -3, 3, 0, 1, -1],
];

const _log2FracTable = [0, 8, 13, 16, 19, 21, 23, 24, 26, 27, 28, 29, 30, 31, 32, 32, 33, 34, 34, 35, 36, 36, 37, 37];

int _ilog(int v) => ilog(v);

int getPulses(int i) => i < 8 ? i : (8 + (i & 7)) << ((i >> 3) - 1);

int _bits2pulses(int band, int lm, int bits) {
  lm++;
  final base = celtCacheIndex[lm * nbEBands + band];
  var lo = 0, hi = celtCacheBits[base];
  bits--;
  for (var i = 0; i < _logMaxPseudo; i++) {
    final mid = (lo + hi + 1) >> 1;
    if (celtCacheBits[base + mid] >= bits) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  if (bits - (lo == 0 ? -1 : celtCacheBits[base + lo]) <= celtCacheBits[base + hi] - bits) return lo;
  return hi;
}

int _pulses2bits(int band, int lm, int pulses) {
  lm++;
  final base = celtCacheIndex[lm * nbEBands + band];
  return pulses == 0 ? 0 : celtCacheBits[base + pulses] + 1;
}

/// The caps of the bits per band (libopus `init_caps`).
void initCaps(List<int> cap, int lm, int c) {
  for (var i = 0; i < nbEBands; i++) {
    final n = (celtEBands[i + 1] - celtEBands[i]) << lm;
    cap[i] = ((celtCacheCaps[nbEBands * (2 * lm + c - 1) + i] + 64) * c * n) >> 2;
  }
}

/// The result of the bit allocation.
class Allocation {
  int codedBands = 0, intensity = 0, balance = 0;
  bool dualStereo = false;
}

Allocation computeAllocation(int start, int end, List<int> offsets, List<int> cap, int allocTrim, int total, List<int> pulses, List<int> ebits, List<int> finePriority, int c, int lm, RangeDecoder ec) {
  final res = Allocation();
  total = math.max(total, 0);
  const len = nbEBands;
  var skipStart = start;
  final skipRsv = total >= 1 << _bitres ? 1 << _bitres : 0;
  total -= skipRsv;
  var intensityRsv = 0, dualStereoRsv = 0;
  if (c == 2) {
    intensityRsv = _log2FracTable[end - start];
    if (intensityRsv > total) {
      intensityRsv = 0;
    } else {
      total -= intensityRsv;
      dualStereoRsv = total >= 1 << _bitres ? 1 << _bitres : 0;
      total -= dualStereoRsv;
    }
  }
  final bits1 = List<int>.filled(len, 0), bits2 = List<int>.filled(len, 0), thresh = List<int>.filled(len, 0), trimOffset = List<int>.filled(len, 0);
  for (var j = start; j < end; j++) {
    final w = celtEBands[j + 1] - celtEBands[j];
    thresh[j] = math.max(c << _bitres, (3 * w << lm << _bitres) >> 4);
    trimOffset[j] = (c * w * (allocTrim - 5 - lm) * (end - j - 1) * (1 << (lm + _bitres))) >> 6;
    if (w << lm == 1) trimOffset[j] -= c << _bitres;
  }
  const nbAllocVectors = 11;
  var lo = 1, hi = nbAllocVectors - 1;
  do {
    var done = false, psum = 0;
    final mid = (lo + hi) >> 1;
    for (var j = end; j-- > start;) {
      final n = celtEBands[j + 1] - celtEBands[j];
      var bitsj = (c * n * celtAllocVectors[mid * len + j] << lm) >> 2;
      if (bitsj > 0) bitsj = math.max(0, bitsj + trimOffset[j]);
      bitsj += offsets[j];
      if (bitsj >= thresh[j] || done) {
        done = true;
        psum += math.min(bitsj, cap[j]);
      } else if (bitsj >= c << _bitres) {
        psum += c << _bitres;
      }
    }
    if (psum > total) {
      hi = mid - 1;
    } else {
      lo = mid + 1;
    }
  } while (lo <= hi);
  hi = lo--;
  for (var j = start; j < end; j++) {
    final n = celtEBands[j + 1] - celtEBands[j];
    var bits1j = (c * n * celtAllocVectors[lo * len + j] << lm) >> 2;
    var bits2j = hi >= nbAllocVectors ? cap[j] : (c * n * celtAllocVectors[hi * len + j] << lm) >> 2;
    if (bits1j > 0) bits1j = math.max(0, bits1j + trimOffset[j]);
    if (bits2j > 0) bits2j = math.max(0, bits2j + trimOffset[j]);
    if (lo > 0) bits1j += offsets[j];
    bits2j += offsets[j];
    if (offsets[j] > 0) skipStart = j;
    bits2j = math.max(0, bits2j - bits1j);
    bits1[j] = bits1j;
    bits2[j] = bits2j;
  }
  _interp(res, start, end, skipStart, bits1, bits2, thresh, cap, total, skipRsv, intensityRsv, dualStereoRsv, pulses, ebits, finePriority, c, lm, ec);
  return res;
}

void _interp(Allocation res, int start, int end, int skipStart, List<int> bits1, List<int> bits2, List<int> thresh, List<int> cap, int total, int skipRsv, int intensityRsv, int dualStereoRsv,
    List<int> bits, List<int> ebits, List<int> finePriority, int c, int lm, RangeDecoder ec) {
  const allocSteps = 6;
  final allocFloor = c << _bitres;
  final stereo = c > 1 ? 1 : 0;
  final logM = lm << _bitres;
  var lo = 0, hi = 1 << allocSteps;
  for (var i = 0; i < allocSteps; i++) {
    final mid = (lo + hi) >> 1;
    var psum = 0, done = false;
    for (var j = end; j-- > start;) {
      final tmp = bits1[j] + ((mid * bits2[j]) >> allocSteps);
      if (tmp >= thresh[j] || done) {
        done = true;
        psum += math.min(tmp, cap[j]);
      } else if (tmp >= allocFloor) {
        psum += allocFloor;
      }
    }
    if (psum > total) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  var psum = 0, done = false;
  for (var j = end; j-- > start;) {
    var tmp = bits1[j] + ((lo * bits2[j]) >> allocSteps);
    if (tmp < thresh[j] && !done) {
      tmp = tmp >= allocFloor ? allocFloor : 0;
    } else {
      done = true;
    }
    tmp = math.min(tmp, cap[j]);
    bits[j] = tmp;
    psum += tmp;
  }
  var codedBands = end;
  for (;; codedBands--) {
    final j = codedBands - 1;
    if (j <= skipStart) {
      total += skipRsv;
      break;
    }
    var left = total - psum;
    final percoeff = left ~/ (celtEBands[codedBands] - celtEBands[start]);
    left -= (celtEBands[codedBands] - celtEBands[start]) * percoeff;
    final rem = math.max(left - (celtEBands[j] - celtEBands[start]), 0);
    final bandWidth = celtEBands[codedBands] - celtEBands[j];
    var bandBits = bits[j] + percoeff * bandWidth + rem;
    if (bandBits >= math.max(thresh[j], allocFloor + (1 << _bitres))) {
      if (ec.bitLogp(1) == 1) break;
      psum += 1 << _bitres;
      bandBits -= 1 << _bitres;
    }
    psum -= bits[j] + intensityRsv;
    if (intensityRsv > 0) intensityRsv = _log2FracTable[j - start];
    psum += intensityRsv;
    if (bandBits >= allocFloor) {
      psum += allocFloor;
      bits[j] = allocFloor;
    } else {
      bits[j] = 0;
    }
  }
  if (intensityRsv > 0) {
    res.intensity = start + ec.uint(codedBands + 1 - start);
  } else {
    res.intensity = 0;
  }
  if (res.intensity <= start) {
    total += dualStereoRsv;
    dualStereoRsv = 0;
  }
  if (dualStereoRsv > 0) {
    res.dualStereo = ec.bitLogp(1) == 1;
  } else {
    res.dualStereo = false;
  }
  var left = total - psum;
  var percoeff = left ~/ (celtEBands[codedBands] - celtEBands[start]);
  left -= (celtEBands[codedBands] - celtEBands[start]) * percoeff;
  for (var j = start; j < codedBands; j++) {
    bits[j] += percoeff * (celtEBands[j + 1] - celtEBands[j]);
  }
  for (var j = start; j < codedBands; j++) {
    final tmp = math.min(left, celtEBands[j + 1] - celtEBands[j]);
    bits[j] += tmp;
    left -= tmp;
  }
  var balance = 0;
  var j = start;
  for (; j < codedBands; j++) {
    final n0 = celtEBands[j + 1] - celtEBands[j];
    final n = n0 << lm;
    final bit = bits[j] + balance;
    int excess;
    if (n > 1) {
      excess = math.max(bit - cap[j], 0);
      bits[j] = bit - excess;
      final den = c * n + ((c == 2 && n > 2 && !res.dualStereo && j < res.intensity) ? 1 : 0);
      final nClogN = den * (celtLogN[j] + logM);
      var offset = (nClogN >> 1) - den * _fineOffset;
      if (n == 2) offset += (den << _bitres) >> 2;
      if (bits[j] + offset < (den * 2) << _bitres) {
        offset += nClogN >> 2;
      } else if (bits[j] + offset < (den * 3) << _bitres) {
        offset += nClogN >> 3;
      }
      ebits[j] = math.max(0, bits[j] + offset + (den << (_bitres - 1)));
      ebits[j] = (ebits[j] ~/ den) >> _bitres;
      if (c * ebits[j] > (bits[j] >> _bitres)) ebits[j] = (bits[j] >> stereo) >> _bitres;
      ebits[j] = math.min(ebits[j], _maxFineBits);
      finePriority[j] = ebits[j] * (den << _bitres) >= bits[j] + offset ? 1 : 0;
      bits[j] -= (c * ebits[j]) << _bitres;
    } else {
      excess = math.max(0, bit - (c << _bitres));
      bits[j] = bit - excess;
      ebits[j] = 0;
      finePriority[j] = 1;
    }
    if (excess > 0) {
      final extraFine = math.min(excess >> (stereo + _bitres), _maxFineBits - ebits[j]);
      ebits[j] += extraFine;
      final extraBits = (extraFine * c) << _bitres;
      finePriority[j] = extraBits >= excess - balance ? 1 : 0;
      excess -= extraBits;
    }
    balance = excess;
  }
  res.balance = balance;
  for (; j < end; j++) {
    ebits[j] = (bits[j] >> stereo) >> _bitres;
    bits[j] = 0;
    finePriority[j] = ebits[j] < 1 ? 1 : 0;
  }
  res.codedBands = codedBands;
}

// ---- energy ----

const _predCoef = [29440 / 32768, 26112 / 32768, 21248 / 32768, 16384 / 32768];
const _betaCoef = [30147 / 32768, 22282 / 32768, 12124 / 32768, 6554 / 32768];
const _betaIntra = 4915 / 32768;
const _smallEnergyIcdf = [2, 1, 0];

int _laplaceFreq1(int fs0, int decay) {
  final ft = 32768 - 2 * 16 - fs0;
  return (ft * (16384 - decay)) >> 15;
}

int _laplaceDecode(RangeDecoder dec, int fs, int decay) {
  var val = 0;
  final fm = dec.decodeBin(15);
  var fl = 0;
  if (fm >= fs) {
    val++;
    fl = fs;
    fs = _laplaceFreq1(fs, decay) + 1;
    while (fs > 1 && fm >= fl + 2 * fs) {
      fs *= 2;
      fl += fs;
      fs = ((fs - 2) * decay) >> 15;
      fs += 1;
      val++;
    }
    if (fs <= 1) {
      final di = (fm - fl) >> 1;
      val += di;
      fl += 2 * di;
    }
    if (fm < fl + fs) {
      val = -val;
    } else {
      fl += fs;
    }
  }
  dec.update(fl, math.min(fl + fs, 32768), 32768);
  return val;
}

void unquantCoarseEnergy(int start, int end, Float64List oldEBands, bool intra, RangeDecoder dec, int c, int lm) {
  final model = (lm * 2 + (intra ? 1 : 0)) * 42;
  final prev = [0.0, 0.0];
  double coef, beta;
  if (intra) {
    coef = 0;
    beta = _betaIntra;
  } else {
    beta = _betaCoef[lm];
    coef = _predCoef[lm];
  }
  final budget = dec.storage * 8;
  for (var i = start; i < end; i++) {
    for (var ch = 0; ch < c; ch++) {
      int qi;
      final tell = dec.tell();
      if (budget - tell >= 15) {
        final int pi = 2 * (i < 20 ? i : 20);
        qi = _laplaceDecode(dec, celtProbModel[model + pi] << 7, celtProbModel[model + pi + 1] << 6);
      } else if (budget - tell >= 2) {
        qi = dec.icdf(_smallEnergyIcdf, 2);
        qi = (qi >> 1) ^ -(qi & 1);
      } else if (budget - tell >= 1) {
        qi = -dec.bitLogp(1);
      } else {
        qi = -1;
      }
      final q = qi.toDouble();
      final k = i + ch * nbEBands;
      oldEBands[k] = math.max(-9.0, oldEBands[k]);
      oldEBands[k] = coef * oldEBands[k] + prev[ch] + q;
      prev[ch] = prev[ch] + q - beta * q;
    }
  }
}

void unquantFineEnergy(int start, int end, Float64List oldEBands, List<int> fineQuant, RangeDecoder dec, int c) {
  for (var i = start; i < end; i++) {
    if (fineQuant[i] <= 0) continue;
    for (var ch = 0; ch < c; ch++) {
      final q2 = dec.bits(fineQuant[i]);
      final offset = (q2 + .5) * (1 << (14 - fineQuant[i])) * (1.0 / 16384) - .5;
      oldEBands[i + ch * nbEBands] += offset;
    }
  }
}

void unquantEnergyFinalise(int start, int end, Float64List oldEBands, List<int> fineQuant, List<int> finePriority, int bitsLeft, RangeDecoder dec, int c) {
  for (var prio = 0; prio < 2; prio++) {
    for (var i = start; i < end && bitsLeft >= c; i++) {
      if (fineQuant[i] >= _maxFineBits || finePriority[i] != prio) continue;
      for (var ch = 0; ch < c; ch++) {
        final q2 = dec.bits(1);
        final offset = (q2 - .5) * (1 << (14 - fineQuant[i] - 1)) * (1.0 / 16384);
        oldEBands[i + ch * nbEBands] += offset;
        bitsLeft--;
      }
    }
  }
}

// ---- pulse vectors ----

int _u32(int v) => v & 0xFFFFFFFF;

void _unext(List<int> u, int off, int len, int ui0) {
  var j = 1;
  do {
    final ui1 = _u32(u[off + j] + u[off + j - 1] + ui0);
    u[off + j - 1] = ui0;
    ui0 = ui1;
  } while (++j < len);
  u[off + j - 1] = ui0;
}

void _uprev(List<int> u, int n, int ui0) {
  var j = 1;
  do {
    final ui1 = _u32(u[j] - u[j - 1] - ui0);
    u[j - 1] = ui0;
    ui0 = ui1;
  } while (++j < n);
  u[j - 1] = ui0;
}

int _ncwrsUrow(int n, int k, List<int> u) {
  final len = k + 2;
  u[0] = 0;
  u[1] = 1;
  for (var i = 2; i < len; i++) {
    u[i] = (i << 1) - 1;
  }
  for (var i = 2; i < n; i++) {
    _unext(u, 1, k + 1, 1);
  }
  return _u32(u[k] + u[k + 1]);
}

/// Reads the pulse vector of a band into [y]; returns the sum of the squares.
double _decodePulses(List<int> y, int n, int k, RangeDecoder dec) {
  final u = List<int>.filled(k + 2, 0);
  var i = dec.uint(_ncwrsUrow(n, k, u));
  var yy = 0.0;
  for (var j = 0; j < n; j++) {
    var p = u[k + 1];
    final s = i >= p ? -1 : 0;
    i -= p & s;
    final yj = k;
    p = u[k];
    while (p > i) {
      p = u[--k];
    }
    i -= p;
    final val = ((yj - k) + s) ^ s;
    y[j] = val;
    yy += val * val;
    _uprev(u, k + 2, 0);
  }
  return yy;
}

// ---- vector quantisation ----

void _expRotation1(Float64List x, int xo, int len, int stride, double c, double s) {
  final ms = -s;
  var p = xo;
  for (var i = 0; i < len - stride; i++) {
    final x1 = x[p], x2 = x[p + stride];
    x[p + stride] = c * x2 + s * x1;
    x[p++] = c * x1 + ms * x2;
  }
  p = xo + len - 2 * stride - 1;
  for (var i = len - 2 * stride - 1; i >= 0; i--) {
    final x1 = x[p], x2 = x[p + stride];
    x[p + stride] = c * x2 + s * x1;
    x[p--] = c * x1 + ms * x2;
  }
}

void _expRotation(Float64List x, int xo, int len, int dir, int stride, int k, int spread) {
  const spreadFactor = [15, 10, 5];
  if (2 * k >= len || spread == spreadNone) return;
  final factor = spreadFactor[spread - 1];
  final gain = len / (len + factor * k);
  final theta = .5 * (gain * gain);
  final c = math.cos(.5 * math.pi * theta);
  final s = math.cos(.5 * math.pi * (1 - theta));
  var stride2 = 0;
  if (len >= 8 * stride) {
    stride2 = 1;
    while ((stride2 * stride2 + stride2) * stride + (stride >> 2) < len) {
      stride2++;
    }
  }
  len = len ~/ stride;
  for (var i = 0; i < stride; i++) {
    if (dir < 0) {
      if (stride2 != 0) _expRotation1(x, xo + i * len, len, stride2, s, c);
      _expRotation1(x, xo + i * len, len, 1, c, s);
    } else {
      _expRotation1(x, xo + i * len, len, 1, c, -s);
      if (stride2 != 0) _expRotation1(x, xo + i * len, len, stride2, s, -c);
    }
  }
}

int _algUnquant(Float64List x, int xo, int n, int k, int spread, int b, RangeDecoder dec, double gain) {
  final iy = List<int>.filled(n, 0);
  final ryy = _decodePulses(iy, n, k, dec);
  final g = (1 / math.sqrt(ryy)) * gain;
  for (var i = 0; i < n; i++) {
    x[xo + i] = g * iy[i];
  }
  _expRotation(x, xo, n, -1, b, k, spread);
  if (b <= 1) return 1;
  final n0 = n ~/ b;
  var mask = 0;
  for (var i = 0; i < b; i++) {
    var tmp = 0;
    for (var j = 0; j < n0; j++) {
      tmp |= iy[i * n0 + j];
    }
    if (tmp != 0) mask |= 1 << i;
  }
  return mask;
}

void renormaliseVector(Float64List x, int xo, int n, double gain) {
  var e = 1e-15;
  for (var i = 0; i < n; i++) {
    e += x[xo + i] * x[xo + i];
  }
  final g = (1 / math.sqrt(e)) * gain;
  for (var i = 0; i < n; i++) {
    x[xo + i] *= g;
  }
}

// ---- band shapes ----

int _bitexactCos(int x) {
  final tmp = (4096 + x * x) >> 13;
  var x2 = tmp;
  int fracMul16(int a, int b) => (16384 + a * b) >> 15;
  x2 = (32767 - x2) + fracMul16(x2, (-7651 + fracMul16(x2, (8277 + fracMul16(-626, x2)))));
  return 1 + x2;
}

int _bitexactLog2tan(int isin, int icos) {
  int fracMul16(int a, int b) => (16384 + a * b) >> 15;
  final lc = _ilog(icos), ls = _ilog(isin);
  icos <<= 15 - lc;
  isin <<= 15 - ls;
  return (ls - lc) * (1 << 11) + fracMul16(isin, fracMul16(isin, -2597) + 7932) - fracMul16(icos, fracMul16(icos, -2597) + 7932);
}

int celtLcgRand(int seed) => (1664525 * seed + 1013904223) & 0xFFFFFFFF;

void _haar1(Float64List x, int xo, int n0, int stride) {
  n0 >>= 1;
  const h = 0.70710678;
  for (var i = 0; i < stride; i++) {
    for (var j = 0; j < n0; j++) {
      final tmp1 = h * x[xo + stride * 2 * j + i];
      final tmp2 = h * x[xo + stride * (2 * j + 1) + i];
      x[xo + stride * 2 * j + i] = tmp1 + tmp2;
      x[xo + stride * (2 * j + 1) + i] = tmp1 - tmp2;
    }
  }
}

const _orderyTable = [1, 0, 3, 0, 2, 1, 7, 0, 4, 3, 6, 1, 5, 2, 15, 0, 8, 7, 12, 3, 11, 4, 14, 1, 9, 6, 13, 2, 10, 5];

void _deinterleaveHadamard(Float64List x, int xo, int n0, int stride, bool hadamard) {
  final n = n0 * stride;
  final tmp = Float64List(n);
  if (hadamard) {
    final o = stride - 2;
    for (var i = 0; i < stride; i++) {
      for (var j = 0; j < n0; j++) {
        tmp[_orderyTable[o + i] * n0 + j] = x[xo + j * stride + i];
      }
    }
  } else {
    for (var i = 0; i < stride; i++) {
      for (var j = 0; j < n0; j++) {
        tmp[i * n0 + j] = x[xo + j * stride + i];
      }
    }
  }
  x.setRange(xo, xo + n, tmp);
}

void _interleaveHadamard(Float64List x, int xo, int n0, int stride, bool hadamard) {
  final n = n0 * stride;
  final tmp = Float64List(n);
  if (hadamard) {
    final o = stride - 2;
    for (var i = 0; i < stride; i++) {
      for (var j = 0; j < n0; j++) {
        tmp[j * stride + i] = x[xo + _orderyTable[o + i] * n0 + j];
      }
    }
  } else {
    for (var i = 0; i < stride; i++) {
      for (var j = 0; j < n0; j++) {
        tmp[j * stride + i] = x[xo + i * n0 + j];
      }
    }
  }
  x.setRange(xo, xo + n, tmp);
}

int _computeQn(int n, int b, int offset, int pulseCap, bool stereo) {
  const exp2Table8 = [16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048];
  var n2 = 2 * n - 1;
  if (stereo && n == 2) n2--;
  var qb = (b + n2 * offset) ~/ n2;
  qb = math.min(b - pulseCap - (4 << _bitres), qb);
  qb = math.min(8 << _bitres, qb);
  if (qb < (1 << _bitres >> 1)) return 1;
  var qn = exp2Table8[qb & 7] >> (14 - (qb >> _bitres));
  return (qn + 1) >> 1 << 1;
}

class _Split {
  bool inv = false;
  int imid = 0, iside = 0, delta = 0, itheta = 0, qalloc = 0;
}

/// A view of a part of a list (a band's shape or the folding buffer).
class _Ref {
  final Float64List list;
  final int off;
  const _Ref(this.list, this.off);
}

/// Reads all the band shapes of a frame (libopus `quant_all_bands`, decoding only).
class BandDecoder {
  final RangeDecoder ec;
  final int start, end, lm;
  final int spread;
  final bool disableInv;
  int seed;
  int remainingBits = 0;
  int _i = 0, _intensity = 0, _tfChange = 0;
  final _split = _Split();

  BandDecoder(this.ec, this.start, this.end, this.lm, this.spread, this.disableInv, this.seed);

  /// [x] holds C*N values (the second channel from N on); [collapseMasks] has C*21 entries.
  void decode(Float64List x, int c, List<int> collapseMasks, List<int> pulses, bool shortBlocks, bool dualStereo, int intensity, List<int> tfRes, int totalBits, int balance, int codedBands) {
    final m = 1 << lm;
    final b0 = shortBlocks ? m : 1;
    final n = m * 96; // shortMdctSize 120 -> N = M*120
    final nn = m * 120;
    assert(n > 0);
    final normOffset = m * celtEBands[start];
    final normLen = m * celtEBands[nbEBands - 1] - normOffset;
    final norm = Float64List(c * normLen + 16);
    final norm2Off = normLen;
    var lowbandOffset = 0;
    var updateLowband = true;
    _intensity = intensity;
    var lowbandScratch = m * celtEBands[nbEBands - 1 - 0]; // effEBands - 1 == 20
    for (var i = start; i < end; i++) {
      _i = i;
      final last = i == end - 1;
      var xo = m * celtEBands[i];
      var xl = x;
      var yl = c == 2 ? x : null;
      var yo = c == 2 ? nn + m * celtEBands[i] : 0;
      final bn = m * celtEBands[i + 1] - m * celtEBands[i];
      final tell = ec.tellFrac();
      if (i != start) balance -= tell;
      remainingBits = totalBits - tell - 1;
      int b;
      if (i <= codedBands - 1) {
        final currBalance = _sdiv(balance, math.min(3, codedBands - i));
        b = math.max(0, math.min(16383, math.min(remainingBits + 1, pulses[i] + currBalance)));
      } else {
        b = 0;
      }
      if ((m * celtEBands[i] - bn >= m * celtEBands[start] || i == start + 1) && (updateLowband || lowbandOffset == 0)) lowbandOffset = i;
      if (i == start + 1) _specialHybridFolding(norm, norm2Off, start, m, dualStereo);
      _tfChange = tfRes[i];
      int? scratch = lowbandScratch;
      if (i >= nbEBands) {
        xl = norm;
        xo = 0;
        if (c == 2) {
          yl = norm;
          yo = 0;
        }
        scratch = null;
      }
      if (last) scratch = null;
      var effectiveLowband = -1;
      int xCm, yCm;
      if (lowbandOffset != 0 && (spread != spreadAggressive || b0 > 1 || _tfChange < 0)) {
        effectiveLowband = math.max(0, m * celtEBands[lowbandOffset] - normOffset - bn);
        var foldStart = lowbandOffset;
        while (m * celtEBands[--foldStart] > effectiveLowband + normOffset) {}
        var foldEnd = lowbandOffset - 1;
        while (++foldEnd < i && m * celtEBands[foldEnd] < effectiveLowband + normOffset + bn) {}
        xCm = yCm = 0;
        var foldI = foldStart;
        do {
          xCm |= collapseMasks[foldI * c + 0];
          yCm |= collapseMasks[foldI * c + c - 1];
        } while (++foldI < foldEnd);
      } else {
        xCm = yCm = (1 << b0) - 1;
      }
      if (dualStereo && i == _intensity) {
        dualStereo = false;
        for (var j = 0; j < m * celtEBands[i] - normOffset; j++) {
          norm[j] = .5 * (norm[j] + norm[norm2Off + j]);
        }
      }
      final lowOutOff = last ? -1 : m * celtEBands[i] - normOffset;
      if (dualStereo) {
        xCm = _quantBand(xl, xo, bn, b ~/ 2, b0, effectiveLowband != -1 ? _Ref(norm, effectiveLowband) : null, lm, last ? null : _Ref(norm, lowOutOff), 1.0, scratch == null ? null : _Ref(x, scratch), xCm);
        yCm = _quantBand(yl!, yo, bn, b ~/ 2, b0, effectiveLowband != -1 ? _Ref(norm, norm2Off + effectiveLowband) : null, lm, last ? null : _Ref(norm, norm2Off + lowOutOff), 1.0, scratch == null ? null : _Ref(x, scratch), yCm);
      } else {
        if (yl != null) {
          xCm = _quantBandStereo(xl, xo, yl, yo, bn, b, b0, effectiveLowband != -1 ? _Ref(norm, effectiveLowband) : null, lm, last ? null : _Ref(norm, lowOutOff), scratch == null ? null : _Ref(x, scratch), xCm | yCm);
        } else {
          xCm = _quantBand(xl, xo, bn, b, b0, effectiveLowband != -1 ? _Ref(norm, effectiveLowband) : null, lm, last ? null : _Ref(norm, lowOutOff), 1.0, scratch == null ? null : _Ref(x, scratch), xCm | yCm);
        }
        yCm = xCm;
      }
      collapseMasks[i * c + 0] = xCm & 0xFF;
      collapseMasks[i * c + c - 1] = yCm & 0xFF;
      balance += pulses[i] + tell;
      updateLowband = b > (bn << _bitres);
    }
  }

  static int _sdiv(int a, int b) => a ~/ b;

  void _specialHybridFolding(Float64List norm, int norm2Off, int start, int m, bool dualStereo) {
    final n1 = m * (celtEBands[start + 1] - celtEBands[start]);
    final n2 = m * (celtEBands[start + 2] - celtEBands[start + 1]);
    if (n2 > n1) {
      for (var k = 0; k < n2 - n1; k++) {
        norm[n1 + k] = norm[2 * n1 - n2 + k];
      }
      if (dualStereo) {
        for (var k = 0; k < n2 - n1; k++) {
          norm[norm2Off + n1 + k] = norm[norm2Off + 2 * n1 - n2 + k];
        }
      }
    }
  }

  void _computeTheta(_Split s, int n, List<int> bRef, int bb, int b0, int lmm, bool stereo, List<int> fill) {
    var inv = false;
    final i = _i;
    final pulseCap = celtLogN[i] + lmm * (1 << _bitres);
    final offset = (pulseCap >> 1) - (stereo && n == 2 ? _qthetaOffsetTwophase : _qthetaOffset);
    var qn = _computeQn(n, bRef[0], offset, pulseCap, stereo);
    if (stereo && i >= _intensity) qn = 1;
    var itheta = 0;
    final tell = ec.tellFrac();
    if (qn != 1) {
      if (stereo && n > 2) {
        const p0 = 3;
        var x = itheta;
        final x0 = qn ~/ 2;
        final ft = p0 * (x0 + 1) + x0;
        final fs = ec.decode(ft);
        if (fs < (x0 + 1) * p0) {
          x = fs ~/ p0;
        } else {
          x = x0 + 1 + (fs - (x0 + 1) * p0);
        }
        ec.update(x <= x0 ? p0 * x : (x - 1 - x0) + (x0 + 1) * p0, x <= x0 ? p0 * (x + 1) : (x - x0) + (x0 + 1) * p0, ft);
        itheta = x;
      } else if (b0 > 1 || stereo) {
        itheta = ec.uint(qn + 1);
      } else {
        var fs = 1, fl = 0;
        final ft = ((qn >> 1) + 1) * ((qn >> 1) + 1);
        final fm = ec.decode(ft);
        if (fm < (((qn >> 1) * ((qn >> 1) + 1)) >> 1)) {
          itheta = (isqrt32(8 * fm + 1) - 1) >> 1;
          fs = itheta + 1;
          fl = (itheta * (itheta + 1)) >> 1;
        } else {
          itheta = (2 * (qn + 1) - isqrt32(8 * (ft - fm - 1) + 1)) >> 1;
          fs = qn + 1 - itheta;
          fl = ft - (((qn + 1 - itheta) * (qn + 2 - itheta)) >> 1);
        }
        ec.update(fl, fl + fs, ft);
      }
      itheta = (itheta * 16384) ~/ qn;
    } else if (stereo) {
      if (bRef[0] > 2 << _bitres && remainingBits > 2 << _bitres) {
        inv = ec.bitLogp(2) == 1;
      } else {
        inv = false;
      }
      if (disableInv) inv = false;
      itheta = 0;
    }
    final qalloc = ec.tellFrac() - tell;
    bRef[0] -= qalloc;
    int imid, iside, delta;
    if (itheta == 0) {
      imid = 32767;
      iside = 0;
      fill[0] &= (1 << bb) - 1;
      delta = -16384;
    } else if (itheta == 16384) {
      imid = 0;
      iside = 32767;
      fill[0] &= ((1 << bb) - 1) << bb;
      delta = 16384;
    } else {
      imid = _bitexactCos(itheta);
      iside = _bitexactCos(16384 - itheta);
      delta = (((n - 1) << 7) * _bitexactLog2tan(iside, imid) + 16384) >> 15;
    }
    s.inv = inv;
    s.imid = imid;
    s.iside = iside;
    s.delta = delta;
    s.itheta = itheta;
    s.qalloc = qalloc;
  }

  int _quantBandN1(Float64List x, int xo, Float64List? y, int yo, _Ref? lowbandOut) {
    var list = x, o = xo;
    for (var c = 0; c < (y != null ? 2 : 1); c++) {
      var sign = 0;
      if (remainingBits >= 1 << _bitres) {
        sign = ec.bits(1);
        remainingBits -= 1 << _bitres;
      }
      list[o] = sign != 0 ? -1.0 : 1.0;
      if (y != null) {
        list = y;
        o = yo;
      }
    }
    if (lowbandOut != null) lowbandOut.list[lowbandOut.off] = x[xo];
    return 1;
  }

  int _quantPartition(Float64List x, int xo, int n, int b, int bb, _Ref? lowband, int lmm, double gain, int fill) {
    final cacheBase = celtCacheIndex[(lmm + 1) * nbEBands + _i];
    final b0 = bb;
    var cm = 0;
    if (lmm != -1 && b > celtCacheBits[cacheBase + celtCacheBits[cacheBase]] + 12 && n > 2) {
      n >>= 1;
      final yo = xo + n;
      lmm -= 1;
      if (bb == 1) fill = (fill & 1) | (fill << 1);
      bb = (bb + 1) >> 1;
      final bRef = [b];
      final f = [fill];
      _computeTheta(_split, n, bRef, bb, b0, lmm, false, f);
      b = bRef[0];
      fill = f[0];
      final imid = _split.imid, iside = _split.iside;
      var delta = _split.delta;
      final itheta = _split.itheta, qalloc = _split.qalloc;
      final mid = (1.0 / 32768) * imid, side = (1.0 / 32768) * iside;
      if (b0 > 1 && (itheta & 0x3fff) != 0) {
        if (itheta > 8192) {
          delta -= delta >> (4 - lmm);
        } else {
          delta = math.min(0, delta + ((n << _bitres) >> (5 - lmm)));
        }
      }
      final mbits0 = math.max(0, math.min(b, (b - delta) ~/ 2));
      var mbits = mbits0, sbits = b - mbits0;
      remainingBits -= qalloc;
      final next2 = lowband == null ? null : _Ref(lowband.list, lowband.off + n);
      var rebalance = remainingBits;
      if (mbits >= sbits) {
        cm = _quantPartition(x, xo, n, mbits, bb, lowband, lmm, gain * mid, fill);
        rebalance = mbits - (rebalance - remainingBits);
        if (rebalance > 3 << _bitres && itheta != 0) sbits += rebalance - (3 << _bitres);
        cm |= _quantPartition(x, yo, n, sbits, bb, next2, lmm, gain * side, fill >> bb) << (b0 >> 1);
      } else {
        cm = _quantPartition(x, yo, n, sbits, bb, next2, lmm, gain * side, fill >> bb) << (b0 >> 1);
        rebalance = sbits - (rebalance - remainingBits);
        if (rebalance > 3 << _bitres && itheta != 16384) mbits += rebalance - (3 << _bitres);
        cm |= _quantPartition(x, xo, n, mbits, bb, lowband, lmm, gain * mid, fill);
      }
    } else {
      var q = _bits2pulses(_i, lmm, b);
      var currBits = _pulses2bits(_i, lmm, q);
      remainingBits -= currBits;
      while (remainingBits < 0 && q > 0) {
        remainingBits += currBits;
        q--;
        currBits = _pulses2bits(_i, lmm, q);
        remainingBits -= currBits;
      }
      if (q != 0) {
        final k = getPulses(q);
        cm = _algUnquant(x, xo, n, k, spread, bb, ec, gain);
      } else {
        final cmMask = (1 << bb) - 1;
        fill &= cmMask;
        if (fill == 0) {
          for (var j = 0; j < n; j++) {
            x[xo + j] = 0;
          }
        } else {
          if (lowband == null) {
            for (var j = 0; j < n; j++) {
              seed = celtLcgRand(seed);
              x[xo + j] = (((seed ^ 0x80000000) - 0x80000000) >> 20).toDouble();
            }
            cm = cmMask;
          } else {
            for (var j = 0; j < n; j++) {
              seed = celtLcgRand(seed);
              var tmp = 1.0 / 256;
              tmp = (seed & 0x8000) != 0 ? tmp : -tmp;
              x[xo + j] = lowband.list[lowband.off + j] + tmp;
            }
            cm = fill;
          }
          renormaliseVector(x, xo, n, gain);
        }
      }
    }
    return cm;
  }

  int _quantBand(Float64List x, int xo, int n, int b, int bb, _Ref? lowband, int lmm, _Ref? lowbandOut, double gain, _Ref? lowbandScratch, int fill) {
    final n0 = n;
    var nB = n;
    var b0 = bb;
    var timeDivide = 0, recombine = 0;
    final longBlocks = b0 == 1;
    final tfChange0 = _tfChange;
    var tfChange = tfChange0;
    nB = nB ~/ bb;
    if (n == 1) return _quantBandN1(x, xo, null, 0, lowbandOut);
    if (tfChange > 0) recombine = tfChange;
    if (lowbandScratch != null && lowband != null && (recombine != 0 || ((nB & 1) == 0 && tfChange < 0) || b0 > 1)) {
      for (var k = 0; k < n; k++) {
        lowbandScratch.list[lowbandScratch.off + k] = lowband.list[lowband.off + k];
      }
      lowband = lowbandScratch;
    }
    const bitInterleave = [0, 1, 1, 1, 2, 3, 3, 3, 2, 3, 3, 3, 2, 3, 3, 3];
    for (var k = 0; k < recombine; k++) {
      if (lowband != null) _haar1(lowband.list, lowband.off, n >> k, 1 << k);
      fill = bitInterleave[fill & 0xF] | bitInterleave[fill >> 4] << 2;
    }
    bb >>= recombine;
    nB <<= recombine;
    while ((nB & 1) == 0 && tfChange < 0) {
      if (lowband != null) _haar1(lowband.list, lowband.off, nB, bb);
      fill |= fill << bb;
      bb <<= 1;
      nB >>= 1;
      timeDivide++;
      tfChange++;
    }
    b0 = bb;
    final nB0 = nB;
    if (b0 > 1) {
      if (lowband != null) _deinterleaveHadamard(lowband.list, lowband.off, nB >> recombine, b0 << recombine, longBlocks);
    }
    var cm = _quantPartition(x, xo, n, b, bb, lowband, lmm, gain, fill);
    if (b0 > 1) _interleaveHadamard(x, xo, nB >> recombine, b0 << recombine, longBlocks);
    nB = nB0;
    bb = b0;
    for (var k = 0; k < timeDivide; k++) {
      bb >>= 1;
      nB <<= 1;
      cm |= cm >> bb;
      _haar1(x, xo, nB, bb);
    }
    const bitDeinterleave = [0x00, 0x03, 0x0C, 0x0F, 0x30, 0x33, 0x3C, 0x3F, 0xC0, 0xC3, 0xCC, 0xCF, 0xF0, 0xF3, 0xFC, 0xFF];
    for (var k = 0; k < recombine; k++) {
      cm = bitDeinterleave[cm];
      _haar1(x, xo, n0 >> k, 1 << k);
    }
    bb <<= recombine;
    if (lowbandOut != null) {
      final nn = math.sqrt(n0.toDouble());
      for (var j = 0; j < n0; j++) {
        lowbandOut.list[lowbandOut.off + j] = nn * x[xo + j];
      }
    }
    cm &= (1 << bb) - 1;
    return cm;
  }

  int _quantBandStereo(Float64List x, int xo, Float64List y, int yo, int n, int b, int bb, _Ref? lowband, int lmm, _Ref? lowbandOut, _Ref? lowbandScratch, int fill) {
    if (n == 1) return _quantBandN1(x, xo, y, yo, lowbandOut);
    final origFill = fill;
    final bRef = [b];
    final f = [fill];
    _computeTheta(_split, n, bRef, bb, bb, lmm, true, f);
    b = bRef[0];
    fill = f[0];
    final inv = _split.inv;
    final imid = _split.imid, iside = _split.iside, delta = _split.delta, itheta = _split.itheta, qalloc = _split.qalloc;
    final mid = (1.0 / 32768) * imid, side = (1.0 / 32768) * iside;
    var cm = 0;
    int mbits, sbits;
    if (n == 2) {
      mbits = b;
      sbits = 0;
      if (itheta != 0 && itheta != 16384) sbits = 1 << _bitres;
      mbits -= sbits;
      final c = itheta > 8192;
      remainingBits -= qalloc + sbits;
      final x2 = c ? y : x, x2o = c ? yo : xo;
      final y2 = c ? x : y, y2o = c ? xo : yo;
      var sign = 0;
      if (sbits != 0) sign = ec.bits(1);
      sign = 1 - 2 * sign;
      cm = _quantBand(x2, x2o, n, mbits, bb, lowband, lmm, lowbandOut, 1.0, lowbandScratch, origFill);
      y2[y2o] = -sign * x2[x2o + 1];
      y2[y2o + 1] = sign * x2[x2o];
      x[xo] = mid * x[xo];
      x[xo + 1] = mid * x[xo + 1];
      y[yo] = side * y[yo];
      y[yo + 1] = side * y[yo + 1];
      var tmp = x[xo];
      x[xo] = tmp - y[yo];
      y[yo] = tmp + y[yo];
      tmp = x[xo + 1];
      x[xo + 1] = tmp - y[yo + 1];
      y[yo + 1] = tmp + y[yo + 1];
    } else {
      mbits = math.max(0, math.min(b, (b - delta) ~/ 2));
      sbits = b - mbits;
      remainingBits -= qalloc;
      var rebalance = remainingBits;
      if (mbits >= sbits) {
        cm = _quantBand(x, xo, n, mbits, bb, lowband, lmm, lowbandOut, 1.0, lowbandScratch, fill);
        rebalance = mbits - (rebalance - remainingBits);
        if (rebalance > 3 << _bitres && itheta != 0) sbits += rebalance - (3 << _bitres);
        cm |= _quantBand(y, yo, n, sbits, bb, null, lmm, null, side, null, fill >> bb);
      } else {
        cm = _quantBand(y, yo, n, sbits, bb, null, lmm, null, side, null, fill >> bb);
        rebalance = sbits - (rebalance - remainingBits);
        if (rebalance > 3 << _bitres && itheta != 16384) mbits += rebalance - (3 << _bitres);
        cm |= _quantBand(x, xo, n, mbits, bb, lowband, lmm, lowbandOut, 1.0, lowbandScratch, fill);
      }
    }
    if (n != 2) _stereoMerge(x, xo, y, yo, mid, n);
    if (inv) {
      for (var j = 0; j < n; j++) {
        y[yo + j] = -y[yo + j];
      }
    }
    return cm;
  }

  void _stereoMerge(Float64List x, int xo, Float64List y, int yo, double mid, int n) {
    var xp = 0.0, side = 0.0;
    for (var j = 0; j < n; j++) {
      xp += y[yo + j] * x[xo + j];
      side += y[yo + j] * y[yo + j];
    }
    xp = mid * xp;
    final mid2 = mid;
    final el = mid2 * mid2 + side - 2 * xp;
    final er = mid2 * mid2 + side + 2 * xp;
    if (er < 6e-4 || el < 6e-4) {
      for (var j = 0; j < n; j++) {
        y[yo + j] = x[xo + j];
      }
      return;
    }
    final lgain = 1 / math.sqrt(el), rgain = 1 / math.sqrt(er);
    for (var j = 0; j < n; j++) {
      final l = mid * x[xo + j], r = y[yo + j];
      x[xo + j] = lgain * (l - r);
      y[yo + j] = rgain * (l + r);
    }
  }
}

/// Puts back the energy and the random noise of bands that got no pulses in some blocks (libopus `anti_collapse`).
void antiCollapse(Float64List x, List<int> collapseMasks, int lm, int c, int size, int start, int end, Float64List logE, Float64List prev1logE, Float64List prev2logE, List<int> pulses, int seed) {
  for (var i = start; i < end; i++) {
    final n0 = celtEBands[i + 1] - celtEBands[i];
    final depth = ((1 + pulses[i]) ~/ n0) >> lm;
    final thresh = .5 * math.pow(2, -.125 * depth);
    final sqrt1 = 1 / math.sqrt((n0 << lm).toDouble());
    for (var ch = 0; ch < c; ch++) {
      var prev1 = prev1logE[ch * nbEBands + i];
      var prev2 = prev2logE[ch * nbEBands + i];
      if (c == 1) {
        prev1 = math.max(prev1, prev1logE[nbEBands + i]);
        prev2 = math.max(prev2, prev2logE[nbEBands + i]);
      }
      var eDiff = logE[ch * nbEBands + i] - math.min(prev1, prev2);
      eDiff = math.max(0.0, eDiff);
      double r = 2 * math.pow(2, -eDiff).toDouble();
      if (lm == 3) r *= 1.41421356;
      r = math.min(thresh, r.toDouble());
      r = r * sqrt1;
      final xo = ch * size + (celtEBands[i] << lm);
      var renormalize = false;
      for (var k = 0; k < 1 << lm; k++) {
        if ((collapseMasks[i * c + ch] & (1 << k)) == 0) {
          for (var j = 0; j < n0; j++) {
            seed = celtLcgRand(seed);
            x[xo + (j << lm) + k] = (seed & 0x8000) != 0 ? r : -r;
          }
          renormalize = true;
        }
      }
      if (renormalize) renormaliseVector(x, xo, n0 << lm, 1.0);
    }
  }
}

/// The band energies back into spectrum values (libopus `denormalise_bands`).
void denormaliseBands(Float64List x, int xo, Float64List freq, Float64List bandLogE, int logEo, int start, int end, int m, bool silence) {
  const n0 = 120;
  final n = m * n0;
  var bound = m * celtEBands[end];
  if (silence) {
    bound = 0;
    start = end = 0;
  }
  var f = 0;
  var xp = xo + m * celtEBands[start];
  for (var i = 0; i < m * celtEBands[start]; i++) {
    freq[f++] = 0;
  }
  for (var i = start; i < end; i++) {
    var j = m * celtEBands[i];
    final bandEnd = m * celtEBands[i + 1];
    final lg = bandLogE[logEo + i] + celtEMeans[i];
    final g = math.pow(2, math.min(32.0, lg)).toDouble();
    do {
      freq[f++] = x[xp++] * g;
    } while (++j < bandEnd);
  }
  for (var i = bound; i < n; i++) {
    freq[i] = 0;
  }
}
