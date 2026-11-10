import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import 'markdown_parser.dart';

/// A formula drawn as a picture, for the PDF export. [width] and [height] are
/// in the same units as the page (the picture itself is sharper than that).
class MathImage {
  final Uint8List png;
  final double width, height;

  const MathImage(this.png, this.width, this.height);
}

/// Formulas drawn to pictures beforehand, by their LaTeX and whether they stand alone, for places that cannot typeset LaTeX (the PDF).
class MathImages {
  final Map<String, MathImage> _images;

  const MathImages([this._images = const {}]);

  static const empty = MathImages();

  static String _key(String tex, bool display) => '${display ? 'D' : 'I'}:$tex';

  MathImage? of(String tex, {bool display = false}) => _images[_key(tex, display)];

  bool get isEmpty => _images.isEmpty;
}

/// The formulas written in [sources] (Markdown), as (LaTeX, shown on its own line).
Set<(String, bool)> mathIn(Iterable<String> sources) => {
      for (final source in sources)
        for (final block in parseMarkdown(source))
          for (final run in [...block.runs, for (final r in block.rows) for (final c in r) ...c])
            if (run.math) (run.text, block.type == MdBlockType.math),
    };

/// Draws each of [formulas] in [color] (black) at [fontSize] and returns the pictures.
/// A formula that cannot be read has no picture. Needs the app on screen: the
/// formulas are laid out in an overlay, out of sight.
Future<MathImages> renderMathImages(
  BuildContext context,
  Iterable<(String, bool)> formulas, {
  required double fontSize,
  double pixelRatio = 4,
  Color color = Colors.black,
}) async {
  final todo = [
    for (final f in formulas)
      if (Math.tex(f.$1).parseError == null) f,
  ];
  if (todo.isEmpty) return MathImages.empty;

  final keys = [for (var i = 0; i < todo.length; i++) GlobalKey()];
  final style = TextStyle(fontSize: fontSize, color: color);
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -100000, // far off screen; it is still painted into its own layer
      top: 0,
      child: Material(
        type: MaterialType.transparency,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < todo.length; i++)
            RepaintBoundary(
              key: keys[i],
              child: Math.tex(todo[i].$1, textStyle: style, mathStyle: todo[i].$2 ? MathStyle.display : MathStyle.text),
            ),
        ]),
      ),
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  try {
    await WidgetsBinding.instance.endOfFrame;
    final images = <String, MathImage>{};
    for (var i = 0; i < todo.length; i++) {
      final boundary = keys[i].currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || !boundary.hasSize || boundary.size.isEmpty) continue;
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png == null) continue;
      images[MathImages._key(todo[i].$1, todo[i].$2)] =
          MathImage(png.buffer.asUint8List(), boundary.size.width, boundary.size.height);
    }
    return MathImages(images);
  } finally {
    entry.remove();
  }
}
