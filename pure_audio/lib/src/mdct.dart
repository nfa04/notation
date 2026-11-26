import 'dart:math' as math;
import 'dart:typed_data';

/// The inverse modified discrete cosine transform of [m] coefficients into 2·[m] samples (a power of two for [m]):
///   y[n] = scale · Σ X[k] · cos(π/m · (n + 1/2 + m/2) · (k + 1/2))
/// done through a DCT-IV that is computed by a complex FFT of m/2 points.
class Imdct {
  final int m;
  final double scale;
  final int _half;
  late final Float64List _twRe, _twIm; // exp(-iπ(n + 1/4)/m)
  late final Float64List _postRe, _postIm; // exp(-iπ n/m)
  late final Float64List _fftRe, _fftIm; // exp(-2πi k / half)
  late final Int32List _reverse;
  final Float64List _re, _im, _u;

  Imdct(this.m, this.scale)
      : _half = m ~/ 2,
        _re = Float64List(m ~/ 2),
        _im = Float64List(m ~/ 2),
        _u = Float64List(m) {
    assert(m >= 4 && (m & (m - 1)) == 0);
    _twRe = Float64List(_half);
    _twIm = Float64List(_half);
    _postRe = Float64List(_half);
    _postIm = Float64List(_half);
    for (var n = 0; n < _half; n++) {
      final a = -math.pi * (n + 0.25) / m;
      _twRe[n] = math.cos(a);
      _twIm[n] = math.sin(a);
      _postRe[n] = math.cos(-math.pi * n / m);
      _postIm[n] = math.sin(-math.pi * n / m);
    }
    _fftRe = Float64List(_half ~/ 2 == 0 ? 1 : _half ~/ 2);
    _fftIm = Float64List(_fftRe.length);
    for (var k = 0; k < _fftRe.length; k++) {
      final a = -2 * math.pi * k / _half;
      _fftRe[k] = math.cos(a);
      _fftIm[k] = math.sin(a);
    }
    _reverse = Int32List(_half);
    final bits = (math.log(_half) / math.ln2).round();
    for (var i = 0; i < _half; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _reverse[i] = r;
    }
  }

  void _fft() {
    final n = _half;
    for (var i = 0; i < n; i++) {
      final j = _reverse[i];
      if (j > i) {
        final tr = _re[i], ti = _im[i];
        _re[i] = _re[j];
        _im[i] = _im[j];
        _re[j] = tr;
        _im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final step = n ~/ size;
      final h = size >> 1;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < h; k++) {
          final wr = _fftRe[k * step], wi = _fftIm[k * step];
          final a = start + k, b = a + h;
          final xr = _re[b] * wr - _im[b] * wi;
          final xi = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - xr;
          _im[b] = _im[a] - xi;
          _re[a] += xr;
          _im[a] += xi;
        }
      }
    }
  }

  /// The DCT-IV of [x] (m numbers) into [_u]: u[n] = Σ x[k] cos(π/m (n + 1/2)(k + 1/2)).
  void _dct4(List<double> x) {
    for (var n = 0; n < _half; n++) {
      final a = x[2 * n].toDouble(), b = x[m - 1 - 2 * n].toDouble();
      _re[n] = a * _twRe[n] - b * _twIm[n];
      _im[n] = a * _twIm[n] + b * _twRe[n];
    }
    _fft();
    for (var k = 0; k < _half; k++) {
      final r = _re[k] * _postRe[k] - _im[k] * _postIm[k];
      final i = _re[k] * _postIm[k] + _im[k] * _postRe[k];
      _u[2 * k] = r;
      _u[m - 1 - 2 * k] = -i;
    }
  }

  /// Writes the 2·m samples of the transform of [input] (m numbers) to [out], from [outOffset] on.
  void run(List<double> input, List<double> out, [int outOffset = 0]) {
    _dct4(input);
    final h = m ~/ 2;
    // y[n] = v[n + m/2] with v[j] = u[j] on 0..m-1, -u[2m-1-j] on m..2m-1, -u[j-2m] on 2m..
    for (var n = 0; n < h; n++) {
      out[outOffset + n] = _u[n + h] * scale;
    }
    for (var n = h; n < h + m; n++) {
      out[outOffset + n] = -_u[2 * m - 1 - (n + h)] * scale;
    }
    for (var n = h + m; n < 2 * m; n++) {
      out[outOffset + n] = -_u[n + h - 2 * m] * scale;
    }
  }
}
