import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

/// The parts of reading printed text from a picture that need no model: getting the picture ready for the models and making
/// sense of what they answer. The models are PaddleOCR's (Apache 2.0): one finds the lines of text (DB, a map of how likely
/// each pixel is text), one reads a line (CRNN with CTC).

/// The most pixels a picture has along its long side when it goes to the detector.
const detectorSide = 960;

/// The height every line has when it goes to the reader.
const readerHeight = 48;

/// A picture ready for the detector: [data] is NCHW (blue, green, red), [width] and [height] multiples of 32.
class DetectorInput {
  final Float32List data;
  final int width, height;

  /// The size of the picture it was made from.
  final int sourceWidth, sourceHeight;
  const DetectorInput(this.data, this.width, this.height, this.sourceWidth, this.sourceHeight);
}

int _multipleOf32(double v) => math.max(32, (v / 32).round() * 32);

/// Makes [image] the size the detector takes and normalises it (the detector wants the channels as OpenCV has them, blue first).
DetectorInput prepareDetector(img.Image image, {int side = detectorSide}) {
  final src = image.convert(numChannels: 3);
  final ratio = math.min(1.0, side / math.max(src.width, src.height));
  final w = _multipleOf32(src.width * ratio), h = _multipleOf32(src.height * ratio);
  final small = img.copyResize(src, width: w, height: h, interpolation: img.Interpolation.linear);
  const mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225];
  final data = Float32List(3 * w * h);
  final plane = w * h;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      final i = y * w + x;
      data[i] = (p.b / 255 - mean[0]) / std[0];
      data[plane + i] = (p.g / 255 - mean[1]) / std[1];
      data[2 * plane + i] = (p.r / 255 - mean[2]) / std[2];
    }
  }
  return DetectorInput(data, w, h, src.width, src.height);
}

/// A line of text found in a picture, in the pixels of that picture.
class TextBox {
  final Rect rect;
  final double score;
  const TextBox(this.rect, this.score);
}

/// The lines of text in the probability map [map] ([width] x [height]) the detector made for a picture of [sourceWidth] x
/// [sourceHeight]: places where the map is above [threshold] and hang together, that are big enough and sure enough, widened
/// a little (the map marks a core smaller than the text), and taken back to the picture's own size.
List<TextBox> findTextBoxes(
  Float32List map,
  int width,
  int height,
  int sourceWidth,
  int sourceHeight, {
  double threshold = 0.3,
  double minScore = 0.6,
  double unclip = 1.5,
  int minSide = 3,
}) {
  final seen = Uint8List(width * height);
  final stack = <int>[];
  final boxes = <TextBox>[];
  final sx = sourceWidth / width, sy = sourceHeight / height;
  for (var start = 0; start < map.length; start++) {
    if (seen[start] != 0 || map[start] <= threshold) continue;
    var minX = width, minY = height, maxX = 0, maxY = 0, count = 0;
    var sum = 0.0;
    seen[start] = 1;
    stack.add(start);
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      final x = i % width, y = i ~/ width;
      count++;
      sum += map[i];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (final n in [if (x > 0) i - 1, if (x < width - 1) i + 1, if (y > 0) i - width, if (y < height - 1) i + width]) {
        if (seen[n] == 0 && map[n] > threshold) {
          seen[n] = 1;
          stack.add(n);
        }
      }
    }
    final w = (maxX - minX + 1).toDouble(), h = (maxY - minY + 1).toDouble();
    if (math.min(w, h) < minSide) continue;
    final score = sum / count;
    if (score < minScore) continue;
    // how far the core has to grow to cover the text: area x ratio / perimeter, as the model was trained
    final grow = w * h * unclip / (2 * (w + h));
    final r = Rect.fromLTRB(
      ((minX - grow) * sx).clamp(0, sourceWidth - 1).toDouble(),
      ((minY - grow) * sy).clamp(0, sourceHeight - 1).toDouble(),
      ((maxX + 1 + grow) * sx).clamp(1, sourceWidth).toDouble(),
      ((maxY + 1 + grow) * sy).clamp(1, sourceHeight).toDouble(),
    );
    boxes.add(TextBox(r, score));
  }
  return boxes;
}

/// The picture of one line, ready for the reader: [data] is NCHW (blue, green, red) [readerHeight] high.
class ReaderInput {
  final Float32List data;
  final int width;
  const ReaderInput(this.data, this.width);
}

