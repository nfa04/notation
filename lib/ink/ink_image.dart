import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/canvas_models.dart';
import 'glm_ocr.dart';
import 'ink_grouping.dart';
import 'onnx_paddle_vl.dart';
import 'paddle_vl.dart';
import 'math_decoder.dart' show formulaImageSize;

/// Draws [strokes] as black ink on white, stretched over the whole
/// [formulaImageSize] square the way the model's training pictures of text lines
/// were (they were squeezed into the square without keeping their proportions),
/// and returns the pixels as floats 0..1, three per pixel.
Future<Float32List> renderInkForModel(List<DrawingStroke> strokes, {double penWidth = 4.5}) async {
  final drawn = [for (final s in strokes) if (s.points.length >= 2) s];
  var bounds = strokeBounds(drawn.first);
  for (final s in drawn.skip(1)) {
    bounds = bounds.expandToInclude(strokeBounds(s));
  }
  // some white around the writing, like the margin of a scanned line
  final margin = 0.06 * (bounds.width > bounds.height ? bounds.width : bounds.height) + 2;
  final area = bounds.inflate(margin);
  final sx = formulaImageSize / area.width;
  final sy = formulaImageSize / area.height;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, formulaImageSize.toDouble(), formulaImageSize.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final pen = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    ..strokeWidth = penWidth;
  for (final s in drawn) {
    final path = ui.Path();
    for (var i = 0; i < s.points.length; i++) {
      final p = ui.Offset((s.points[i].dx - area.left) * sx, (s.points[i].dy - area.top) * sy);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, pen);
  }
  final image = await recorder.endRecording().toImage(formulaImageSize, formulaImageSize);
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();

  final out = Float32List(formulaImageSize * formulaImageSize * 3);
  for (var i = 0; i < formulaImageSize * formulaImageSize; i++) {
    out[3 * i] = rgba.getUint8(4 * i) / 255;
    out[3 * i + 1] = rgba.getUint8(4 * i + 1) / 255;
    out[3 * i + 2] = rgba.getUint8(4 * i + 2) / 255;
  }
  return out;
}

/// The size of the picture TexTeller reads, and the numbers it was trained with (gray, mean and spread of the pixels).
const int texTellerImageSize = 448;
const double _texTellerMean = 0.9545467;
const double _texTellerSpread = 0.15394445;

/// How thick the pen is in the picture TexTeller gets, as a part of the height of a letter.
///
/// Much thinner than the pen on the page: TexTeller learned from printed formulas, whose lines are about a pixel wide, and it
/// reads a pen drawn that thin far better (76 % of the test formulas right against 25 % with a pen a seventh of a letter
/// thick). Only this picture is drawn so; what the person sees is not changed.
const double texTellerPen = 0.02;

/// The picture of [strokes] for TexTeller: the ink at the size that fits 448 x 448 with its proportions kept (not squeezed, as
/// the other formula reader wants), drawn as a thin line, gray and normalised, in the top left corner of a 448 x 448 square
/// (the rest is zero, as TexTeller pads its pictures). [penScale] scales the thin pen (for tests; 1 is as tuned).
Future<Float32List> renderInkForTexTeller(List<DrawingStroke> strokes, {double penScale = 1}) async {
  final drawn = [for (final s in strokes) if (s.points.length >= 2) s];
  var bounds = strokeBounds(drawn.first);
  for (final s in drawn.skip(1)) {
    bounds = bounds.expandToInclude(strokeBounds(s));
  }
  const margin = 2;
  final w = bounds.width < 1e-6 ? 1e-6 : bounds.width;
  final h = bounds.height < 1e-6 ? 1e-6 : bounds.height;
  final scale = math.min((texTellerImageSize - 2 * margin) / w, (texTellerImageSize - 2 * margin) / h);
  final width = math.min((w * scale).ceil() + 2 * margin, texTellerImageSize);
  final height = math.min((h * scale).ceil() + 2 * margin, texTellerImageSize);

  // the pen follows the size of the writing: a part of the height of a letter (the tall strokes tell it)
  final heights = [for (final s in drawn) strokeBounds(s).height]..sort();
  final letter = math.max(heights[(heights.length * 0.8).floor().clamp(0, heights.length - 1)], 1e-6);
  final pen = math.max(0.6, texTellerPen * penScale * letter * scale);

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  final paint = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    ..isAntiAlias = true
    ..strokeWidth = pen;
  for (final s in drawn) {
    final path = ui.Path();
    for (var i = 0; i < s.points.length; i++) {
      final p = ui.Offset((s.points[i].dx - bounds.left) * scale + margin, (s.points[i].dy - bounds.top) * scale + margin);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }
  final image = await recorder.endRecording().toImage(width, height);
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();

  final out = Float32List(texTellerImageSize * texTellerImageSize);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      out[y * texTellerImageSize + x] = (rgba.getUint8(4 * (y * width + x)) / 255 - _texTellerMean) / _texTellerSpread;
    }
  }
  return out;
}

