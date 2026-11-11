// How pages of mixed handwriting are cut into blocks and lines, held against what is known to be right, so that a change to the cut that
// breaks a case that worked is seen.
//
// test/fixtures/ink_layout/mixed_pages.json: generated pages (tool/ink_fixtures/make_mixed_pages.py) of text, formulas, matrices and
// doodles, every stroke with its answer `t: [block, row, kind]` (kind 0 text, 1 maths, 2 drawing; row -1 for what is in no row). Each page
// is scored on three things:
//   lines:    every row is exactly one line of what the reader is given (clusterStrokes, then groupIntoLines), nothing more, nothing less
//             (drawings left aside);
//   rows:     no row of the maths check (clusterStrokes with rows) has strokes of two rows;
//   drawings: no line the reader is given has a drawing in it with writing.
// baseline.json says which page passed which; a page that passed and does not is a failure, one that passes now is told about. To take
// the results as the new baseline: flutter test test/ink_layout_test.dart --update-goldens
//
// test/fixtures/ink_layout_private/pages.json (git-ignored, never committed: pages of the owner's own notes) has no answers: its cut is
// kept in snapshot.json there, and any change to it is shown, to be looked at with tool/handwriting_bench/segment_view_test.dart and
// taken with --update-goldens. The test is skipped where the folder is missing.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ink/ink_clusters.dart';
import 'package:notes/ink/ink_grouping.dart';
import 'package:notes/models/canvas_models.dart';

const _public = 'test/fixtures/ink_layout';
const _private = 'test/fixtures/ink_layout_private';

typedef _Page = ({String id, List<DrawingStroke> strokes, List<List<int>>? truth});

List<_Page> _load(String path) => [
      for (final p in jsonDecode(File(path).readAsStringSync()) as List)
        () {
          final raw = [for (final s in p['strokes'] as List) if ((s['pts'] as List).length >= 2) s];
          return (
            id: p['id'] as String,
            strokes: [
              for (final s in raw)
                DrawingStroke(
                  color: Color(s['c'] as int),
                  width: (s['w'] as num?)?.toDouble() ?? 3,
                  brush: (s['b'] as String?) ?? penBrushId,
                  points: () {
                    final v = (s['pts'] as List).cast<num>();
                    return [for (var i = 0; i + 1 < v.length; i += 2) Offset(v[i].toDouble(), v[i + 1].toDouble())];
                  }(),
                ),
            ],
            truth: raw.every((s) => s['t'] != null) ? [for (final s in raw) (s['t'] as List).cast<int>()] : null,
          );
        }(),
    ];

/// The lines the reader is given, as sets of stroke numbers.
List<Set<int>> _lines(_Page page) {
  final index = {for (var i = 0; i < page.strokes.length; i++) page.strokes[i]: i};
  return [
    for (final block in clusterStrokes(0, page.strokes))
      for (final line in groupIntoLines(block.strokes)) {for (final chunk in line) for (final s in chunk.strokes) index[s]!},
  ];
}

/// The rows of the maths check.
List<Set<int>> _rows(_Page page) {
  final index = {for (var i = 0; i < page.strokes.length; i++) page.strokes[i]: i};
  return [for (final row in clusterStrokes(0, page.strokes, rows: true)) {for (final s in row.strokes) index[s]!}];
}

Map<String, bool> _score(_Page page) {
  final truth = page.truth!;
  const drawing = 2;
  final lines = _lines(page), rows = _rows(page);
  final wanted = <String, Set<int>>{};
  for (var i = 0; i < truth.length; i++) {
    final [block, row, kind] = truth[i];
    if (kind != drawing && row >= 0) wanted.putIfAbsent('$block/$row', () => {}).add(i);
  }
  final written = [for (final l in lines) l.where((i) => truth[i][2] != drawing).toSet()]..removeWhere((l) => l.isEmpty);
  bool same(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);
  final linesRight = wanted.length == written.length && wanted.values.every((w) => written.any((l) => same(l, w)));
  final rowsPure = rows.every((r) => {for (final i in r) if (truth[i][2] != drawing && truth[i][1] >= 0) '${truth[i][0]}/${truth[i][1]}'}.length <= 1);
  final drawingsOut = lines.every((l) => !l.any((i) => truth[i][2] == drawing) || l.every((i) => truth[i][2] == drawing));
  return {'lines': linesRight, 'rows': rowsPure, 'drawings': drawingsOut};
}

void main() {
  test('mixed pages are cut as they were, or better', () {
    final pages = _load('$_public/mixed_pages.json');
    final now = {for (final p in pages) p.id: _score(p)};
    final file = File('$_public/baseline.json');
    final totals = <String, int>{};
    for (final s in now.values) {
      s.forEach((k, v) => totals[k] = (totals[k] ?? 0) + (v ? 1 : 0));
    }
    // ignore: avoid_print
    print('ink layout, of ${pages.length} pages right: $totals');
    if (autoUpdateGoldenFiles || !file.existsSync()) {
      file.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(now)}\n');
      return;
    }
    final before = (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
    final worse = <String>[], better = <String>[];
    now.forEach((id, s) {
      final was = (before[id] as Map?)?.cast<String, bool>() ?? const {};
      s.forEach((k, v) {
        if (was[k] == true && !v) worse.add('$id $k');
        if (was[k] == false && v) better.add('$id $k');
      });
    });
    // ignore: avoid_print
    if (better.isNotEmpty) print('better than the baseline (take it with --update-goldens): $better');
    expect(worse, isEmpty, reason: 'cases that were right and are not any more');
  });

  final private = File('$_private/pages.json');
  test('the owner\'s own pages are cut as they were', () {
    final pages = _load(private.path);
    String cut(List<Set<int>> parts) => [for (final p in parts) (p.toList()..sort()).join(',')].join(' | ');
    final now = {for (final p in pages) p.id: {'lines': cut(_lines(p)), 'rows': cut(_rows(p))}};
    final file = File('$_private/snapshot.json');
    if (autoUpdateGoldenFiles || !file.existsSync()) {
      file.writeAsStringSync(jsonEncode(now));
      return;
    }
    final before = (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
    final changed = [
      for (final e in now.entries)
        for (final k in e.value.keys)
          if ((before[e.key] as Map?)?[k] != e.value[k]) '${e.key} $k',
    ];
    expect(changed, isEmpty, reason: 'look at these with tool/handwriting_bench/segment_view_test.dart; if they are better, --update-goldens');
  }, skip: private.existsSync() ? false : 'no private pages here');
}
