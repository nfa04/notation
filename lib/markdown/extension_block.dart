import 'package:flutter/material.dart' hide Text;

import '../extensions/draw_result.dart' show colorFromHex;
import '../extensions/extension_service.dart' show BlockDrawing;
import '../l10n/text.dart';

/// Where the written document learns which languages of fenced code blocks an extension draws (a block of chess, of music...), and
/// how to ask it. The app fills it in from the extensions that are on; without it every block is plain code.
class ExtensionBlocks {
  /// The languages some extension draws, in lower case.
  static Set<String> languages = {};

  /// Draws the block [code] of [language] in a box [width] wide; throws a sentence for the person when it cannot.
  static Future<BlockDrawing> Function(String language, String code, double width)? draw;

  static bool handles(String language) => draw != null && languages.contains(language.toLowerCase());
}

/// What an extension drew for a block: lines and texts in a box that is scaled to the width there is. While the extension works a
/// thin placeholder is shown; when it fails the reason is shown (the source of the block is one tap away: the caret in it shows the
/// code again).
class ExtensionBlockView extends StatefulWidget {
  final String language, code;
  final double width, fontSize;
  final Color textColor;
  const ExtensionBlockView({super.key, required this.language, required this.code, required this.width, required this.fontSize, required this.textColor});

  @override
  State<ExtensionBlockView> createState() => _ExtensionBlockViewState();
}

class _ExtensionBlockViewState extends State<ExtensionBlockView> {
  Future<BlockDrawing>? _drawing;
  (String, String, double)? _for;

  void _ask() {
    final key = (widget.language, widget.code, widget.width.roundToDouble());
    if (_for == key) return;
    _for = key;
    final draw = ExtensionBlocks.draw;
    _drawing = draw == null ? Future.error('No extension draws this.') : draw(widget.language.toLowerCase(), widget.code, widget.width);
  }

  @override
  Widget build(BuildContext context) {
    _ask();
    return FutureBuilder<BlockDrawing>(
      future: _drawing,
      builder: (context, snapshot) {
        final pad = widget.fontSize * 0.3;
        if (snapshot.hasError) {
          return Container(
            key: const ValueKey('extension-block-error'),
            width: double.infinity,
            margin: EdgeInsets.symmetric(vertical: pad),
            padding: EdgeInsets.all(widget.fontSize * 0.6),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(6)),
            child: Text.verbatim('${widget.language}: ${snapshot.error}', style: TextStyle(fontSize: widget.fontSize * 0.85, color: widget.textColor)),
          );
        }
        final drawing = snapshot.data;
        if (drawing == null) return SizedBox(key: const ValueKey('extension-block-waiting'), width: double.infinity, height: widget.fontSize * 2.4);
        final scale = (widget.width / drawing.width).clamp(0.05, 1.0);
        return Padding(
          padding: EdgeInsets.symmetric(vertical: pad),
          child: CustomPaint(
            key: const ValueKey('extension-block'),
            size: Size(drawing.width * scale, drawing.height * scale),
            painter: BlockPainter(drawing, scale, widget.textColor),
          ),
        );
      },
    );
  }
}

/// Paints what a block's extension drew: its lines (with their colours, widths and dashes) and its texts.
class BlockPainter extends CustomPainter {
  final BlockDrawing drawing;
  final double scale;
  final Color defaultColor;
  BlockPainter(this.drawing, this.scale, this.defaultColor);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    for (final s in drawing.strokes) {
      final points = [for (final p in (s['points'] as List)) Offset((p[0] as num).toDouble() * scale, (p[1] as num).toDouble() * scale)];
      if (points.length < 2) continue;
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      final fill = colorFromHex(s['fill']);
      if (fill != null) canvas.drawPath(path, Paint()..color = fill..style = PaintingStyle.fill);
      final paint = Paint()
        ..color = colorFromHex(s['color']) ?? defaultColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = ((s['width'] as num?)?.toDouble() ?? 1.5) * scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final dash = s['dash'];
      if (dash == 'dashed' || dash == 'dotted') {
        final on = dash == 'dashed' ? 8.0 * scale : 1.5 * scale, off = dash == 'dashed' ? 5.0 * scale : 4.0 * scale;
        for (final m in path.computeMetrics()) {
          for (var d = 0.0; d < m.length; d += on + off) {
            canvas.drawPath(m.extractPath(d, (d + on).clamp(0, m.length)), paint);
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }
    }
    for (final t in drawing.texts) {
      final painter = TextPainter(
        text: TextSpan(text: t['text'] as String, style: TextStyle(fontSize: ((t['size'] as num?)?.toDouble() ?? 14) * scale, color: colorFromHex(t['color']) ?? defaultColor)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      painter.paint(canvas, Offset((t['x'] as num).toDouble() * scale, (t['y'] as num).toDouble() * scale));
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(BlockPainter old) => old.drawing != drawing || old.scale != scale || old.defaultColor != defaultColor;
}