/// Cuts [box] out of [image] and makes it what the reader takes. A line that is much taller than wide is turned.
ReaderInput prepareReader(img.Image image, Rect box, {int maxWidth = 2400}) {
  final x0 = box.left.floor().clamp(0, image.width - 1), y0 = box.top.floor().clamp(0, image.height - 1);
  final x1 = box.right.ceil().clamp(x0 + 1, image.width), y1 = box.bottom.ceil().clamp(y0 + 1, image.height);
  var crop = img.copyCrop(image.convert(numChannels: 3), x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  if (crop.height >= crop.width * 1.5) crop = img.copyRotate(crop, angle: 90);
  final w = (readerHeight * crop.width / crop.height).ceil().clamp(8, maxWidth);
  final small = img.copyResize(crop, width: w, height: readerHeight, interpolation: img.Interpolation.linear);
  final data = Float32List(3 * w * readerHeight);
  final plane = w * readerHeight;
  for (var y = 0; y < readerHeight; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      final i = y * w + x;
      data[i] = (p.b / 255 - 0.5) / 0.5;
      data[plane + i] = (p.g / 255 - 0.5) / 0.5;
      data[2 * plane + i] = (p.r / 255 - 0.5) / 0.5;
    }
  }
  return ReaderInput(data, w);
}

/// The characters the reader answers with: the blank of the CTC first, then the dictionary file's lines, then the space.
List<String> readerAlphabet(String dictionaryFile) {
  final lines = dictionaryFile.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return ['', for (final l in lines) l.replaceAll('\r', ''), ' '];
}

/// What a line says, from the reader's scores for each step ([steps] x [classes], row after row): the likeliest class of each
/// step, repeats joined, blanks dropped. [confidence] is the mean of the likelihoods of the steps that gave a character.
({String text, double confidence}) decodeCtc(List<double> scores, int steps, int classes, List<String> alphabet) {
  final out = StringBuffer();
  var previous = -1, kept = 0;
  var sum = 0.0;
  for (var t = 0; t < steps; t++) {
    var best = 0;
    var bestScore = double.negativeInfinity;
    for (var c = 0; c < classes; c++) {
      final v = scores[t * classes + c];
      if (v > bestScore) {
        bestScore = v;
        best = c;
      }
    }
    if (best != previous && best != 0 && best < alphabet.length) {
      out.write(alphabet[best]);
      sum += bestScore;
      kept++;
    }
    previous = best;
  }
  return (text: out.toString(), confidence: kept == 0 ? 0 : sum / kept);
}

/// One line as read.
class OcrLine {
  final String text;
  final Rect rect;
  final double confidence;
  const OcrLine(this.text, this.rect, this.confidence);
}

/// Everything read from a picture.
class OcrPage {
  final List<OcrLine> lines;
  final int width, height;
  const OcrPage(this.lines, this.width, this.height);

  bool get isEmpty => lines.every((l) => l.text.trim().isEmpty);

  /// The text in reading order: lines that sit side by side are joined with spaces, and a gap that is much taller than usual
  /// is a blank line.
  String get text => textOf(lines);
}

/// Puts [lines] in reading order, top to bottom and left to right, and joins them.
String textOf(List<OcrLine> lines) {
  final sorted = [...lines.where((l) => l.text.trim().isNotEmpty)]..sort((a, b) => a.rect.center.dy.compareTo(b.rect.center.dy));
  if (sorted.isEmpty) return '';
  final rows = <List<OcrLine>>[];
  for (final l in sorted) {
    if (rows.isNotEmpty) {
      final r = rows.last.first.rect;
      final overlap = math.min(r.bottom, l.rect.bottom) - math.max(r.top, l.rect.top);
      if (overlap > 0.5 * math.min(r.height, l.rect.height)) {
        rows.last.add(l);
        continue;
      }
    }
    rows.add([l]);
  }
  for (final r in rows) {
    r.sort((a, b) => a.rect.left.compareTo(b.rect.left));
  }
  final heights = [for (final r in rows) r.first.rect.height]..sort();
  final usual = heights[heights.length ~/ 2];
  final out = StringBuffer();
  for (var i = 0; i < rows.length; i++) {
    if (i > 0) {
      final gap = rows[i].first.rect.top - rows[i - 1].map((l) => l.rect.bottom).reduce(math.max);
      out.write(gap > usual * 0.9 ? '\n\n' : '\n');
    }
    out.write(rows[i].map((l) => l.text.trim()).join('  '));
  }
  return out.toString();
}
