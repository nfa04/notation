import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A ruler across the top of the page with a handle at each end of the text
/// area, to drag the left and right margins. Values are in page units
/// ([pageWidth] wide); the ruler itself may be drawn narrower.
class MarginRuler extends StatelessWidget {
  final double pageWidth;
  final double left;
  final double right;
  final void Function(double left, double right) onChanged;

  static const double minMargin = 16;
  static const double minText = 200;
  static const double height = 22;
  static const double _grip = 22;

  const MarginRuler({
    super.key,
    required this.pageWidth,
    required this.left,
    required this.right,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final scale = box.maxWidth / pageWidth; // screen pixels per page unit
      final leftX = left * scale;
      final rightX = (pageWidth - right) * scale;

      Widget handle(Key key, double x, void Function(double dx) drag, {required bool isLeft}) => Positioned(
            left: x - _grip / 2,
            top: 0,
            width: _grip,
            height: height,
            child: GestureDetector(
              key: key,
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) => drag(d.delta.dx / scale),
              child: CustomPaint(painter: _HandlePainter(scheme.primary, pointsRight: isLeft)),
            ),
          );

      return SizedBox(
        height: height,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: CustomPaint(painter: _RulerPainter(scale, left, right, pageWidth, scheme)),
          ),
          handle(const ValueKey('margin-left'), leftX,
              (dx) => onChanged(left + dx < minMargin ? minMargin : math.min(left + dx, pageWidth - right - minText), right),
              isLeft: true),
          handle(const ValueKey('margin-right'), rightX,
              (dx) => onChanged(left, right - dx < minMargin ? minMargin : math.min(right - dx, pageWidth - left - minText)),
              isLeft: false),
        ]),
      );
    });
  }
}

class _RulerPainter extends CustomPainter {
  final double scale, left, right, pageWidth;
  final ColorScheme scheme;

  _RulerPainter(this.scale, this.left, this.right, this.pageWidth, this.scheme);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = scheme.surfaceContainerHighest);
    // the text area is the lighter part
    canvas.drawRect(
      Rect.fromLTRB(left * scale, 3, (pageWidth - right) * scale, size.height - 3),
      Paint()..color = scheme.surface,
    );
    final tick = Paint()
      ..color = scheme.outline
      ..strokeWidth = 1;
    for (var x = 0.0; x <= pageWidth; x += 20) {
      final major = x % 100 == 0;
      canvas.drawLine(Offset(x * scale, size.height - 3), Offset(x * scale, size.height - (major ? 9 : 6)), tick);
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.scale != scale || old.left != left || old.right != right || old.scheme != scheme;
}

class _HandlePainter extends CustomPainter {
  final Color color;
  final bool pointsRight;

  _HandlePainter(this.color, {required this.pointsRight});

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final paint = Paint()..color = color;
    canvas.drawLine(Offset(x, 2), Offset(x, size.height - 2), paint..strokeWidth = 2);
    final tri = Path()
      ..moveTo(x, 2)
      ..lineTo(pointsRight ? x + 7 : x - 7, 7)
      ..lineTo(x, 12)
      ..close();
    canvas.drawPath(tri, paint..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _HandlePainter old) => old.color != color || old.pointsRight != pointsRight;
}

/// The same ruler down the side of a page, to drag the top and bottom margins. It is as high on the screen as the page is (the caller
/// gives it that height), so a tick is where the same place of the page is and a drag moves a margin by what it moved on the page.
/// [pageHeight] is the height of the page in page units.
class VerticalMarginRuler extends StatelessWidget {
  final double pageHeight;
  final double top;
  final double bottom;
  final void Function(double top, double bottom) onChanged;

  static const double width = MarginRuler.height;

  const VerticalMarginRuler({super.key, required this.pageHeight, required this.top, required this.bottom, required this.onChanged});

  /// The top margin for a wanted [value]: not less than the least margin, and the text area keeps its least height.
  static double clampTop(double value, double bottom, double pageHeight) =>
      value < MarginRuler.minMargin ? MarginRuler.minMargin : math.min(value, pageHeight - bottom - MarginRuler.minText);

  static double clampBottom(double value, double top, double pageHeight) =>
      value < MarginRuler.minMargin ? MarginRuler.minMargin : math.min(value, pageHeight - top - MarginRuler.minText);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const grip = MarginRuler._grip;
    return LayoutBuilder(builder: (context, box) {
      final scale = box.maxHeight / pageHeight; // screen pixels per page unit

      Widget handle(Key key, double y, void Function(double dy) drag, {required bool isTop}) => Positioned(
            top: y - grip / 2,
            left: 0,
            width: width,
            height: grip,
            child: GestureDetector(
              key: key,
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) => drag(d.delta.dy / scale),
              child: CustomPaint(painter: _VerticalHandlePainter(scheme.primary, pointsDown: isTop)),
            ),
          );

      return SizedBox(
        width: width,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(child: CustomPaint(painter: _VerticalRulerPainter(scale, top, bottom, pageHeight, scheme))),
          handle(const ValueKey('margin-top'), top * scale, (dy) => onChanged(clampTop(top + dy, bottom, pageHeight), bottom), isTop: true),
          handle(const ValueKey('margin-bottom'), (pageHeight - bottom) * scale, (dy) => onChanged(top, clampBottom(bottom - dy, top, pageHeight)), isTop: false),
        ]),
      );
    });
  }
}

class _VerticalRulerPainter extends CustomPainter {
  final double scale, top, bottom, pageHeight;
  final ColorScheme scheme;

  _VerticalRulerPainter(this.scale, this.top, this.bottom, this.pageHeight, this.scheme);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = scheme.surfaceContainerHighest);
    // the text area is the lighter part
    canvas.drawRect(
      Rect.fromLTRB(3, top * scale, size.width - 3, (pageHeight - bottom) * scale),
      Paint()..color = scheme.surface,
    );
    final tick = Paint()
      ..color = scheme.outline
      ..strokeWidth = 1;
    for (var y = 0.0; y <= pageHeight; y += 20) {
      final major = y % 100 == 0;
      canvas.drawLine(Offset(size.width - 3, y * scale), Offset(size.width - (major ? 9 : 6), y * scale), tick);
    }
  }

  @override
  bool shouldRepaint(covariant _VerticalRulerPainter old) =>
      old.scale != scale || old.top != top || old.bottom != bottom || old.pageHeight != pageHeight || old.scheme != scheme;
}

class _VerticalHandlePainter extends CustomPainter {
  final Color color;
  final bool pointsDown;

  _VerticalHandlePainter(this.color, {required this.pointsDown});

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final paint = Paint()..color = color;
    canvas.drawLine(Offset(2, y), Offset(size.width - 2, y), paint..strokeWidth = 2);
    final tri = Path()
      ..moveTo(2, y)
      ..lineTo(7, pointsDown ? y + 7 : y - 7)
      ..lineTo(12, y)
      ..close();
    canvas.drawPath(tri, paint..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _VerticalHandlePainter old) => old.color != color || old.pointsDown != pointsDown;
}