/// The picture of one line of writing for PaddleOCR-VL: black ink on white, 112 pixels high with the proportions kept (the ink with
/// an eighth of white above and below), as wide as the line needs (a multiple of 28, at least 1008 pixels; a line too long for the
/// model is made smaller), cut into patches.
Future<PaddleVlPicture> renderInkForPaddleVl(List<DrawingStroke> strokes,) async {
  final drawn = [for (final s in strokes) if (s.points.length >= 2) s];
  if (drawn.isEmpty) throw ArgumentError('Nothing is drawn.');
  var bounds = strokeBounds(drawn.first);
  for (final s in drawn.skip(1)) {
    bounds = bounds.expandToInclude(strokeBounds(s));
  }
  const margin = paddleVlHeight / 8;
  final inkWidth = math.max(bounds.width, 1.0),
      inkHeight = math.max(bounds.height, 1.0);
  var scale = (paddleVlHeight - 2 * margin) / inkHeight;
  scale = math.min(scale, (paddleVlMaxWidth - 2 * margin) / inkWidth);
  final width = math.min (
    paddleVlMaxWidth,
    math.max(
      paddleVlMinWidth,
      ((inkWidth * scale + 2 * margin) / 28).ceil() * 28,
    ),
  );
  // a line that is flatter than the picture sits in the middle of its height
  final top = (paddleVlHeight - inkHeight * scale) / 2;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), paddleVlHeight.toDouble()), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  final pen = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    ..strokeWidth = 4;
  for (final s in drawn) {
    final path = ui.Path();
    for (var i = 0; i < s.points.length; i++) {
      final p = ui.Offset((s.points[i].dx - bounds.left) * scale + margin, (s.points[i].dy - bounds.top) * scale + top);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, pen);
  }
  final image = await recorder.endRecording().toImage(width, paddleVlHeight);
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  return PaddleVlPicture(
    paddleVlPatches(rgba.buffer.asUint8List(), width, paddleVlHeight),
    paddleVlHeight ~/ paddleVlPatch,
    width ~/ paddleVlPatch,
  );
}

/// How thick the pen is in the picture GLM-OCR gets, as a part of the height of the ink (what the benchmark was drawn with).
const double glmOcrPen = 0.045;

/// The picture of one line of writing for GLM-OCR: black ink on white, [rows] patches of 14 pixels high with the ink in the middle of
/// it (a seventh of white above and below), proportions kept, as wide as the line needs (a multiple of 28, at least what the model's
/// smallest picture has in pixels; a line too long for the model is made smaller), cut into patches. Fewer rows are quicker and a
/// little less exact (the vision network's work grows with the square of them): 10 is the standard, 8 the quick choice.
Future<GlmPicture> renderInkForGlmOcr(List<DrawingStroke> strokes, {int rows = 10}) async {
  final drawn = [for (final s in strokes) if (s.points.length >= 2) s];
  if (drawn.isEmpty) throw ArgumentError('Nothing is drawn.');
  rows = (rows ~/ 2 * 2).clamp(4, 16);
  var bounds = strokeBounds(drawn.first);
  for (final s in drawn.skip(1)) {
    bounds = bounds.expandToInclude(strokeBounds(s));
  }
  final height = rows * glmPatch;
  final margin = height / 7; // (white above and below: the ink is five sevenths of the picture)
  final inkHeight = height - 2 * margin;
  final inkWidth = math.max(bounds.width, 1.0), inkTall = math.max(bounds.height, 1.0);
  var scale = inkHeight / inkTall;
  scale = math.min(scale, (glmMaxPatchesPerSide * glmPatch - 2 * margin) / inkWidth);
  final minWidth = (glmMinPixels / height / 28).ceil() * 28;
  final width = math.max(minWidth, ((inkWidth * scale + 2 * margin) / 28).ceil() * 28);
  // a line that is flatter than the picture sits in the middle of its height
  final top = (height - inkTall * scale) / 2;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  final pen = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    ..isAntiAlias = true
    ..strokeWidth = math.max(1.0, glmOcrPen * inkHeight);
  for (final s in drawn) {
    final path = ui.Path();
    for (var i = 0; i < s.points.length; i++) {
      final p = ui.Offset((s.points[i].dx - bounds.left) * scale + margin, (s.points[i].dy - bounds.top) * scale + top);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, pen);
  }
  final image = await recorder.endRecording().toImage(width, height);
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  return GlmPicture(glmPatches(rgba.buffer.asUint8List(), width, height), height ~/ glmPatch, width ~/ glmPatch);
}
