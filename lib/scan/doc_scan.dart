import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

/// Making a clean page of a photograph of one: finding the corners of the paper, straightening it, and cleaning it up.

/// How a scanned page is cleaned up.
enum ScanFilter {
  /// As photographed.
  original('Original'),

  /// Grey, evened out (no shadows, a white page), keeping pencil and print.
  clean('Clean'),

  /// Black and white, like a copier.
  blackWhite('Black and white');

  final String label;
  const ScanFilter(this.label);
}

/// The corners of the paper in [image], as fractions of its width and height: top left, top right, bottom right, bottom left.
/// Looks for the big bright area (paper is lighter than the table it lies on); if there is none the corners are a little inside
/// the picture.
List<Offset> findPageCorners(img.Image image) {
  const fallback = [Offset(0.05, 0.05), Offset(0.95, 0.05), Offset(0.95, 0.95), Offset(0.05, 0.95)];
  const side = 200;
  final scale = side / math.max(image.width, image.height);
  final small = img.copyResize(image, width: math.max(8, (image.width * scale).round()), height: math.max(8, (image.height * scale).round()), interpolation: img.Interpolation.average);
  final w = small.width, h = small.height;
  final grey = List<int>.filled(w * h, 0);
  final histogram = List<int>.filled(256, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      final v = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      grey[y * w + x] = v;
      histogram[v]++;
    }
  }
  // Otsu: the level that splits the pixels into two groups as unlike as can be
  final total = w * h;
  var sumAll = 0.0;
  for (var i = 0; i < 256; i++) {
    sumAll += i * histogram[i];
  }
  var weightBelow = 0, sumBelow = 0.0, bestLevel = 128, bestVariance = -1.0;
  for (var t = 0; t < 256; t++) {
    weightBelow += histogram[t];
    if (weightBelow == 0 || weightBelow == total) continue;
    sumBelow += t * histogram[t];
    final meanBelow = sumBelow / weightBelow, meanAbove = (sumAll - sumBelow) / (total - weightBelow);
    final variance = weightBelow * (total - weightBelow) * (meanBelow - meanAbove) * (meanBelow - meanAbove);
    if (variance > bestVariance) {
      bestVariance = variance;
      bestLevel = t;
    }
  }
  // the biggest bright area that is not just the picture's whole frame
  final label = List<int>.filled(w * h, 0);
  var bestSize = 0, best = 0, next = 0;
  final stack = <int>[];
  for (var s = 0; s < w * h; s++) {
    if (label[s] != 0 || grey[s] <= bestLevel) continue;
    next++;
    var size = 0;
    label[s] = next;
    stack.add(s);
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      size++;
      final x = i % w, y = i ~/ w;
      for (final n in [if (x > 0) i - 1, if (x < w - 1) i + 1, if (y > 0) i - w, if (y < h - 1) i + w]) {
        if (label[n] == 0 && grey[n] > bestLevel) {
          label[n] = next;
          stack.add(n);
        }
      }
    }
    if (size > bestSize) {
      bestSize = size;
      best = next;
    }
  }
  if (best == 0 || bestSize < total * 0.12) return fallback;
  // the corners are the points of the area farthest out along the four diagonals
  Offset? tl, tr, br, bl;
  var minSum = double.infinity, maxSum = -double.infinity, minDiff = double.infinity, maxDiff = -double.infinity;
  for (var i = 0; i < w * h; i++) {
    if (label[i] != best) continue;
    final x = (i % w).toDouble(), y = (i ~/ w).toDouble();
    if (x + y < minSum) {
      minSum = x + y;
      tl = Offset(x, y);
    }
    if (x + y > maxSum) {
      maxSum = x + y;
      br = Offset(x, y);
    }
    if (x - y > maxDiff) {
      maxDiff = x - y;
      tr = Offset(x, y);
    }
    if (x - y < minDiff) {
      minDiff = x - y;
      bl = Offset(x, y);
    }
  }
  Offset frac(Offset o, double dx, double dy) => Offset(((o.dx + dx) / w).clamp(0.0, 1.0), ((o.dy + dy) / h).clamp(0.0, 1.0));
  // (a pixel's own width: the corner pixel is inside the paper, the corner is its outer edge)
  return [frac(tl!, 0, 0), frac(tr!, 1, 0), frac(br!, 1, 1), frac(bl!, 0, 1)];
}

