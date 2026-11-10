import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A change of colour for the whole picture, applied after the sliders.
enum PictureFilter {
  none('None'),
  grayscale('Grayscale'),
  sepia('Sepia'),
  invert('Invert'),
  blackWhite('Black and white'),

  /// A pencil drawing of the picture: the grey picture dodged by its blurred negative, which leaves the shading as soft strokes.
  sketch('Pencil sketch'),

  /// Only the edges of the picture, dark on white, as a line drawing to trace or colour in.
  lineDrawing('Line drawing');

  final String label;
  const PictureFilter(this.label);
}

/// How the background of a picture is taken out (made transparent).
enum BackgroundRemoval {
  none('Keep'),

  /// From the edges of the picture inwards, as far as the colour stays close to the colour of the background: what is enclosed by
  /// the picture's subject keeps its colour (the white of an eye stays).
  fromEdges('Remove the background'),

  /// Every pixel of about the colour, wherever it is (a signature on white paper: all the white goes).
  everywhere('Remove this colour everywhere'),

  /// Finds the main subject of a photograph (a person, an animal, an object) with a model that runs on the device, and keeps only
  /// that. Needs the model (see `subject_service.dart`).
  subject('Find the subject');

  final String label;
  const BackgroundRemoval(this.label);
}

/// What to do to a picture. The steps are taken in this order: turn and flip, crop, colours (brightness, contrast, saturation), the
/// filter, then the background.
class PictureEdit {
  /// Quarter turns clockwise (0 to 3), then flips.
  final int turns;
  final bool flipHorizontal, flipVertical;

  /// What is cut off each side of the turned picture, as a part of its width or height (0 to 0.9; left and right together are less
  /// than 0.95 of it, so that something is left).
  final double cropLeft, cropTop, cropRight, cropBottom;

  /// -1 to 1; 0 changes nothing.
  final double brightness, contrast, saturation;
  final PictureFilter filter;
  final BackgroundRemoval background;

  /// How far from the background colour (0 to 1; of the greatest difference there is) a pixel still counts as background, and the
  /// width (also 0 to 1) of the soft edge that follows it.
  final double tolerance, softness;

  /// The colour of the background, as ARGB, when it was picked on the picture; null: the colour most of the edge has.
  final int? backgroundColor;

  /// For [BackgroundRemoval.subject]: how sure the model has to be (0 to 1) that a pixel is the subject for it to stay.
  final double subjectCut;

  const PictureEdit({
    this.turns = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.cropLeft = 0,
    this.cropTop = 0,
    this.cropRight = 0,
    this.cropBottom = 0,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.filter = PictureFilter.none,
    this.background = BackgroundRemoval.none,
    this.tolerance = 0.12,
    this.softness = 0.06,
    this.backgroundColor,
    this.subjectCut = 0.5,
  });

  static const none = PictureEdit();

  /// Whether this changes nothing.
  bool get isNone => this == none || (turns % 4 == 0 && !flipHorizontal && !flipVertical && !cropped && !recoloured && background == BackgroundRemoval.none);

  bool get cropped => cropLeft > 0 || cropTop > 0 || cropRight > 0 || cropBottom > 0;

  bool get recoloured => brightness != 0 || contrast != 0 || saturation != 0 || filter != PictureFilter.none;

  /// Whether the result has transparent parts (and so has to be a PNG).
  bool get transparent => background != BackgroundRemoval.none;

  PictureEdit copyWith({
    int? turns,
    bool? flipHorizontal,
    bool? flipVertical,
    double? cropLeft,
    double? cropTop,
    double? cropRight,
    double? cropBottom,
    double? brightness,
    double? contrast,
    double? saturation,
    PictureFilter? filter,
    BackgroundRemoval? background,
    double? tolerance,
    double? softness,
    int? backgroundColor,
    bool clearBackgroundColor = false,
    double? subjectCut,
  }) =>
      PictureEdit(
        turns: (turns ?? this.turns) % 4,
        flipHorizontal: flipHorizontal ?? this.flipHorizontal,
        flipVertical: flipVertical ?? this.flipVertical,
        cropLeft: _crop(cropLeft ?? this.cropLeft),
        cropTop: _crop(cropTop ?? this.cropTop),
        cropRight: _crop(cropRight ?? this.cropRight),
        cropBottom: _crop(cropBottom ?? this.cropBottom),
        brightness: (brightness ?? this.brightness).clamp(-1.0, 1.0),
        contrast: (contrast ?? this.contrast).clamp(-1.0, 1.0),
        saturation: (saturation ?? this.saturation).clamp(-1.0, 1.0),
        filter: filter ?? this.filter,
        background: background ?? this.background,
        tolerance: (tolerance ?? this.tolerance).clamp(0.0, 1.0),
        softness: (softness ?? this.softness).clamp(0.0, 1.0),
        backgroundColor: clearBackgroundColor ? null : backgroundColor ?? this.backgroundColor,
        subjectCut: (subjectCut ?? this.subjectCut).clamp(0.05, 0.95),
      );

