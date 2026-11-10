import 'dart:math' as math;
import 'dart:typed_data';

/// What Whisper wants of sound: 16 kHz mono, in windows of 30 seconds, as a log-mel spectrogram of 80 bands and 3000 frames.
const whisperSampleRate = 16000;
const whisperWindowSamples = 30 * whisperSampleRate;
const whisperFrames = 3000;
const whisperBands = 80;
const _nFft = 400;
const _hop = 160;
const _bins = _nFft ~/ 2 + 1;

double _hzToMel(double hz) => hz < 1000 ? hz / (200 / 3) : 1000 / (200 / 3) + math.log(hz / 1000) / (math.log(6.4) / 27);
double _melToHz(double mel) => mel < 1000 / (200 / 3) ? mel * (200 / 3) : 1000 * math.exp((math.log(6.4) / 27) * (mel - 1000 / (200 / 3)));

/// The 80 triangular filters on the Slaney mel scale (area-normalised) from 0 to 8000 Hz, as `bands x 201`.
final List<Float64List> _filters = () {
  final minMel = _hzToMel(0), maxMel = _hzToMel(8000);
  final edges = [for (var i = 0; i < whisperBands + 2; i++) _melToHz(minMel + (maxMel - minMel) * i / (whisperBands + 1))];
  final fft = [for (var i = 0; i < _bins; i++) 8000.0 * i / (_bins - 1)];
  final rows = <Float64List>[];
  for (var m = 0; m < whisperBands; m++) {
    final row = Float64List(_bins);
    final lower = edges[m], centre = edges[m + 1], upper = edges[m + 2];
    final norm = 2.0 / (upper - lower);
    for (var k = 0; k < _bins; k++) {
      final down = (fft[k] - lower) / (centre - lower);
      final up = (upper - fft[k]) / (upper - centre);
      row[k] = math.max(0, math.min(down, up)) * norm;
    }
    rows.add(row);
  }
  return rows;
}();

final Float64List _cos = Float64List.fromList([for (var i = 0; i < _nFft; i++) math.cos(2 * math.pi * i / _nFft)]);
final Float64List _sin = Float64List.fromList([for (var i = 0; i < _nFft; i++) -math.sin(2 * math.pi * i / _nFft)]);
final Float64List _window = Float64List.fromList([for (var i = 0; i < _nFft; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / _nFft)]);

/// The discrete Fourier transform of [n] points (n divides 400), by splitting off the smallest prime factor again and again.
(Float64List, Float64List) _fft(Float64List re, Float64List im, int n) {
  if (n == 1) return (re, im);
  var p = 2;
  while (n % p != 0) {
    p++;
  }
  final m = n ~/ p;
  final subRe = <Float64List>[], subIm = <Float64List>[];
  for (var k = 0; k < p; k++) {
    final r = Float64List(m), i = Float64List(m);
    for (var j = 0; j < m; j++) {
      r[j] = re[j * p + k];
      i[j] = im[j * p + k];
    }
    final (fr, fi) = _fft(r, i, m);
    subRe.add(fr);
    subIm.add(fi);
  }
  final outRe = Float64List(n), outIm = Float64List(n);
  final step = _nFft ~/ n; // W_n^a = W_400^(a * 400/n)
  for (var q = 0; q < m; q++) {
    for (var r = 0; r < p; r++) {
      final out = q + m * r;
      var sr = 0.0, si = 0.0;
      for (var k = 0; k < p; k++) {
        final a = (k * out) % n * step;
        final c = _cos[a], s = _sin[a];
        sr += subRe[k][q] * c - subIm[k][q] * s;
        si += subRe[k][q] * s + subIm[k][q] * c;
      }
      outRe[out] = sr;
      outIm[out] = si;
    }
  }
  return (outRe, outIm);
}

