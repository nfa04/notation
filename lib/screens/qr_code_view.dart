import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Shows [data] as a QR code (black on white, with the quiet border scanners need), [size] logical pixels wide.
class QrCodeView extends StatelessWidget {
  final String data;
  final double size;

  const QrCodeView({super.key, required this.data, this.size = 220});

  @override
  Widget build(BuildContext context) {
    final code = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
    return Semantics(
      label: 'QR code',
      image: true,
      child: SizedBox(width: size, height: size, child: CustomPaint(painter: _QrPainter(QrImage(code)))),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrImage image;

  _QrPainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    const quiet = 2; // modules of white around the code
    final count = image.moduleCount;
    final cell = size.width / (count + 2 * quiet);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final dark = Paint()..color = Colors.black;
    for (var y = 0; y < count; y++) {
      for (var x = 0; x < count; x++) {
        if (image.isDark(y, x)) {
          canvas.drawRect(Rect.fromLTWH((x + quiet) * cell, (y + quiet) * cell, cell + 0.5, cell + 0.5), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