  static double _crop(double v) => v.clamp(0.0, 0.9);

  @override
  bool operator ==(Object other) =>
      other is PictureEdit &&
      other.turns == turns &&
      other.flipHorizontal == flipHorizontal &&
      other.flipVertical == flipVertical &&
      other.cropLeft == cropLeft &&
      other.cropTop == cropTop &&
      other.cropRight == cropRight &&
      other.cropBottom == cropBottom &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.filter == filter &&
      other.background == background &&
      other.tolerance == tolerance &&
      other.softness == softness &&
      other.backgroundColor == backgroundColor &&
      other.subjectCut == subjectCut;

  @override
  int get hashCode => Object.hash(turns, flipHorizontal, flipVertical, cropLeft, cropTop, cropRight, cropBottom, brightness, contrast, saturation, filter, background, tolerance, softness, backgroundColor, subjectCut);
}

/// A picture as it is worked on: [width] by [height] pixels, four bytes (red, green, blue, alpha) for each.
class RgbaPicture {
  final int width, height;
  final Uint8List rgba;

  RgbaPicture(this.width, this.height, this.rgba) : assert(rgba.length == width * height * 4);

  /// A picture of one colour.
  factory RgbaPicture.filled(int width, int height, int r, int g, int b, [int a = 255]) {
    final bytes = Uint8List(width * height * 4);
    for (var i = 0; i < bytes.length; i += 4) {
      bytes[i] = r;
      bytes[i + 1] = g;
      bytes[i + 2] = b;
      bytes[i + 3] = a;
    }
    return RgbaPicture(width, height, bytes);
  }

  int _at(int x, int y) => (y * width + x) * 4;

  /// The pixel at [x], [y] as (red, green, blue, alpha).
  (int, int, int, int) pixel(int x, int y) {
    final i = _at(x, y);
    return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]);
  }

  void setPixel(int x, int y, int r, int g, int b, [int a = 255]) {
    final i = _at(x, y);
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = a;
  }

  /// Whether anything of it is see-through.
  bool get hasTransparency {
    for (var i = 3; i < rgba.length; i += 4) {
      if (rgba[i] < 255) return true;
    }
    return false;
  }

  RgbaPicture copy() => RgbaPicture(width, height, Uint8List.fromList(rgba));

  /// Turned [turns] quarter turns clockwise.
  RgbaPicture rotated(int turns) {
    final t = turns % 4;
    if (t == 0) return copy();
    final w = t == 2 ? width : height, h = t == 2 ? height : width;
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        // where the pixel (x, y) goes
        final (nx, ny) = switch (t) {
          1 => (height - 1 - y, x),
          2 => (width - 1 - x, height - 1 - y),
          _ => (y, width - 1 - x),
        };
        final from = _at(x, y), to = (ny * w + nx) * 4;
        out[to] = rgba[from];
        out[to + 1] = rgba[from + 1];
        out[to + 2] = rgba[from + 2];
        out[to + 3] = rgba[from + 3];
      }
    }
    return RgbaPicture(w, h, out);
  }

  RgbaPicture flipped({bool horizontal = false, bool vertical = false}) {
    if (!horizontal && !vertical) return copy();
    final out = Uint8List(rgba.length);
    for (var y = 0; y < height; y++) {
      final sy = vertical ? height - 1 - y : y;
      for (var x = 0; x < width; x++) {
        final sx = horizontal ? width - 1 - x : x;
        final from = _at(sx, sy), to = _at(x, y);
        out[to] = rgba[from];
        out[to + 1] = rgba[from + 1];
        out[to + 2] = rgba[from + 2];
        out[to + 3] = rgba[from + 3];
      }
    }
    return RgbaPicture(width, height, out);
  }

  /// The part of the picture left when the given parts of each side are cut off (always at least one pixel).
  RgbaPicture cropped(double left, double top, double right, double bottom) {
    final x0 = (width * left).round().clamp(0, width - 1);
    final y0 = (height * top).round().clamp(0, height - 1);
    final x1 = (width - width * right).round().clamp(x0 + 1, width);
    final y1 = (height - height * bottom).round().clamp(y0 + 1, height);
    final w = x1 - x0, h = y1 - y0;
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      out.setRange(y * w * 4, (y + 1) * w * 4, rgba, _at(x0, y0 + y));
    }
    return RgbaPicture(w, h, out);
  }
}