/// The log-mel spectrogram of [samples] (16 kHz, mono, -1..1; at most 30 seconds, more is cut), as 80 x 3000 numbers in one
/// list, band after band. What the encoder of Whisper takes. The same numbers as the feature extractor of the reference
/// implementation.
Float32List logMelSpectrogram(Float32List samples) {
  final n = math.min(samples.length, whisperWindowSamples);
  final x = Float64List(whisperWindowSamples);
  var last = -1;
  for (var i = 0; i < n; i++) {
    x[i] = samples[i];
    if (samples[i] != 0) last = i;
  }
  // the signal is read with a half window of its own mirrored in front of it and behind it
  const pad = _nFft ~/ 2;
  final padded = Float64List(whisperWindowSamples + 2 * pad);
  for (var i = 0; i < whisperWindowSamples; i++) {
    padded[pad + i] = x[i];
  }
  for (var j = 0; j < pad; j++) {
    padded[j] = x[pad - j];
    padded[pad + whisperWindowSamples + j] = x[whisperWindowSamples - 2 - j];
  }
  final lastPadded = last < 0 ? -1 : last + pad;
  // 3001 frames are made and the last is dropped
  final mel = List<Float64List>.generate(whisperFrames, (_) => Float64List(whisperBands));
  var peak = -1e30;
  final power = Float64List(_bins);
  final re = Float64List(_nFft), im = Float64List(_nFft);
  const silent = -10.0; // log10 of the floor 1e-10: a frame with nothing in it
  for (var f = 0; f < whisperFrames; f++) {
    final start = f * _hop;
    final empty = start > lastPadded; // (the window has only zeros in it: the right-hand mirror of zeros is zeros too)
    if (empty) {
      for (var b = 0; b < whisperBands; b++) {
        mel[f][b] = silent;
      }
      peak = math.max(peak, silent);
      continue;
    }
    for (var i = 0; i < _nFft; i++) {
      re[i] = padded[start + i] * _window[i];
      im[i] = 0;
    }
    final (fr, fi) = _fft(Float64List.fromList(re), Float64List.fromList(im), _nFft);
    for (var k = 0; k < _bins; k++) {
      power[k] = fr[k] * fr[k] + fi[k] * fi[k];
    }
    for (var b = 0; b < whisperBands; b++) {
      var s = 0.0;
      final row = _filters[b];
      for (var k = 0; k < _bins; k++) {
        s += row[k] * power[k];
      }
      final v = _log10(math.max(s, 1e-10));
      mel[f][b] = v;
      if (v > peak) peak = v;
    }
  }
  final out = Float32List(whisperBands * whisperFrames);
  for (var b = 0; b < whisperBands; b++) {
    for (var f = 0; f < whisperFrames; f++) {
      out[b * whisperFrames + f] = ((math.max(mel[f][b], peak - 8) + 4) / 4);
    }
  }
  return out;
}

double _log10(double v) => math.log(v) / math.ln10;

/// Cuts [samples] into pieces of at most [maxSeconds], each ending where it is quietest in its last [searchSeconds], so that
/// a word is not cut in two when it can be helped. Pieces shorter than [minSeconds] at the end join the one before.
List<Float32List> splitAtQuiet(Float32List samples, {double maxSeconds = 29, double searchSeconds = 5, double minSeconds = 1}) {
  final max = (maxSeconds * whisperSampleRate).round();
  if (samples.length <= max) return [samples];
  final out = <Float32List>[];
  var start = 0;
  final frame = (0.2 * whisperSampleRate).round();
  while (samples.length - start > max) {
    final from = start + max - (searchSeconds * whisperSampleRate).round();
    var bestAt = start + max;
    var best = double.infinity;
    for (var at = from; at + frame <= start + max; at += frame ~/ 2) {
      var e = 0.0;
      for (var i = at; i < at + frame; i++) {
        e += samples[i] * samples[i];
      }
      if (e < best) {
        best = e;
        bestAt = at + frame ~/ 2;
      }
    }
    out.add(Float32List.sublistView(samples, start, bestAt));
    start = bestAt;
  }
  final rest = Float32List.sublistView(samples, start);
  if (rest.length < minSeconds * whisperSampleRate && out.isNotEmpty) {
    final joined = Float32List(out.last.length + rest.length)
      ..setAll(0, out.last)
      ..setAll(out.last.length, rest);
    out[out.length - 1] = joined;
  } else {
    out.add(rest);
  }
  return out;
}

/// How loud [samples] are (root mean square), to tell silence from speech.
double loudness(Float32List samples) {
  if (samples.isEmpty) return 0;
  var e = 0.0;
  for (final s in samples) {
    e += s * s;
  }
  return math.sqrt(e / samples.length);
}
