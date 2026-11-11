// What the handwriting reader makes of the generated pages of test/fixtures/ink_layout/mixed_pages.json, read the way the app reads a
// note (blocks, lines, pieces of a line, GLM-OCR through ONNX Runtime), held against what each row says. Prints the error per kind of page
// and per kind of row, and how much was read out of drawings, which should be nothing:
//   flutter test integration_test/ink_read_eval_test.dart -d linux --dart-define=MODEL_DIR=$HOME/hw-bench/glm_release \
//     [--dart-define=ONLY=kind_0,kind_1] [--dart-define=OUT=/path/reads.json] [--dart-define=MATH_DIR=/path/to/texteller]
// It needs the model files, so it is not run with the other tests; OUT keeps every row's reading to compare two runs, and every piece that
// was read with how sure the reader was of it and how much of it is drawing. With MATH_DIR (the folder of the maths check's encoder.onnx and
// decoder.onnx), the rows of formulas are also read by the maths check's own reader, the way it reads them (rows of rowsOf), to compare.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notes/ink/glm_ocr.dart';
import 'package:notes/ink/glm_ocr_service.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/ink/ink_image.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/ink/onnx_glm_ocr.dart';
import 'package:notes/models/canvas_models.dart';

const modelDir = String.fromEnvironment('MODEL_DIR');
const only = String.fromEnvironment('ONLY');
const outPath = String.fromEnvironment('OUT');
const mathDir = String.fromEnvironment('MATH_DIR');

const _drawing = 2;

/// [s] as it is compared: what differs between two ways of writing the same thing (spaces, dollar signs, braces, `\left`) is left out.
String normalise(String s) => s
    // a matrix may be written as an array in brackets, a pmatrix or a bmatrix
    .replaceAll(RegExp(r'(\\left\s*[(\[]\s*)?\\begin\{(array|[pbv]?matrix)\}(\{[^}]*\})?'), 'M(')
    .replaceAll(RegExp(r'\\end\{(array|[pbv]?matrix)\}(\s*\\right\s*[)\]])?'), ')')
    .replaceAll(RegExp(r'\\(left|right|mathrm|text|,|;|!|quad)'), '')
    // r_{1} and r1 are the same reading of a small 1 beside an r
    .replaceAll(RegExp(r'[\s${}_^]'), '')
    .replaceAll(r'\cdot', '·')
    .replaceAll(r'\to', r'\rightarrow')
    .toLowerCase();