int _byte(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

/// What a model that finds the subject of a picture said: for each pixel of a picture of [width] by [height], how sure it is, from
/// 0 to 1, that it belongs to the subject.
class SubjectMatte {
  final int width, height;
  final Float32List values;

  SubjectMatte(this.width, this.height, this.values) : assert(values.length == width * height);

  /// The matte as a picture of [w] by [h] (grey: the red, green and blue of a pixel are its value, from 0 to 255), smoothly made
  /// larger or smaller.
  RgbaPicture asPicture(int w, int h) {
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final fy = ((y + 0.5) * height / h - 0.5).clamp(0.0, height - 1.0);
      final y0 = fy.floor(), y1 = math.min(height - 1, y0 + 1), ty = fy - y0;
      for (var x = 0; x < w; x++) {
        final fx = ((x + 0.5) * width / w - 0.5).clamp(0.0, width - 1.0);
        final x0 = fx.floor(), x1 = math.min(width - 1, x0 + 1), tx = fx - x0;
        final top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx;
        final bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx;
        final v = _byte((top * (1 - ty) + bottom * ty) * 255);
        final i = (y * w + x) * 4;
        out[i] = out[i + 1] = out[i + 2] = v;
        out[i + 3] = 255;
      }
    }
    return RgbaPicture(w, h, out);
  }
}

/// The side of the square a picture is made into for the model that finds the subject.
const int subjectModelSide = 320;

/// What the subject model is given for [picture]: its red, green and blue as three planes of [subjectModelSide] squared numbers,
/// the picture made that size (smoothly, whatever its proportions) and each plane brought to what the model was trained on
/// (scaled by the brightest value in the picture, then the mean taken off and divided by the spread of the ImageNet pictures).
Float32List subjectModelInput(RgbaPicture picture) {
  const side = subjectModelSide;
  const mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225];
  final plane = side * side;
  final out = Float32List(3 * plane);
  var brightest = 1;
  for (var i = 0; i < picture.rgba.length; i += 4) {
    brightest = math.max(brightest, math.max(picture.rgba[i], math.max(picture.rgba[i + 1], picture.rgba[i + 2])));
  }
  final w = picture.width, h = picture.height;
  for (var y = 0; y < side; y++) {
    // each pixel of the small picture is the average of the box of the large one it covers (a bilinear look at a few points is
    // too jagged for a photograph of many megapixels made so small)
    final y0 = (y * h / side).floor(), y1 = math.max(y0 + 1, ((y + 1) * h / side).ceil());
    for (var x = 0; x < side; x++) {
      final x0 = (x * w / side).floor(), x1 = math.max(x0 + 1, ((x + 1) * w / side).ceil());
      var r = 0.0, g = 0.0, b = 0.0, n = 0;
      // (at most a few samples across each way: the box is stepped over)
      final dy = math.max(1, (y1 - y0) ~/ 4), dx = math.max(1, (x1 - x0) ~/ 4);
      for (var yy = y0; yy < math.min(h, y1); yy += dy) {
        for (var xx = x0; xx < math.min(w, x1); xx += dx) {
          final i = (yy * w + xx) * 4;
          r += picture.rgba[i];
          g += picture.rgba[i + 1];
          b += picture.rgba[i + 2];
          n++;
        }
      }
      if (n == 0) n = 1;
      final at = y * side + x;
      out[at] = (r / n / brightest - mean[0]) / std[0];
      out[plane + at] = (g / n / brightest - mean[1]) / std[1];
      out[2 * plane + at] = (b / n / brightest - mean[2]) / std[2];
    }
  }
  return out;
}

