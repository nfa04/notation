import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/graph/graph_builder.dart';
import 'package:notes/graph/graph_model.dart';

Float32List _unit(math.Random r, int dim) {
  final v = Float32List(dim);
  var len = 0.0;
  for (var d = 0; d < dim; d++) {
    v[d] = r.nextDouble() - 0.5;
    len += v[d] * v[d];
  }
  len = math.sqrt(len);
  for (var d = 0; d < dim; d++) {
    v[d] /= len;
  }
  return v;
}

double _dot(Float32List a, Float32List b) {
  var s = 0.0;
  for (var d = 0; d < math.min(a.length, b.length); d++) {
    s += a[d] * b[d];
  }
  return s;
}

void main() {
  // The similar edges of the graph are what a loop over every pair gives: each node to its k most alike above the bar.
  void check(List<Float32List?> vectors, {required int k, required double bar}) {
    final inputs = [for (var i = 0; i < vectors.length; i++) GraphInput(id: 'n$i', kind: GraphNodeKind.fact, label: 'n$i', vector: vectors[i])];
    final g = buildGraph('facts', inputs, settings: GraphSettings(neighbours: k, minSimilarity: bar, topicHubs: false));
    final want = <(int, int)>{};
    for (var a = 0; a < vectors.length; a++) {
      final va = vectors[a];
      if (va == null) continue;
      final near = <(double, int)>[
        for (var b = 0; b < vectors.length; b++)
          if (b != a && vectors[b] != null && _dot(va, vectors[b]!) >= bar + 1e-5) (_dot(va, vectors[b]!), b),
      ]..sort((x, y) => y.$1.compareTo(x.$1));
      for (final (_, b) in near.take(k)) {
        want.add((math.min(a, b), math.max(a, b)));
      }
    }
    final got = {for (final e in g.edges) (e.a, e.b)};
    // (a pair that sits within rounding of the bar or of another's k-th place may go either way: those are not asked about)
    expect(got.containsAll(want), isTrue, reason: 'missing ${want.difference(got)}');
    for (final (a, b) in got) {
      expect(_dot(vectors[a]!, vectors[b]!), greaterThanOrEqualTo(bar - 1e-4));
    }
    for (final e in g.edges) {
      expect(e.weight, inInclusiveRange(bar * 0.85 - 1e-3, 1.0001));
    }
  }

  test('same similar edges as comparing every pair (a width that is not a multiple of four, more than one tile)', () {
    final r = math.Random(3);
    check([for (var i = 0; i < 300; i++) _unit(r, 37)], k: 4, bar: 0.0);
  });

  test('nodes with no vector are left out, and vectors of different length compare as far as both reach', () {
    final r = math.Random(5);
    final base = [for (var i = 0; i < 80; i++) _unit(r, 12)];
    final vectors = <Float32List?>[
      for (var i = 0; i < 80; i++)
        if (i % 7 == 0) null else if (i % 5 == 0) Float32List.sublistView(base[i], 0, 9) else base[i],
    ];
    check(vectors, k: 3, bar: -0.2);
  });

  test('a bigger graph in a wide space', () {
    final r = math.Random(8);
    check([for (var i = 0; i < 500; i++) _unit(r, 96)], k: 4, bar: 0.1);
  });

  test('nothing with vectors, one node, none: no edges and no failure', () {
    check([null, null, null], k: 4, bar: 0.1);
    check([Float32List.fromList([1, 0, 0])], k: 4, bar: 0.1);
    expect(buildGraph('facts', const []).nodes, isEmpty);
  });
}