/// Solves the 8 numbers of the projective map that takes the four points [from] to the four points [to].
List<double> _homography(List<Offset> from, List<Offset> to) {
  final a = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final x = from[i].dx, y = from[i].dy, u = to[i].dx, v = to[i].dy;
    a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u];
    a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v];
  }
  for (var c = 0; c < 8; c++) {
    var pivot = c;
    for (var r = c + 1; r < 8; r++) {
      if (a[r][c].abs() > a[pivot][c].abs()) pivot = r;
    }
    final t = a[c];
    a[c] = a[pivot];
    a[pivot] = t;
    final d = a[c][c];
    if (d.abs() < 1e-12) throw const FormatException('The corners are not a page.');
    for (var k = c; k < 9; k++) {
      a[c][k] /= d;
    }
    for (var r = 0; r < 8; r++) {
      if (r == c) continue;
      final f = a[r][c];
      if (f == 0) continue;
      for (var k = c; k < 9; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  return [for (var i = 0; i < 8; i++) a[i][8]];
}

/// The page inside [corners] (fractions of the picture, top left, top right, bottom right, bottom left) as a straight, upright
/// picture, at most [maxSide] pixels along its long side.
img.Image straightenPage(img.Image source, List<Offset> corners, {int maxSide = 2400}) {
  final pts = [for (final c in corners) Offset(c.dx * source.width, c.dy * source.height)];
  double dist(Offset a, Offset b) => (a - b).distance;
  var w = math.max(dist(pts[0], pts[1]), dist(pts[3], pts[2]));
  var h = math.max(dist(pts[0], pts[3]), dist(pts[1], pts[2]));
  final shrink = math.min(1.0, maxSide / math.max(w, h));
  w = math.max(16, w * shrink);
  h = math.max(16, h * shrink);
  final out = img.Image(width: w.round(), height: h.round(), numChannels: 3);
  // from the straight page to the photograph, so that every pixel of the page asks where it comes from
  final hm = _homography([Offset.zero, Offset(w, 0), Offset(w, h), Offset(0, h)], pts);
  final src = source.convert(numChannels: 3);
  for (var y = 0; y < out.height; y++) {
    for (var x = 0; x < out.width; x++) {
      final d = hm[6] * x + hm[7] * y + 1;
      final sx = (hm[0] * x + hm[1] * y + hm[2]) / d, sy = (hm[3] * x + hm[4] * y + hm[5]) / d;
      final p = src.getPixelInterpolate(sx.clamp(0, src.width - 1.0), sy.clamp(0, src.height - 1.0), interpolation: img.Interpolation.linear);
      out.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }
  return out;
}

/// Cleans [page] up as [filter] says.
img.Image applyFilter(img.Image page, ScanFilter filter) {
  if (filter == ScanFilter.original) return page;
  final grey = img.grayscale(page.clone());
  // the paper's own brightness at each place (smooth, from a small copy): dividing by it takes the shadows and the uneven light out
  final side = math.max(16, math.min(grey.width, grey.height) ~/ 12);
  final tinyW = math.max(8, grey.width ~/ side), tinyH = math.max(8, grey.height ~/ side);
  final tiny = img.copyResize(grey, width: tinyW, height: tinyH, interpolation: img.Interpolation.average);
  // text is thin: the paper level is the brightest of the neighbourhood, so the blur is of a local maximum
  final bright = img.Image(width: tinyW, height: tinyH, numChannels: 3);
  for (var y = 0; y < tinyH; y++) {
    for (var x = 0; x < tinyW; x++) {
      var m = 0.0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          m = math.max(m, tiny.getPixel((x + dx).clamp(0, tinyW - 1), (y + dy).clamp(0, tinyH - 1)).r.toDouble());
        }
      }
      bright.setPixelRgb(x, y, m, m, m);
    }
  }
  final paper = img.copyResize(img.gaussianBlur(bright, radius: 2), width: grey.width, height: grey.height, interpolation: img.Interpolation.linear);
  final out = img.Image(width: grey.width, height: grey.height, numChannels: 3);
  for (var y = 0; y < grey.height; y++) {
    for (var x = 0; x < grey.width; x++) {
      final g = grey.getPixel(x, y).r.toDouble();
      final b = math.max(1.0, paper.getPixel(x, y).r.toDouble());
      var v = (g / b * 255).clamp(0.0, 255.0);
      if (filter == ScanFilter.blackWhite) {
        v = v < 170 ? 0 : 255;
      } else {
        // a little contrast: the paper white, print dark
        v = ((v - 40) / (235 - 40) * 255).clamp(0.0, 255.0);
      }
      out.setPixelRgb(x, y, v, v, v);
    }
  }
  return out;
}