/// The matte from what the model answered ([subjectModelSide] squared numbers): stretched so that the weakest is 0 and the
/// strongest 1, as the model's makers do.
SubjectMatte subjectMatteFrom(Float32List answer) {
  const side = subjectModelSide;
  assert(answer.length == side * side);
  var lo = double.infinity, hi = -double.infinity;
  for (final v in answer) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final range = hi - lo;
  final out = Float32List(answer.length);
  for (var i = 0; i < answer.length; i++) {
    out[i] = range < 1e-6 ? 0 : ((answer[i] - lo) / range).clamp(0.0, 1.0);
  }
  return SubjectMatte(side, side, out);
}

RgbaPicture _geometry(RgbaPicture picture, PictureEdit edit) {
  var out = picture.rotated(edit.turns);
  if (edit.flipHorizontal || edit.flipVertical) out = out.flipped(horizontal: edit.flipHorizontal, vertical: edit.flipVertical);
  if (edit.cropped) out = out.cropped(edit.cropLeft, edit.cropTop, edit.cropRight, edit.cropBottom);
  return out;
}

/// [picture] with [edit] done to it (the original is not changed). [subject] is what the model said of [picture] as it is before
/// anything is done to it (it is turned, flipped and cut with the picture); without it, finding the subject changes nothing.
RgbaPicture applyPictureEdit(RgbaPicture picture, PictureEdit edit, {SubjectMatte? subject}) {
  final out = _geometry(picture, edit);
  if (edit.recoloured) _recolour(out, edit);
  if (edit.filter == PictureFilter.sketch) _sketch(out);
  if (edit.filter == PictureFilter.lineDrawing) _lineDrawing(out);
  if (edit.background == BackgroundRemoval.subject) {
    if (subject != null) keepSubject(out, _geometry(subject.asPicture(picture.width, picture.height), edit), edit);
  } else if (edit.background != BackgroundRemoval.none) {
    removeBackground(out, edit);
  }
  return out;
}

/// Makes everything but the subject of [p] transparent, in place: [matte] is the matte as a picture of the size of [p]. A pixel
/// the model is surer of than [PictureEdit.subjectCut] stays, one that it is less sure of goes, with [PictureEdit.softness] of soft
/// edge between.
void keepSubject(RgbaPicture p, RgbaPicture matte, PictureEdit edit) {
  assert(p.width == matte.width && p.height == matte.height);
  final half = math.max(edit.softness, 0.01) / 2;
  final lo = edit.subjectCut - half, span = 2 * half;
  final data = p.rgba;
  for (var i = 0; i < data.length; i += 4) {
    final m = matte.rgba[i] / 255;
    final a = ((m - lo) / span).clamp(0.0, 1.0);
    data[i + 3] = (data[i + 3] * a).round();
  }
}

void _recolour(RgbaPicture p, PictureEdit e) {
  final data = p.rgba;
  final shift = e.brightness * 255;
  // contrast 0 leaves the picture, -1 makes it flat grey, towards 1 it gets steeper and steeper
  final slope = math.tan((e.contrast + 1) * math.pi / 4);
  final saturate = 1 + e.saturation;
  for (var i = 0; i < data.length; i += 4) {
    var r = data[i] + shift, g = data[i + 1] + shift, b = data[i + 2] + shift;
    if (e.contrast != 0) {
      r = (r - 128) * slope + 128;
      g = (g - 128) * slope + 128;
      b = (b - 128) * slope + 128;
    }
    if (e.saturation != 0) {
      final luma = 0.299 * r + 0.587 * g + 0.114 * b;
      r = luma + (r - luma) * saturate;
      g = luma + (g - luma) * saturate;
      b = luma + (b - luma) * saturate;
    }
    r = _byte(r).toDouble();
    g = _byte(g).toDouble();
    b = _byte(b).toDouble();
    switch (e.filter) {
      case PictureFilter.none:
        break;
      case PictureFilter.grayscale:
        final l = 0.299 * r + 0.587 * g + 0.114 * b;
        r = g = b = l;
      case PictureFilter.sepia:
        final nr = 0.393 * r + 0.769 * g + 0.189 * b;
        final ng = 0.349 * r + 0.686 * g + 0.168 * b;
        final nb = 0.272 * r + 0.534 * g + 0.131 * b;
        r = nr;
        g = ng;
        b = nb;
      case PictureFilter.invert:
        r = 255 - r;
        g = 255 - g;
        b = 255 - b;
      case PictureFilter.blackWhite:
        final l = 0.299 * r + 0.587 * g + 0.114 * b >= 128 ? 255.0 : 0.0;
        r = g = b = l;
      case PictureFilter.sketch:
      case PictureFilter.lineDrawing:
        break; // (they look at a pixel's neighbours: done after this, over the whole picture)
    }
    data[i] = _byte(r);
    data[i + 1] = _byte(g);
    data[i + 2] = _byte(b);
  }
}

