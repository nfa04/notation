import 'package:flutter/material.dart';

import '../style/app_theme.dart';

/// The Notation logo: a pen that writes its own N. The left stem and the diagonal are the ink, the right stem is the
/// pen, and its amber tip is where the diagonal ends.
///
/// The tile takes the accent the person chose (the default accent gives exactly the picture of the app icon, in the dark
/// theme too: the colours of the theme itself are lighter or darker tones of it), the amber tip stays amber. The geometry is the one of branding/make_icons.py, which makes the icon files: change one, change both.
class NotationLogo extends StatelessWidget {
  const NotationLogo({super.key, this.size = 40, this.color});

  final double size;

  /// The colour of the tile; the accent of the app when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Notation',
      image: true,
      child: ExcludeSemantics(
        child: CustomPaint(size: Size.square(size), painter: NotationLogoPainter(color ?? Theme.of(context).extension<BrandAccent>()?.color ?? AppTheme.defaultAccent)),
      ),
    );
  }
}

class NotationLogoPainter extends CustomPainter {
  const NotationLogoPainter(this.color);

  final Color color;

  static const amber = Color(0xFFFFD54A);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 1024;
    canvas.save();
    canvas.scale(k);

    // the tile: the accent, a little lighter above and darker below (0xFF4285F4 gives 0xFF5B9BFF / 0xFF2F6FE0)
    final hsl = HSLColor.fromColor(color);
    final top = hsl.withLightness((hsl.lightness + 0.07).clamp(0.0, 1.0)).toColor();
    final bottom = hsl.withLightness((hsl.lightness - 0.07).clamp(0.0, 1.0)).toColor();
    const tile = Rect.fromLTWH(0, 0, 1024, 1024);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tile, const Radius.circular(230)),
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]).createShader(tile),
    );

    // the glyph, centred: translate(512 512) scale(1.12) translate(-495 -500)
    canvas.translate(512, 512);
    canvas.scale(1.12);
    canvas.translate(-495, -500);

    final white = Paint()..color = Colors.white;
    final ink = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 100
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(300, 760)
        ..lineTo(300, 280)
        ..lineTo(690, 590),
      ink,
    );
    canvas.drawPath(
      Path()
        ..moveTo(640, 240)
        ..arcToPoint(const Offset(740, 240), radius: const Radius.circular(50))
        ..lineTo(740, 600)
        ..lineTo(690, 810)
        ..lineTo(640, 600)
        ..close(),
      white,
    );
    // the band round the pen: the accent, mostly white (0xFF4285F4 gives 0xFFC7D9FB)
    canvas.drawRect(const Rect.fromLTWH(640, 300, 100, 40), Paint()..color = Color.lerp(Colors.white, color, 0.25)!);
    canvas.drawPath(
      Path()
        ..moveTo(640, 600)
        ..lineTo(690, 810)
        ..lineTo(740, 600)
        ..quadraticBezierTo(690, 625, 640, 600)
        ..close(),
      Paint()..color = amber,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(NotationLogoPainter old) => old.color != color;
}

/// The accent colour the person picked, as the theme carries it: [ColorScheme.primary] is a lighter or darker tone of it,
/// which is right for buttons but not for a logo.
class BrandAccent extends ThemeExtension<BrandAccent> {
  const BrandAccent(this.color);

  final Color color;

  @override
  BrandAccent copyWith({Color? color}) => BrandAccent(color ?? this.color);

  @override
  BrandAccent lerp(BrandAccent? other, double t) => BrandAccent(Color.lerp(color, other?.color, t)!);
}
