// Draws the spelling marks of real pages (local only): flutter test tool/handwriting_bench/spell_marks_view_test.dart
//   --dart-define=PAGES=pages.json --dart-define=READS=reads.json --dart-define=DIC=de_DE --dart-define=OUT=dir
// PAGES/READS as in integration_test/ink_read_pages_test.dart. Every checked word is drawn as a box (red: not known, green: known)
// over the strokes, with the strokes it selects in orange.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/ink/ink_spelling.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/spelling/hunspell.dart';
import 'package:notes/spelling/spell_checker.dart';

const pagesPath = String.fromEnvironment('PAGES');
const readsPath = String.fromEnvironment('READS');
const dic = String.fromEnvironment('DIC');
const outDir = String.fromEnvironment('OUT');

void main() {
  testWidgets('draw the marks', (tester) async {
    if (pagesPath.isEmpty) return;
    await tester.runAsync(() async {
      final checker = SpellChecker()..dictionaries = [await HunspellDictionary.parse(File('$dic.aff').readAsBytesSync(), File('$dic.dic').readAsBytesSync())];
      final reads = jsonDecode(File(readsPath).readAsStringSync()) as Map<String, dynamic>;
      Directory(outDir).createSync(recursive: true);
      for (final page in jsonDecode(File(pagesPath).readAsStringSync()) as List) {
        final id = page['id'] as String;
        final lines = reads[id] as List?;
        if (lines == null) continue;
        final strokes = [
          for (final s in page['strokes'] as List)
            if ((s['pts'] as List).length >= 4)
              DrawingStroke(
                color: ui.Color(s['c'] as int),
                width: (s['w'] as num?)?.toDouble() ?? 3,
                points: () {
                  final v = (s['pts'] as List).cast<num>();
                  return [for (var i = 0; i + 1 < v.length; i += 2) ui.Offset(v[i].toDouble(), v[i + 1].toDouble())];
                }(),
              ),
        ];
        var n = 0;
        final marks = <InkMisspelling>[];
        for (final block in clusterStrokes(0, strokes)) {
          final rows = <String>[];
          for (final _ in groupIntoLines(block.strokes)) {
            final parts = lines[n++]['parts'] as List;
            rows.add([for (final p in parts) if (p['kept'] == true) p['text'] as String].join(' '));
          }
          marks.addAll(checkedInk([(block: block, text: rows.join('\n'))], checker));
        }
        final all = strokes.map(strokeBounds).reduce((a, b) => a.expandToInclude(b)).inflate(10);
        const k = 1.5;
        final rec = ui.PictureRecorder();
        final c = ui.Canvas(rec);
        c.scale(k);
        c.translate(-all.left, -all.top);
        c.drawRect(all, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
        final orange = <DrawingStroke>{for (final m in marks) ...m.strokes};
        for (final s in strokes) {
          final p = ui.Path()..moveTo(s.points.first.dx, s.points.first.dy);
          for (final q in s.points.skip(1)) {
            p.lineTo(q.dx, q.dy);
          }
          c.drawPath(p, ui.Paint()..style = ui.PaintingStyle.stroke..strokeWidth = 2..color = orange.contains(s) ? const ui.Color(0xFFFF8800) : const ui.Color(0xFF000000));
        }
        for (final m in marks) {
          c.drawRect(m.rect, ui.Paint()..style = ui.PaintingStyle.stroke..strokeWidth = 1..color = m.correct ? const ui.Color(0xFF00AA00) : const ui.Color(0xFFFF0000));
          final tp = TextPainter(text: TextSpan(text: m.word, style: const TextStyle(fontSize: 9, color: ui.Color(0xFF0000FF))), textDirection: TextDirection.ltr)..layout();
          tp.paint(c, m.rect.bottomLeft);
        }
        final img = await rec.endRecording().toImage((all.width * k).ceil(), (all.height * k).ceil());
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$outDir/$id.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        debugPrint('$id: ${marks.length} marks');
      }
    });
  });
}