/// The grey levels of [p] (0 to 255).
Float32List _greys(RgbaPicture p) {
  final out = Float32List(p.width * p.height);
  for (var i = 0, k = 0; i < p.rgba.length; i += 4, k++) {
    out[k] = 0.299 * p.rgba[i] + 0.587 * p.rgba[i + 1] + 0.114 * p.rgba[i + 2];
  }
  return out;
}

/// [v] (a [w] by [h] picture) blurred by averaging over a square of 2 * [r] + 1 sides, two times over (which is close to a soft blur).
Float32List _blurred(Float32List v, int w, int h, int r) {
  Float32List pass(Float32List input, bool across) {
    final out = Float32List(input.length);
    final lines = across ? h : w, length = across ? w : h;
    for (var line = 0; line < lines; line++) {
      int at(int k) => across ? line * w + k : k * w + line;
      var sum = 0.0;
      // (the edge counts as the nearest pixel)
      for (var k = -r; k <= r; k++) {
        sum += input[at(k.clamp(0, length - 1))];
      }
      for (var k = 0; k < length; k++) {
        out[at(k)] = sum / (2 * r + 1);
        sum += input[at((k + r + 1).clamp(0, length - 1))] - input[at((k - r).clamp(0, length - 1))];
      }
    }
    return out;
  }

  var out = v;
  for (var i = 0; i < 2; i++) {
    out = pass(pass(out, true), false);
  }
  return out;
}

void _setGreys(RgbaPicture p, Float32List grey) {
  for (var i = 0, k = 0; i < p.rgba.length; i += 4, k++) {
    final v = _byte(grey[k]);
    p.rgba[i] = v;
    p.rgba[i + 1] = v;
    p.rgba[i + 2] = v;
  }
}

/// The pencil sketch of [p], in place (the "colour dodge" of the grey picture by its blurred negative).
void _sketch(RgbaPicture p) {
  final w = p.width, h = p.height;
  if (w == 0 || h == 0) return;
  final grey = _greys(p);
  final blur = _blurred(Float32List.fromList([for (final g in grey) 255 - g]), w, h, math.max(2, math.max(w, h) ~/ 120));
  final out = Float32List(grey.length);
  for (var i = 0; i < grey.length; i++) {
    out[i] = math.min(255.0, grey[i] * 255 / math.max(1.0, 255 - blur[i]));
  }
  _setGreys(p, out);
}

/// The edges of [p] as dark lines on white, in place (Sobel's edges of the slightly blurred grey picture).
void _lineDrawing(RgbaPicture p) {
  final w = p.width, h = p.height;
  if (w == 0 || h == 0) return;
  final g = _blurred(_greys(p), w, h, math.max(1, math.max(w, h) ~/ 300));
  final out = Float32List(g.length)..fillRange(0, g.length, 255);
  double at(int x, int y) => g[y.clamp(0, h - 1) * w + x.clamp(0, w - 1)];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final gx = at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1) - at(x - 1, y - 1) - 2 * at(x - 1, y) - at(x - 1, y + 1);
      final gy = at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1) - at(x - 1, y - 1) - 2 * at(x, y - 1) - at(x + 1, y - 1);
      final edge = math.sqrt(gx * gx + gy * gy);
      out[y * w + x] = 255 - (edge * 2.2).clamp(0.0, 255.0);
    }
  }
  _setGreys(p, out);
}

