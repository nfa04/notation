import 'dart:math' as math;
import 'dart:typed_data';

/// A forward complex DFT of any size made of the factors 2, 3, 4 and 5 (CELT's FFT sizes are 60, 120, 240 and 480), in natural order.
class ComplexFft {
  final int n;
  final Float64List _cos, _sin;
  final Float64List _tr, _ti;
  ComplexFft(this.n)
      : _cos = Float64List(n),
        _sin = Float64List(n),
        _tr = Float64List(8),
        _ti = Float64List(8) {
    for (var k = 0; k < n; k++) {
      final a = -2 * math.pi * k / n;
      _cos[k] = math.cos(a);
      _sin[k] = math.sin(a);
    }
  }

  /// Transforms [re]/[im] (length [n]) in place.
  void transform(Float64List re, Float64List im) {
    final outR = Float64List(n), outI = Float64List(n);
    _rec(re, im, 0, 1, outR, outI, 0, n);
    re.setAll(0, outR);
    im.setAll(0, outI);
  }

  void _rec(Float64List inR, Float64List inI, int inOff, int inStride, Float64List outR, Float64List outI, int outOff, int len) {
    if (len == 1) {
      outR[outOff] = inR[inOff];
      outI[outOff] = inI[inOff];
      return;
    }
    final p = len % 4 == 0 ? 4 : len % 2 == 0 ? 2 : len % 3 == 0 ? 3 : len % 5 == 0 ? 5 : len;
    final m = len ~/ p;
    for (var r = 0; r < p; r++) {
      _rec(inR, inI, inOff + r * inStride, inStride * p, outR, outI, outOff + r * m, m);
    }
    final step = n ~/ len; // W_len^x = W_n^(x*step)
    final tr = p <= 8 ? _tr : Float64List(p), ti = p <= 8 ? _ti : Float64List(p);
    for (var k = 0; k < m; k++) {
      for (var r = 0; r < p; r++) {
        final idx = (r * k * step) % n;
        final xr = outR[outOff + r * m + k], xi = outI[outOff + r * m + k];
        tr[r] = xr * _cos[idx] - xi * _sin[idx];
        ti[r] = xr * _sin[idx] + xi * _cos[idx];
      }
      for (var q = 0; q < p; q++) {
        var sr = 0.0, si = 0.0;
        for (var r = 0; r < p; r++) {
          final idx = ((r * q * m) % len) * step;
          sr += tr[r] * _cos[idx] - ti[r] * _sin[idx];
          si += tr[r] * _sin[idx] + ti[r] * _cos[idx];
        }
        outR[outOff + q * m + k] = sr;
        outI[outOff + q * m + k] = si;
      }
    }
  }
}

/// CELT's inverse MDCT with its window overlap (libopus `clt_mdct_backward`), for the one 48 kHz mode: N = 1920 >> shift.
class CeltMdct {
  static const int maxN = 1920;
  final Map<int, ComplexFft> _ffts = {};
  final Map<int, Float64List> _trig = {};

  Float64List _trigFor(int n) => _trig.putIfAbsent(n, () {
        final n2 = n >> 1;
        final t = Float64List(n2);
        for (var i = 0; i < n2; i++) {
          t[i] = math.cos(2 * math.pi * (i + .125) / n);
        }
        return t;
      });

  /// Reads `N/2` values of [input] (every [stride]-th, from [inOff]) and writes `N/2 + overlap/2` values into [out] from [outOff]
  /// (adding the window overlap in place, as the decoder expects).
  void backward(Float64List input, int inOff, Float64List out, int outOff, Float64List window, int overlap, int shift, int stride) {
    final n = maxN >> shift;
    final n2 = n >> 1, n4 = n >> 2;
    final t = _trigFor(n);
    final fft = _ffts.putIfAbsent(n4, () => ComplexFft(n4));
    final zr = Float64List(n4), zi = Float64List(n4);
    // pre-rotate
    var xp1 = inOff, xp2 = inOff + stride * (n2 - 1);
    for (var i = 0; i < n4; i++) {
      final yr = input[xp2] * t[i] + input[xp1] * t[n4 + i];
      final yi = input[xp1] * t[i] - input[xp2] * t[n4 + i];
      // (real and imaginary are swapped because an FFT is used for the inverse)
      zr[i] = yi;
      zi[i] = yr;
      xp1 += 2 * stride;
      xp2 -= 2 * stride;
    }
    fft.transform(zr, zi);
    final base = outOff + (overlap >> 1);
    // post-rotate, de-shuffle from both ends at once
    var yp0 = base, yp1 = base + n2 - 2;
    for (var i = 0; i < (n4 + 1) >> 1; i++) {
      var re = zi[i], im = zr[i]; // (swapped back)
      var t0 = t[i], t1 = t[n4 + i];
      var yr = re * t0 + im * t1;
      var yi = re * t1 - im * t0;
      final j = n4 - 1 - i;
      re = zi[j];
      im = zr[j];
      out[yp0] = yr;
      out[yp1 + 1] = yi;
      t0 = t[n4 - i - 1];
      t1 = t[n2 - i - 1];
      yr = re * t0 + im * t1;
      yi = re * t1 - im * t0;
      out[yp1] = yr;
      out[yp0 + 1] = yi;
      yp0 += 2;
      yp1 -= 2;
    }
    // mirror on both sides for TDAC
    var xq = outOff + overlap - 1, yq = outOff;
    var wp1 = 0, wp2 = overlap - 1;
    for (var i = 0; i < overlap ~/ 2; i++) {
      final x1 = out[xq], x2 = out[yq];
      out[yq++] = window[wp2] * x2 - window[wp1] * x1;
      out[xq--] = window[wp1] * x2 + window[wp2] * x1;
      wp1++;
      wp2--;
    }
  }
}

/// floor(sqrt(v)) for a 32 bit value.
int isqrt32(int v) {
  var g = math.sqrt(v.toDouble()).floor();
  while (g * g > v) {
    g--;
  }
  while ((g + 1) * (g + 1) <= v) {
    g++;
  }
  return g;
}