int distance(String a, String b) {
  var prev = List.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = [i, ...List.filled(b.length, 0)];
    for (var j = 1; j <= b.length; j++) {
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('read the generated pages and score the readings', (tester) async {
    await tester.runAsync(() async {
      final vocabulary = GlmVocabulary.parse(File('assets/glm_ocr/vocab.txt').readAsStringSync());
      final reader = GlmOnnxReader();
      MathService? formulas;
      if (mathDir.isNotEmpty) {
        formulas = MathService(defaultModel: FormulaModel.texteller, tellerDirectory: () async => Directory(mathDir));
        await formulas.load();
      }
      final pieceLog = <Map<String, Object?>>[];
      final pages = jsonDecode(File('test/fixtures/ink_layout/mixed_pages.json').readAsStringSync()) as List;
      final out = <Map<String, Object?>>[];
      // per kind of page and kind of row: errors and characters wanted; characters read out of drawings
      final errors = <String, int>{}, wanted = <String, int>{}, fromDrawings = <String, int>{};
      final watch = Stopwatch()..start();
      for (final page in pages) {
        final id = page['id'] as String;
        final kind = id.substring(0, id.lastIndexOf('_'));
        if (only.isNotEmpty && !only.split(',').contains(id) && !only.split(',').contains(kind)) continue;
        final raw = [for (final s in page['strokes'] as List) if ((s['pts'] as List).length >= 2) s];
        final strokes = [
          for (final s in raw)
            DrawingStroke(
              color: Color(s['c'] as int),
              width: (s['w'] as num?)?.toDouble() ?? 3,
              points: () {
                final v = (s['pts'] as List).cast<num>();
                return [for (var i = 0; i + 1 < v.length; i += 2) Offset(v[i].toDouble(), v[i + 1].toDouble())];
              }(),
            ),
        ];
        final truth = {for (var i = 0; i < raw.length; i++) strokes[i]: (raw[i]['t'] as List).cast<int>()};
        final says = (page['says'] as Map).cast<String, String>();
        final got = <String, List<(double, String)>>{};
        for (final block in clusterStrokes(0, strokes)) {
          for (final line in groupIntoLines(block.strokes)) {
            final pieces = GlmOcrService.joinChunks(line);
            final pictures = [for (final p in pieces) await renderInkForGlmOcr(p, rows: GlmQuality.standard.rows)];
            final readings = await reader.readScored('$modelDir/vision.onnx', '$modelDir/text.onnx', '$modelDir/embeddings.bin', pictures);
            for (var i = 0; i < pieces.length; i++) {
              final drawn = pieces[i].where((s) => truth[s]![2] == _drawing).length;
              pieceLog.add({'page': id, 'strokes': pieces[i].length, 'drawing': drawn / pieces[i].length, 'confidence': readings[i].confidence, 'text': vocabulary.decode(readings[i].tokens)});
            }
            // (as the app keeps it: what is not writing left out, see GlmOcrService.isWriting)
            final text = [
              for (final r in readings)
                if (GlmOcrService.isWriting(vocabulary.decode(r.tokens), r.confidence)) vocabulary.decode(r.tokens),
            ].join(' ');
            // the row the line is, by most of its strokes; a line of a drawing's strokes is a drawing
            final votes = <String, int>{};
            for (final chunk in line) {
              for (final s in chunk.strokes) {
                final [b, r, k] = truth[s]!;
                final key = k == _drawing || r < 0 ? 'drawing' : '$b/$r';
                votes[key] = (votes[key] ?? 0) + 1;
              }
            }
            final row = votes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
            // (the lines of one row are beside each other, a label and its formula: in the order they are written, left to right)
            final left = line.map((c) => c.bounds.left).reduce(math.min);
            got.putIfAbsent(row, () => []).add((left, text));
          }
        }
        // the maths check's reader, on its rows
        final formulaRead = <String, List<(double, String)>>{};
        if (formulas != null) {
          for (final row in clusterStrokes(0, strokes, rows: true)) {
            final votes = <String, int>{};
            for (final s in row.strokes) {
              final [b, r, k] = truth[s]!;
              if (k != _drawing && r >= 0) votes['$b/$r'] = (votes['$b/$r'] ?? 0) + 1;
            }
            if (votes.isEmpty) continue;
            final key = votes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
            if (!(says[key] ?? '').contains(r'$')) continue;
            final latex = await formulas.recognize(row.strokes);
            formulaRead.putIfAbsent(key, () => []).add((row.bounds.left, latex));
          }
        }
        for (final e in says.entries) {
          final parts = (got[e.key] ?? [])..sort((a, b) => a.$1.compareTo(b.$1));
          final read = parts.map((p) => p.$2).join(' ');
          final rowKind = e.value.contains(r'$') ? (e.value.startsWith(r'$') && e.value.endsWith(r'$') ? 'maths' : 'mixed') : 'text';
          final want = normalise(e.value), have = normalise(read);
          final d = distance(want, have);
          for (final k in ['$kind $rowKind', 'all $rowKind']) {
            errors[k] = (errors[k] ?? 0) + d;
            wanted[k] = (wanted[k] ?? 0) + want.length;
          }
          final entry = {'page': id, 'row': e.key, 'kind': rowKind, 'want': e.value, 'got': read, 'cer': want.isEmpty ? 0 : d / want.length};
          if (formulas != null && rowKind == 'maths') {
            final parts = (formulaRead[e.key] ?? [])..sort((a, b) => a.$1.compareTo(b.$1));
            final latex = parts.map((p) => p.$2).join(' ');
            final fd = distance(want, normalise(latex));
            entry['formula'] = latex;
            entry['formulaCer'] = want.isEmpty ? 0 : fd / want.length;
            errors['all maths (formula reader)'] = (errors['all maths (formula reader)'] ?? 0) + fd;
            wanted['all maths (formula reader)'] = (wanted['all maths (formula reader)'] ?? 0) + want.length;
          }
          out.add(entry);
        }
        final drawn = [for (final p in got['drawing'] ?? const <(double, String)>[]) p.$2].join(' ');
        if (drawn.isNotEmpty) {
          fromDrawings[kind] = (fromDrawings[kind] ?? 0) + normalise(drawn).length;
          out.add({'page': id, 'row': 'drawing', 'kind': 'drawing', 'want': '', 'got': drawn});
        }
        debugPrint('$id read (${(watch.elapsedMilliseconds / 1000).round()} s)');
      }
      await reader.close();
      final report = StringBuffer('character error rate (errors / characters wanted):\n');
      for (final k in errors.keys.toList()..sort()) {
        report.writeln('  ${k.padRight(28)} ${(100 * errors[k]! / math.max(1, wanted[k]!)).toStringAsFixed(1).padLeft(5)} %  of ${wanted[k]}');
      }
      report.writeln('characters read out of drawings: $fromDrawings');
      debugPrint(report.toString());
      if (outPath.isNotEmpty) File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert({'rows': out, 'pieces': pieceLog}));
    });
  }, timeout: const Timeout(Duration(minutes: 90)));
}