/// The colour most of the pixels on the edge of [p] have (the colour of the background of a photo or a scan): the edge's colours
/// are sorted into boxes of 16 levels of each colour, and the average of the fullest box is it.
(int, int, int) edgeColour(RgbaPicture p) {
  final counts = <int, int>{};
  final sums = <int, List<int>>{};
  void add(int x, int y) {
    final (r, g, b, a) = p.pixel(x, y);
    if (a < 128) return;
    final key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
    counts[key] = (counts[key] ?? 0) + 1;
    final s = sums.putIfAbsent(key, () => [0, 0, 0]);
    s[0] += r;
    s[1] += g;
    s[2] += b;
  }

  for (var x = 0; x < p.width; x++) {
    add(x, 0);
    add(x, p.height - 1);
  }
  for (var y = 1; y < p.height - 1; y++) {
    add(0, y);
    add(p.width - 1, y);
  }
  if (counts.isEmpty) return (255, 255, 255);
  final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  final n = counts[best]!, s = sums[best]!;
  return (s[0] ~/ n, s[1] ~/ n, s[2] ~/ n);
}

/// Makes the background of [p] transparent, in place, as [edit] says (see [BackgroundRemoval]). The difference between two colours
/// is their distance in red, green and blue, as a part of the greatest there is; a pixel within [PictureEdit.tolerance] of the
/// background is gone, and one within the softness beyond that is partly so.
void removeBackground(RgbaPicture p, PictureEdit edit) {
  if (edit.background == BackgroundRemoval.none) return;
  final (kr, kg, kb) = edit.backgroundColor != null
      ? ((edit.backgroundColor! >> 16) & 0xFF, (edit.backgroundColor! >> 8) & 0xFF, edit.backgroundColor! & 0xFF)
      : edgeColour(p);
  const longest = 441.6729559300637; // the distance between black and white
  final tol = edit.tolerance, soft = math.max(edit.softness, 1e-6);
  final data = p.rgba;
  double distance(int i) {
    final dr = data[i] - kr, dg = data[i + 1] - kg, db = data[i + 2] - kb;
    return math.sqrt((dr * dr + dg * dg + db * db).toDouble()) / longest;
  }

  /// How much of the pixel stays, for its distance from the background colour.
  int keep(double d) => d <= tol ? 0 : (d >= tol + soft ? 255 : ((d - tol) / soft * 255).round());

  if (edit.background == BackgroundRemoval.everywhere) {
    for (var i = 0; i < data.length; i += 4) {
      final a = keep(distance(i));
      data[i + 3] = math.min(data[i + 3], a);
    }
    return;
  }

  // from the edges: every pixel that touches the background, and is close to its colour, is background too
  final w = p.width, h = p.height;
  final reach = tol + soft;
  final seen = Uint8List(w * h);
  final stack = <int>[];
  void push(int x, int y) {
    final at = y * w + x;
    if (seen[at] == 1) return;
    if (distance(at * 4) >= reach) return;
    seen[at] = 1;
    stack.add(at);
  }

  for (var x = 0; x < w; x++) {
    push(x, 0);
    push(x, h - 1);
  }
  for (var y = 1; y < h - 1; y++) {
    push(0, y);
    push(w - 1, y);
  }
  while (stack.isNotEmpty) {
    final at = stack.removeLast();
    final x = at % w, y = at ~/ w;
    if (x > 0) push(x - 1, y);
    if (x < w - 1) push(x + 1, y);
    if (y > 0) push(x, y - 1);
    if (y < h - 1) push(x, y + 1);
  }
  for (var at = 0; at < w * h; at++) {
    if (seen[at] == 1) data[at * 4 + 3] = math.min(data[at * 4 + 3], keep(distance(at * 4)));
  }
}

/// The longest side a picture is worked on at: a photo of many megapixels is made smaller first (what is shown on a page is never
/// near that large, and it must fit in memory).
const int pictureEditLongestSide = 4096;

