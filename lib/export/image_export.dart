import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The sizes a page can be exported as a picture in.
enum ImagePreset {
  web('Web', 'Light, for a message or a web page: 1000 pixels across', width: 1000),
  screen('Screen', 'Sharp on a screen: 1600 pixels across', width: 1600),
  print('Print', 'For paper: 300 dots per inch at the size of the page', dpi: 300),
  square('Square', 'A post: 1080 × 1080 pixels, the page in the middle', fitted: ui.Size(1080, 1080)),
  slide('Slide', 'A slide or a video: 1920 × 1080 pixels, the page in the middle', fitted: ui.Size(1920, 1080)),
  tall('Tall', 'A story or a phone screen: 1080 × 1920 pixels, the page in the middle', fitted: ui.Size(1080, 1920));

  final String label;

  /// What the choice means, as a sentence.
  final String hint;

  /// How many pixels across the picture is (0: not set by that).
  final int width;

  /// How many dots per inch the page has (0: not set by that).
  final int dpi;

  /// The size of the picture when it is a fixed one that the page is fitted into (null: the picture is as big as the page).
  final ui.Size? fitted;

  const ImagePreset(this.label, this.hint, {this.width = 0, this.dpi = 0, this.fitted});
}

/// How a page becomes a picture: how many pixels it has and where the page lies in it.
class ImagePlan {
  /// The size of the picture in pixels.
  final int width, height;

  /// Where the page lies in the picture, in pixels (all of it, except in the fixed sizes, which leave room around it).
  final ui.Rect page;

  /// How many pixels a unit of the page is.
  final double scale;

  const ImagePlan(this.width, this.height, this.page, this.scale);

  @override
  String toString() => '$width × $height';
}

/// The most pixels a picture has: more is too much for a phone to make.
const maxImagePixels = 16e6;

/// How a page [size] (in the units of the editor's page space, in which a sheet of A4 is 800 across) is made into a picture of
/// [preset]. A picture that would have more than [maxPixels] is made smaller, with the same shape.
ImagePlan planImage(ImagePreset preset, ui.Size size, {double maxPixels = maxImagePixels}) {
  final fixed = preset.fitted;
  if (fixed != null) {
    final scale = math.min(fixed.width / size.width, fixed.height / size.height);
    final w = size.width * scale, h = size.height * scale;
    return ImagePlan(
      fixed.width.round(),
      fixed.height.round(),
      ui.Rect.fromLTWH((fixed.width - w) / 2, (fixed.height - h) / 2, w, h),
      scale,
    );
  }
  var across = preset.width.toDouble();
  if (preset.dpi > 0) {
    // (an A4 sheet, 210 millimetres, is 800 units across)
    final inches = size.width / 800 * 210 / 25.4;
    across = (inches * preset.dpi).roundToDouble();
  }
  var scale = across / size.width;
  final pixels = size.width * scale * size.height * scale;
  final tooMany = pixels > maxPixels;
  if (tooMany) scale *= math.sqrt(maxPixels / pixels);
  // (rounded down when it was made smaller, so that it is not a few pixels over after all)
  final w = math.max(1, tooMany ? (size.width * scale).floor() : (size.width * scale).round());
  final h = math.max(1, tooMany ? (size.height * scale).floor() : (size.height * scale).round());
  return ImagePlan(w, h, ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), scale);
}

/// A PNG of what [paintPage] draws, in the units of the page: the canvas is moved and scaled so that the page lies where [plan] says.
/// What is round the page (in a fixed size) is [around], or see-through if that is null.
Future<Uint8List> drawImage(ImagePlan plan, void Function(ui.Canvas canvas) paintPage, {ui.Color? around}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  if (around != null) canvas.drawRect(ui.Rect.fromLTWH(0, 0, plan.width.toDouble(), plan.height.toDouble()), ui.Paint()..color = around);
  canvas.save();
  canvas.clipRect(plan.page);
  canvas.translate(plan.page.left, plan.page.top);
  canvas.scale(plan.scale);
  paintPage(canvas);
  canvas.restore();
  final picture = recorder.endRecording();
  final image = await picture.toImage(plan.width, plan.height);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('the picture could not be written');
    return bytes.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// A name for a file made from [title]: no characters a file system does not take.
String fileNameOf(String title, [String fallback = 'Note']) {
  final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-').trim().replaceAll(RegExp(r'\s+'), ' ');
  final trimmed = cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
  return trimmed.isEmpty || trimmed == '.' || trimmed == '..' ? fallback : trimmed;
}
