import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;

import '../ai/flashcards.dart';
import '../data/card_repository.dart';
import '../l10n/text.dart';

/// The colour of the cover a card asks for, and of the others.
const askedCoverColor = Color(0xFFE8833A);
const otherCoverColor = Color(0xFF8E9AAF);

/// Draws the covers of [region] (front or back) on a picture [size] big.
void paintCovers(Canvas canvas, Size size, RegionCard region, {required bool front}) {
  for (final (r, asked, filled) in region.coversOn(front: front)) {
    final rect = Rect.fromLTWH(r[0] * size.width, r[1] * size.height, r[2] * size.width, r[3] * size.height);
    final rounded = RRect.fromRectAndRadius(rect, Radius.circular(size.shortestSide * 0.01 + 2));
    final color = asked ? askedCoverColor : otherCoverColor;
    if (filled) {
      canvas.drawRRect(rounded, Paint()..color = color);
      if (asked) {
        // a question mark in the middle of the cover asked for
        final mark = TextPainter(
          text: TextSpan(text: '?', style: TextStyle(color: Colors.white, fontSize: (rect.shortestSide * 0.6).clamp(10, 64), fontWeight: FontWeight.bold)),
          textDirection: TextDirection.ltr,
        )..layout();
        mark.paint(canvas, rect.center - Offset(mark.width / 2, mark.height / 2));
        mark.dispose();
      }
    } else {
      canvas.drawRRect(rounded, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.006 + 2);
    }
  }
}

/// [png] with the covers of [region] drawn on it, as a PNG (for the Anki export, which has no covers of its own).
Future<Uint8List> pictureWithCovers(Uint8List png, RegionCard region, {required bool front}) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    final size = Size(image.width.toDouble(), image.height.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());
    paintCovers(canvas, size, region, front: front);
    final drawn = await recorder.endRecording().toImage(image.width, image.height);
    try {
      return (await drawn.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    } finally {
      drawn.dispose();
    }
  } finally {
    image.dispose();
  }
}

/// The picture of a card of a part of a page, with its covers, as big as there is room for.
class CardPicture extends StatelessWidget {
  final CardRepository cards;
  final RegionCard region;
  final bool front;

  const CardPicture({super.key, required this.cards, required this.region, required this.front});

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: cards.picture(region.picture),
        builder: (context, shot) {
          final png = shot.data;
          return AspectRatio(
            aspectRatio: region.width / region.height,
            child: png == null
                ? Center(
                    child: shot.connectionState == ConnectionState.done
                        ? Text('The picture of this card is not on this device yet.', key: const ValueKey('card-picture-missing'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
                        : const CircularProgressIndicator.adaptive(),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(fit: StackFit.expand, children: [
                      ColoredBox(color: Colors.white, child: Image.memory(png, key: const ValueKey('card-picture'), fit: BoxFit.fill, gaplessPlayback: true)),
                      CustomPaint(painter: _CoversPainter(region, front)),
                    ]),
                  ),
          );
        },
      );
}

class _CoversPainter extends CustomPainter {
  final RegionCard region;
  final bool front;

  _CoversPainter(this.region, this.front);

  @override
  void paint(Canvas canvas, Size size) => paintCovers(canvas, size, region, front: front);

  @override
  bool shouldRepaint(_CoversPainter old) => old.region != region || old.front != front;
}