/// Decodes PNG, JPEG or another picture format (turned upright by its EXIF orientation), and makes it at most [maxSide] on the
/// longest side. Null if the bytes are not a picture.
RgbaPicture? decodePicture(Uint8List bytes, {int maxSide = pictureEditLongestSide}) {
  img.Image? image;
  try {
    image = img.decodeImage(bytes); // (a file that is cut off or not a picture can make the decoder fail instead of answering null)
  } catch (_) {
    return null;
  }
  if (image == null) return null;
  image = img.bakeOrientation(image);
  if (image.width > maxSide || image.height > maxSide) {
    image = image.width >= image.height ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average) : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
  }
  final rgba = image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
  return RgbaPicture(image.width, image.height, Uint8List.fromList(rgba));
}

/// [p] as a PNG, or as a JPEG ([jpeg]) when nothing in it is see-through.
Uint8List encodePicture(RgbaPicture p, {bool jpeg = false}) {
  final image = img.Image.fromBytes(width: p.width, height: p.height, bytes: Uint8List.fromList(p.rgba).buffer, numChannels: 4, order: img.ChannelOrder.rgba);
  return jpeg && !p.hasTransparency ? img.encodeJpg(image, quality: 92) : img.encodePng(image);
}

/// What [edit] makes of the picture in [bytes], as PNG or (a JPEG that stays one) JPEG bytes with its size in pixels; null if the
/// bytes are not a picture. [subject] is what the model said of the picture, for finding its subject. A top-level function with
/// plain arguments, so that it can run in an isolate.
({Uint8List bytes, int width, int height})? editPictureBytes((Uint8List, PictureEdit, bool, int, SubjectMatte?) args) {
  final (bytes, edit, jpeg, maxSide, subject) = args;
  final picture = decodePicture(bytes, maxSide: maxSide);
  if (picture == null) return null;
  final done = applyPictureEdit(picture, edit, subject: subject);
  return (bytes: encodePicture(done, jpeg: jpeg && !edit.transparent), width: done.width, height: done.height);
}

/// [applyPictureEdit] as a function with one argument, for an isolate.
RgbaPicture renderPicture((RgbaPicture, PictureEdit, SubjectMatte?) args) => applyPictureEdit(args.$1, args.$2, subject: args.$3);

/// The [count] colours that most stand out in [p], as `(r, g, b)`, the commonest first: the picture's colours are sorted into boxes
/// of 16 levels of each, and the fullest boxes are taken one after the other, each only if it differs from those taken already by at
/// least [apart] (so that five shades of one blue do not fill the palette). The colour of a box is the average of what is in it. See-
/// through pixels count for nothing. A picture of one colour gives that one.
List<(int, int, int)> dominantColours(RgbaPicture p, {int count = 6, int apart = 56}) {
  final sums = <int, List<int>>{}; // box -> [pixels, r, g, b]
  final step = math.max(1, (p.width * p.height) ~/ 40000); // (a sample is enough)
  for (var i = 0, n = 0; i < p.rgba.length; i += 4, n++) {
    if (n % step != 0 || p.rgba[i + 3] < 128) continue;
    final r = p.rgba[i], g = p.rgba[i + 1], b = p.rgba[i + 2];
    final box = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
    final entry = sums.putIfAbsent(box, () => [0, 0, 0, 0]);
    entry[0]++;
    entry[1] += r;
    entry[2] += g;
    entry[3] += b;
  }
  final boxes = sums.values.toList()..sort((a, b) => b[0].compareTo(a[0]));
  final out = <(int, int, int)>[];
  for (final e in boxes) {
    if (out.length >= count) break;
    final c = (e[1] ~/ e[0], e[2] ~/ e[0], e[3] ~/ e[0]);
    final far = out.every((o) {
      final dr = o.$1 - c.$1, dg = o.$2 - c.$2, db = o.$3 - c.$3;
      return math.sqrt((dr * dr + dg * dg + db * db).toDouble()) >= apart;
    });
    if (far) out.add(c);
  }
  return out;
}

/// [dominantColours] of the picture in [bytes] (made small first), for an isolate; empty if the bytes are not a picture.
List<(int, int, int)> dominantColoursOf(Uint8List bytes) {
  final picture = decodePicture(bytes, maxSide: 160);
  return picture == null ? const [] : dominantColours(picture);
}
