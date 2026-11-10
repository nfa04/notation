import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/images/picture_edit.dart';

/// A picture whose pixels say where they are: red is the column, green the row.
RgbaPicture grid(int w, int h) {
  final p = RgbaPicture.filled(w, h, 0, 0, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      p.setPixel(x, y, x * 10, y * 10, 100);
    }
  }
  return p;
}

/// White paper with a black square in it (from 3,3 to 6,6), with a white dot in the middle of the square (at 4,4).
RgbaPicture paper() {
  final p = RgbaPicture.filled(10, 10, 255, 255, 255);
  for (var y = 3; y <= 6; y++) {
    for (var x = 3; x <= 6; x++) {
      p.setPixel(x, y, 0, 0, 0);
    }
  }
  p.setPixel(4, 4, 255, 255, 255);
  return p;
}

void main() {
  group('turning, flipping and cutting', () {
    test('a quarter turn clockwise: the top row becomes the right column, and four of them are the picture again', () {
      final p = grid(3, 2); // 3 wide, 2 high
      final t = p.rotated(1);
      expect((t.width, t.height), (2, 3));
      // the pixel at the top left (0,0) goes to the top right (1,0); the one at the top right (2,0) to the bottom right (1,2)
      expect(t.pixel(1, 0), p.pixel(0, 0));
      expect(t.pixel(1, 2), p.pixel(2, 0));
      expect(t.pixel(0, 0), p.pixel(0, 1));
      expect(p.rotated(4).rgba, p.rgba);
      expect(p.rotated(1).rotated(1).rotated(1).rotated(1).rgba, p.rgba);
      expect(p.rotated(2).pixel(0, 0), p.pixel(2, 1));
      final back = p.rotated(3);
      expect((back.width, back.height), (2, 3));
      expect(back.pixel(0, 2), p.pixel(0, 0), reason: 'three turns clockwise is one anticlockwise: the top left goes to the bottom left');
      expect(p.rotated(3).rgba, p.rotated(-1 + 4).rgba);
    });

    test('flips mirror, twice is nothing', () {
      final p = grid(4, 3);
      expect(p.flipped(horizontal: true).pixel(0, 0), p.pixel(3, 0));
      expect(p.flipped(vertical: true).pixel(0, 0), p.pixel(0, 2));
      expect(p.flipped(horizontal: true).flipped(horizontal: true).rgba, p.rgba);
      expect(p.flipped().rgba, p.rgba);
    });

    test('cutting takes a part off each side, and always leaves a pixel', () {
      final p = grid(10, 8);
      final c = p.cropped(0.2, 0.25, 0.3, 0);
      expect((c.width, c.height), (5, 6));
      expect(c.pixel(0, 0), p.pixel(2, 2));
      final tiny = p.cropped(0.9, 0.9, 0.9, 0.9);
      expect(tiny.width, greaterThanOrEqualTo(1));
      expect(tiny.height, greaterThanOrEqualTo(1));
    });

    test('everything together is done in order: turn, flip, cut', () {
      final p = grid(4, 2);
      final out = applyPictureEdit(p, const PictureEdit(turns: 1, flipHorizontal: true, cropBottom: 0.5));
      // turned: 2 wide, 4 high; cut at the bottom: 2 by 2
      expect((out.width, out.height), (2, 2));
      expect(out.rgba, p.rotated(1).flipped(horizontal: true).cropped(0, 0, 0, 0.5).rgba);
      expect(p.rgba, grid(4, 2).rgba, reason: 'the original is left alone');
    });
  });

  group('colours', () {
    RgbaPicture one(int r, int g, int b) => RgbaPicture.filled(2, 2, r, g, b);
    (int, int, int) rgb(RgbaPicture p) {
      final (r, g, b, _) = p.pixel(0, 0);
      return (r, g, b);
    }

    test('nothing set changes nothing', () {
      expect(PictureEdit.none.isNone, isTrue);
      final p = grid(3, 3);
      expect(applyPictureEdit(p, PictureEdit.none).rgba, p.rgba);
      expect(const PictureEdit(turns: 4).isNone, isTrue);
      expect(const PictureEdit(brightness: 0.1).isNone, isFalse);
    });

    test('brightness lightens and darkens, and stays in range', () {
      expect(rgb(applyPictureEdit(one(100, 100, 100), const PictureEdit(brightness: 0.2))), (151, 151, 151));
      expect(rgb(applyPictureEdit(one(100, 100, 100), const PictureEdit(brightness: -0.2))), (49, 49, 49));
      expect(rgb(applyPictureEdit(one(250, 10, 100), const PictureEdit(brightness: 1))), (255, 255, 255));
      expect(rgb(applyPictureEdit(one(250, 10, 100), const PictureEdit(brightness: -1))), (0, 0, 0));
    });

    test('contrast pushes away from the middle grey, and at the lowest makes everything grey', () {
      final more = rgb(applyPictureEdit(one(160, 100, 128), const PictureEdit(contrast: 0.5)));
      expect(more.$1, greaterThan(160));
      expect(more.$2, lessThan(100));
      expect(more.$3, 128);
      final flat = rgb(applyPictureEdit(one(200, 30, 90), const PictureEdit(contrast: -1)));
      expect(flat, (128, 128, 128));
    });

    test('saturation at the lowest is grey, and more makes colours stronger', () {
      final grey = rgb(applyPictureEdit(one(200, 50, 50), const PictureEdit(saturation: -1)));
      expect(grey.$1, grey.$2);
      expect(grey.$2, grey.$3);
      final strong = rgb(applyPictureEdit(one(200, 100, 100), const PictureEdit(saturation: 0.5)));
      expect(strong.$1 - strong.$2, greaterThan(100));
    });

    test('the filters', () {
      expect(rgb(applyPictureEdit(one(255, 0, 0), const PictureEdit(filter: PictureFilter.invert))), (0, 255, 255));
      final g = rgb(applyPictureEdit(one(255, 0, 0), const PictureEdit(filter: PictureFilter.grayscale)));
      expect(g.$1, 76);
      expect(g.$1 == g.$2 && g.$2 == g.$3, isTrue);
      final s = rgb(applyPictureEdit(one(100, 100, 100), const PictureEdit(filter: PictureFilter.sepia)));
      expect(s.$1, greaterThan(s.$2));
      expect(s.$2, greaterThan(s.$3));
      expect(rgb(applyPictureEdit(one(200, 200, 200), const PictureEdit(filter: PictureFilter.blackWhite))), (255, 255, 255));
      expect(rgb(applyPictureEdit(one(60, 60, 60), const PictureEdit(filter: PictureFilter.blackWhite))), (0, 0, 0));
    });

    test('the dominant colours are the biggest areas, the commonest first, and shades of one colour are one', () {
      final p = RgbaPicture.filled(30, 10, 250, 250, 250); // mostly white
      for (var y = 0; y < 10; y++) {
        for (var x = 0; x < 8; x++) {
          p.setPixel(x, y, 200, 20, 20, 255); // a red area
        }
        for (var x = 8; x < 12; x++) {
          p.setPixel(x, y, 205 + x, 25, 20, 255); // nearly the same red, another box
        }
        for (var x = 12; x < 15; x++) {
          p.setPixel(x, y, 20, 40, 220, 255); // a blue one
        }
      }
      final colours = dominantColours(p, count: 4);
      expect(colours.first, (250, 250, 250));
      expect(colours.length, 3, reason: 'white, red (once) and blue');
      expect(colours[1].$1, greaterThan(190));
      expect(colours[2].$3, greaterThan(200));
      expect(dominantColours(RgbaPicture.filled(4, 4, 9, 9, 9)), [(9, 9, 9)]);
      final clear = RgbaPicture.filled(4, 4, 1, 2, 3, 0);
      expect(dominantColours(clear), isEmpty, reason: 'see-through counts for nothing');
      expect(dominantColoursOf(Uint8List.fromList([1, 2, 3])), isEmpty);
    });

    test('a pencil sketch is white where the picture is flat and dark where there is shading; a line drawing is white but for edges', () {
      // left half white, right half black, 40 x 20
      final p = RgbaPicture.filled(40, 20, 255, 255, 255);
      for (var y = 0; y < 20; y++) {
        for (var x = 20; x < 40; x++) {
          p.setPixel(x, y, 0, 0, 0, 255);
        }
      }
      final sketch = applyPictureEdit(p, const PictureEdit(filter: PictureFilter.sketch));
      expect(sketch.pixel(2, 10).$1, greaterThan(240), reason: 'flat white stays white');
      expect(sketch.pixel(38, 10).$1, lessThan(30), reason: 'solid black stays black');
      expect(sketch.pixel(2, 10).$1, greaterThan(sketch.pixel(21, 10).$1), reason: 'the dark side of an edge is darker than flat');
      final lines = applyPictureEdit(p, const PictureEdit(filter: PictureFilter.lineDrawing));
      expect(lines.pixel(3, 10).$1, 255);
      expect(lines.pixel(37, 10).$1, 255);
      expect(lines.pixel(20, 10).$1, lessThan(60), reason: 'the edge is a dark line');
      expect(lines.pixel(20, 10).$4, 255, reason: 'the picture stays as opaque as it was');
      expect(const PictureEdit(filter: PictureFilter.sketch).isNone, isFalse);
    });

    test('colours change nothing about the see-through part of a picture', () {
      final p = RgbaPicture.filled(2, 2, 10, 20, 30, 77);
      expect(applyPictureEdit(p, const PictureEdit(brightness: 0.5, filter: PictureFilter.invert)).pixel(1, 1).$4, 77);
    });
  });

  group('the background', () {
    test('from the edges takes the paper away but not the white inside the subject', () {
      final p = paper();
      final out = applyPictureEdit(p, const PictureEdit(background: BackgroundRemoval.fromEdges, softness: 0));
      expect(out.pixel(0, 0).$4, 0);
      expect(out.pixel(9, 9).$4, 0);
      expect(out.pixel(2, 5).$4, 0, reason: 'paper next to the square');
      expect(out.pixel(3, 3).$4, 255, reason: 'the square stays');
      expect(out.pixel(4, 4).$4, 255, reason: 'a white dot inside the square is enclosed, so it stays');
      expect(p.pixel(0, 0).$4, 255, reason: 'the original is left alone');
    });

    test('everywhere takes every pixel of that colour, also the one inside', () {
      final out = applyPictureEdit(paper(), const PictureEdit(background: BackgroundRemoval.everywhere, softness: 0));
      expect(out.pixel(0, 0).$4, 0);
      expect(out.pixel(4, 4).$4, 0);
      expect(out.pixel(3, 3).$4, 255);
    });

    test('a colour picked on the picture is the one that goes, and a picked colour that is not the paper keeps the paper', () {
      final out = applyPictureEdit(paper(), const PictureEdit(background: BackgroundRemoval.everywhere, backgroundColor: 0xFF000000, softness: 0));
      expect(out.pixel(3, 3).$4, 0, reason: 'black went');
      expect(out.pixel(0, 0).$4, 255, reason: 'white stayed');
    });

    test('the tolerance decides how different a colour may be, and the soft edge makes the end of it gradual', () {
      final p = RgbaPicture.filled(5, 1, 255, 255, 255);
      for (var x = 0; x < 5; x++) {
        final v = 255 - x * 20; // 255, 235, 215, 195, 175
        p.setPixel(x, 0, v, v, v);
      }
      final hard = applyPictureEdit(p, const PictureEdit(background: BackgroundRemoval.everywhere, tolerance: 0.1, softness: 0, backgroundColor: 0xFFFFFFFF));
      // 0.1 of the longest distance is 44 (of three equal steps: 25 per 20 levels)
      expect([for (var x = 0; x < 5; x++) hard.pixel(x, 0).$4], [0, 0, 255, 255, 255]);
      final soft = applyPictureEdit(p, const PictureEdit(background: BackgroundRemoval.everywhere, tolerance: 0.1, softness: 0.2, backgroundColor: 0xFFFFFFFF));
      final alphas = [for (var x = 0; x < 5; x++) soft.pixel(x, 0).$4];
      expect(alphas.first, 0);
      for (var i = 1; i < alphas.length; i++) {
        expect(alphas[i], greaterThanOrEqualTo(alphas[i - 1]), reason: 'the further from the background, the more is kept');
      }
      expect(alphas[2], inInclusiveRange(1, 254));
    });

    test('a picture whose edge is not one colour takes the colour most of it has', () {
      final p = RgbaPicture.filled(8, 8, 200, 30, 30);
      for (var x = 0; x < 3; x++) {
        p.setPixel(x, 0, 255, 255, 255);
      }
      final (r, g, b) = edgeColour(p);
      expect((r, g, b), (200, 30, 30));
      expect(edgeColour(RgbaPicture.filled(4, 4, 0, 0, 0, 0)), (255, 255, 255), reason: 'an edge with nothing opaque has no colour: white');
    });

    test('a picture that is all background becomes all see-through, and a one-pixel picture does not break', () {
      final out = applyPictureEdit(RgbaPicture.filled(4, 4, 9, 9, 9), const PictureEdit(background: BackgroundRemoval.fromEdges));
      expect(out.rgba.where((v) => v == 0).length, greaterThanOrEqualTo(16));
      expect(out.hasTransparency, isTrue);
      applyPictureEdit(RgbaPicture.filled(1, 1, 9, 9, 9), const PictureEdit(background: BackgroundRemoval.fromEdges));
    });
  });

  group('the edit', () {
    test('values stay in range and a turn wraps', () {
      final e = PictureEdit.none.copyWith(turns: 5, cropLeft: 3, cropTop: -1, brightness: 9, contrast: -9, saturation: 2, tolerance: 4);
      expect(e.turns, 1);
      expect(e.cropLeft, 0.9);
      expect(e.cropTop, 0);
      expect(e.brightness, 1);
      expect(e.contrast, -1);
      expect(e.saturation, 1);
      expect(e.tolerance, 1);
    });

    test('equal edits are equal, and what makes a picture see-through is known', () {
      expect(const PictureEdit(brightness: 0.2), const PictureEdit(brightness: 0.2));
      expect(const PictureEdit(brightness: 0.2), isNot(const PictureEdit(brightness: 0.3)));
      expect(const PictureEdit(background: BackgroundRemoval.fromEdges).transparent, isTrue);
      expect(const PictureEdit(filter: PictureFilter.sepia).transparent, isFalse);
      final e = const PictureEdit(backgroundColor: 5).copyWith(clearBackgroundColor: true);
      expect(e.backgroundColor, isNull);
    });
  });

  group('as files', () {
    test('a picture is encoded and decoded again, transparency kept in a PNG', () {
      final p = grid(6, 4);
      p.setPixel(1, 1, 9, 9, 9, 0);
      final back = decodePicture(encodePicture(p))!;
      expect((back.width, back.height), (6, 4));
      expect(back.pixel(2, 2), p.pixel(2, 2));
      expect(back.pixel(1, 1).$4, 0);
    });

    test('a JPEG stays a JPEG when nothing in it is see-through, and becomes a PNG when something is', () {
      final p = grid(16, 16);
      final jpeg = encodePicture(p, jpeg: true);
      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
      final glass = grid(16, 16)..setPixel(0, 0, 1, 1, 1, 0);
      expect(encodePicture(glass, jpeg: true).sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(decodePicture(jpeg)!.width, 16);
    });

    test('a big picture is made smaller to the longest side asked, keeping its proportions', () {
      final bytes = encodePicture(RgbaPicture.filled(400, 200, 5, 5, 5));
      final small = decodePicture(bytes, maxSide: 100)!;
      expect((small.width, small.height), (100, 50));
      final tall = decodePicture(encodePicture(RgbaPicture.filled(100, 300, 5, 5, 5)), maxSide: 150)!;
      expect((tall.width, tall.height), (50, 150));
    });

    test('what is not a picture is none, and the function for isolates does the whole edit', () {
      expect(decodePicture(Uint8List.fromList([1, 2, 3])), isNull);
      expect(editPictureBytes((Uint8List.fromList([1, 2, 3]), PictureEdit.none, false, 4096, null)), isNull);
      final source = encodePicture(grid(8, 6), jpeg: false);
      final out = editPictureBytes((source, const PictureEdit(turns: 1, filter: PictureFilter.invert), false, 4096, null))!;
      final back = decodePicture(out.bytes)!;
      expect((back.width, back.height), (6, 8));
      expect((out.width, out.height), (6, 8));
      final (r, g, b, _) = back.pixel(5, 0); // the original's top left (0,0) = (0,0,100), inverted
      expect((r, g, b), (255, 255, 155));
    });
  });

  group('finding the subject', () {
    SubjectMatte halves(int w, int h, {bool leftIsSubject = true}) => SubjectMatte(w, h, Float32List.fromList([for (var y = 0; y < h; y++) for (var x = 0; x < w; x++) (x < w / 2) == leftIsSubject ? 1.0 : 0.0]));

    test('what the model is given: three planes of the size it wants, each as it was trained on', () {
      final grey = subjectModelInput(RgbaPicture.filled(50, 30, 128, 128, 128));
      const plane = subjectModelSide * subjectModelSide;
      expect(grey.length, 3 * plane);
      // every value is the greatest in the picture, so 1 after scaling: then the mean taken off and divided by the spread
      expect(grey[0], closeTo((1 - 0.485) / 0.229, 1e-5));
      expect(grey[plane], closeTo((1 - 0.456) / 0.224, 1e-5));
      expect(grey[2 * plane], closeTo((1 - 0.406) / 0.225, 1e-5));
      expect(grey[plane - 1], grey[0], reason: 'the same all over');
    });

    test('red on the left and blue on the right shows in the red plane on the left and the blue plane on the right', () {
      final p = RgbaPicture.filled(64, 64, 0, 0, 255);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 32; x++) {
          p.setPixel(x, y, 255, 0, 0);
        }
      }
      final input = subjectModelInput(p);
      const side = subjectModelSide, plane = side * side;
      double at(int channel, int x, int y) => input[channel * plane + y * side + x];
      expect(at(0, 10, 100), greaterThan(at(0, 300, 100)), reason: 'red is on the left');
      expect(at(2, 300, 100), greaterThan(at(2, 10, 100)), reason: 'blue is on the right');
      expect(at(0, 10, 10), closeTo(at(0, 10, 300), 1e-5), reason: 'the picture is made that size, not cut');
    });

    test('a picture of many pixels is made that size smoothly (the average of what a pixel covers)', () {
      final p = RgbaPicture.filled(1000, 640, 0, 0, 0);
      for (var y = 0; y < 640; y++) {
        for (var x = 0; x < 1000; x++) {
          final v = (x + y).isEven ? 255 : 0; // a fine checkerboard: its average is half
          p.setPixel(x, y, v, v, v);
        }
      }
      final input = subjectModelInput(p);
      // white is (1 - mean) / spread after scaling, black (0 - mean) / spread: the average of a box is between, near the middle
      final white = (1 - 0.485) / 0.229, black = (0 - 0.485) / 0.229, middle = (white + black) / 2;
      var worst = 0.0;
      for (var i = 0; i < subjectModelSide * subjectModelSide; i += 997) {
        worst = [worst, (input[i] - middle).abs()].reduce((a, b) => a > b ? a : b);
      }
      expect(worst, lessThan((white - black) * 0.3), reason: 'not black or white, but about between');
    });

    test('the answer is stretched to 0 to 1, and an answer that says the same everywhere finds nothing', () {
      final raw = Float32List(subjectModelSide * subjectModelSide);
      for (var i = 0; i < raw.length; i++) {
        raw[i] = 0.2 + 0.4 * (i % 2); // 0.2 and 0.6
      }
      final m = subjectMatteFrom(raw);
      expect((m.width, m.height), (subjectModelSide, subjectModelSide));
      expect(m.values.reduce((a, b) => a < b ? a : b), 0);
      expect(m.values.reduce((a, b) => a > b ? a : b), 1);
      expect(subjectMatteFrom(Float32List(subjectModelSide * subjectModelSide)..fillRange(0, subjectModelSide * subjectModelSide, 0.7)).values.every((v) => v == 0), isTrue);
    });

    test('the matte is made the size of a picture, smoothly, and keeps its sides', () {
      final big = halves(4, 4).asPicture(40, 20);
      expect((big.width, big.height), (40, 20));
      expect(big.pixel(0, 5).$1, 255);
      expect(big.pixel(39, 5).$1, 0);
      final across = [for (var x = 0; x < 40; x++) big.pixel(x, 5).$1];
      for (var i = 1; i < across.length; i++) {
        expect(across[i], lessThanOrEqualTo(across[i - 1]), reason: 'from the subject to the rest without going back');
      }
      expect(across[20], inInclusiveRange(1, 254), reason: 'the edge is soft, not a step');
    });

    test('only the subject stays: what is on the model\'s other side is see-through, and with no matte nothing changes', () {
      final p = grid(10, 6);
      final out = applyPictureEdit(p, const PictureEdit(background: BackgroundRemoval.subject, softness: 0), subject: halves(10, 6));
      expect(out.pixel(1, 3).$4, 255);
      expect(out.pixel(8, 3).$4, 0);
      expect(out.pixel(1, 3).$1, p.pixel(1, 3).$1, reason: 'the colours stay');
      expect(applyPictureEdit(p, const PictureEdit(background: BackgroundRemoval.subject)).hasTransparency, isFalse);
    });

    test('the matte goes with the picture when it is turned, flipped and cut', () {
      final p = grid(10, 6);
      final matte = halves(10, 6); // the left half
      final turned = applyPictureEdit(p, const PictureEdit(turns: 1, background: BackgroundRemoval.subject, softness: 0), subject: matte);
      // a quarter turn clockwise puts the left side at the top: the top half of the 6-wide, 10-high picture stays
      expect((turned.width, turned.height), (6, 10));
      expect(turned.pixel(3, 1).$4, 255);
      expect(turned.pixel(3, 8).$4, 0);
      final flipped = applyPictureEdit(p, const PictureEdit(flipHorizontal: true, background: BackgroundRemoval.subject, softness: 0), subject: matte);
      expect(flipped.pixel(1, 3).$4, 0);
      expect(flipped.pixel(8, 3).$4, 255);
      final cut = applyPictureEdit(p, const PictureEdit(cropLeft: 0.4, background: BackgroundRemoval.subject, softness: 0), subject: matte);
      expect(cut.width, 6);
      expect(cut.pixel(0, 3).$4, 255, reason: 'what is left of the subject');
      expect(cut.pixel(5, 3).$4, 0);
    });

    test('how sure the model has to be, and the soft edge, decide how much stays', () {
      final matte = SubjectMatte(2, 1, Float32List.fromList([0.3, 0.7]));
      final p = RgbaPicture.filled(2, 1, 10, 10, 10);
      RgbaPicture cutAt(double cut) => applyPictureEdit(p, PictureEdit(background: BackgroundRemoval.subject, subjectCut: cut, softness: 0), subject: matte);
      expect([cutAt(0.2).pixel(0, 0).$4, cutAt(0.2).pixel(1, 0).$4], [255, 255]);
      expect([cutAt(0.5).pixel(0, 0).$4, cutAt(0.5).pixel(1, 0).$4], [0, 255]);
      expect([cutAt(0.9).pixel(0, 0).$4, cutAt(0.9).pixel(1, 0).$4], [0, 0]);
      final soft = applyPictureEdit(p, const PictureEdit(background: BackgroundRemoval.subject, subjectCut: 0.5, softness: 0.6), subject: matte);
      expect(soft.pixel(0, 0).$4, inInclusiveRange(1, 254));
      expect(soft.pixel(1, 0).$4, inInclusiveRange(1, 254));
    });

    test('a subject in a PNG that is edited as a file, and see-through, comes out a PNG', () {
      final source = encodePicture(grid(10, 6), jpeg: true);
      final out = editPictureBytes((source, const PictureEdit(background: BackgroundRemoval.subject, softness: 0), true, 4096, halves(10, 6)))!;
      expect(out.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(decodePicture(out.bytes)!.pixel(8, 3).$4, 0);
    });
  });
}
