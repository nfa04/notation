import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/diagram/advanced.dart';
import 'package:notes/diagram/automaton.dart';
import 'package:notes/diagram/graph.dart';
import 'package:notes/diagram/ink_diagram.dart';
import 'package:notes/diagram/tree.dart';
import 'package:notes/models/canvas_models.dart';

/// Draws like a hand: a little wobble, a different start, more or less than a full turn.
class Pen {
  Pen([int seed = 4]) : random = math.Random(seed);
  final math.Random random;
  final strokes = <DrawingStroke>[];

  /// What each piece of writing says.
  final says = <String, String>{};

  DrawingStroke add(List<Offset> points) {
    final s = DrawingStroke(color: const Color(0xFF000000), width: 2, points: points);
    strokes.add(s);
    return s;
  }

  double _w(double amount) => (random.nextDouble() - 0.5) * amount;

  DrawingStroke circle(Offset c, double r, {double turns = 1.04, double from = 0.8}) => add([
        for (var i = 0; i <= 60; i++)
          c + Offset(math.cos(from + 2 * math.pi * turns * i / 60), math.sin(from + 2 * math.pi * turns * i / 60)) * (r + _w(2.0)),
      ]);

  List<Offset> _line(Offset a, Offset b, {double bend = 0}) {
    final mid = (a + b) / 2;
    final d = b - a;
    final normal = Offset(-d.dy, d.dx) / d.distance;
    return [
      for (var i = 0; i <= 24; i++)
        () {
          final t = i / 24;
          final lift = bend * 4 * t * (1 - t);
          return a + d * t + normal * (lift + _w(1.2)) + (mid - mid);
        }(),
    ];
  }

  /// A line from [a] to [b] with an arrowhead of two short lines (as one stroke) or none.
  DrawingStroke line(Offset a, Offset b, {bool head = false, bool headAsStrokes = false, double bend = 0}) {
    final p = _line(a, b, bend: bend);
    if (head && !headAsStrokes) {
      final u = (b - p[p.length - 3]) / (b - p[p.length - 3]).distance;
      Offset barb(double angle) => b - Offset(u.dx * math.cos(angle) - u.dy * math.sin(angle), u.dx * math.sin(angle) + u.dy * math.cos(angle)) * 12;
      p.addAll([barb(0.5), b, barb(-0.5)]);
    }
    final s = add(p);
    if (head && headAsStrokes) {
      final u = (b - p[p.length - 3]) / (b - p[p.length - 3]).distance;
      Offset barb(double angle) => b - Offset(u.dx * math.cos(angle) - u.dy * math.sin(angle), u.dx * math.sin(angle) + u.dy * math.cos(angle)) * 12;
      add([barb(0.5), b, barb(-0.5)]);
    }
    return s;
  }

  /// A piece of writing of [text] centred on [at] (a squiggle; the reading of it is [says]).
  void write(String text, Offset at) {
    final s = add([for (var i = 0; i < 8; i++) at + Offset(-6 + i * 1.7, math.sin(i * 1.3) * 5)]);
    says[s.id] = text;
  }

  Future<String> read(List<DrawingStroke> s) async => ([...s]..sort((a, b) => a.points.first.dx.compareTo(b.points.first.dx))).map((x) => says[x.id] ?? '?').join();
}

void main() {
  group('a state diagram', () {
    Pen scene(int seed) {
      final pen = Pen(seed);
      // q0 -a-> q1 -b-> q2, a loop on q2, q2 back to q0, an arrow from nowhere into q0, q2 with two rings
      pen.circle(const Offset(150, 200), 30);
      pen.circle(const Offset(350, 200), 30, turns: 1.1, from: 2.0);
      pen.circle(const Offset(550, 200), 30);
      pen.circle(const Offset(550, 200), 24, from: 3.0);
      pen.write('q0', const Offset(150, 200));
      pen.write('q1', const Offset(350, 200));
      pen.write('q2', const Offset(550, 200));
      pen.line(const Offset(60, 200), const Offset(119, 200), head: true);
      pen.line(const Offset(181, 200), const Offset(318, 200), head: true);
      pen.write('a', const Offset(250, 180));
      pen.line(const Offset(382, 200), const Offset(518, 200), head: true, headAsStrokes: true);
      pen.write('b', const Offset(450, 180));
      pen.circle(const Offset(550, 148), 17); // the loop on q2, drawn as a small circle on top
      pen.write('a,b', const Offset(550, 120));
      pen.line(const Offset(540, 232), const Offset(160, 232), head: true, bend: -90);
      pen.write('c', const Offset(350, 290));
      return pen;
    }

    late Pen pen;
    setUp(() => pen = scene(4));

    test('is read from its circles, arrows and writing', () async {
      final r = await readInkDiagram(pen.strokes, pen.read);
      expect(r.mode, DiagramMode.automaton);
      final a = parseAutomaton(r.text).automaton;
      expect(a.states.toSet(), {'q0', 'q1', 'q2'});
      expect(a.start, 'q0');
      expect(a.accepting, {'q2'});
      String t(Transition x) => '${x.from}-${x.symbols.join(',')}->${x.to}';
      expect(a.transitions.map(t).toSet(), {'q0-a->q1', 'q1-b->q2', 'q2-a,b->q2', 'q2-c->q0'});
    });

    test('holds for many hands (different wobble)', () async {
      var good = 0;
      for (var seed = 1; seed <= 40; seed++) {
        final hand = scene(seed);
        final r = await readInkDiagram(hand.strokes, hand.read);
        final a = parseAutomaton(r.text).automaton;
        if (a.start == 'q0' && a.accepting.length == 1 && a.transitions.length == 4) good++;
      }
      expect(good, greaterThanOrEqualTo(38), reason: '$good of 40');
    });

    test('a name that cannot be read is numbered, and a reading that fails is told', () async {
      final r = await readInkDiagram(pen.strokes, (s) async => throw StateError('no model'));
      final a = parseAutomaton(r.text).automaton;
      expect(a.states.toSet(), {'q0', 'q1', 'q2'}, reason: 'numbered from the left');
      expect(a.accepting, {'q2'});
      expect(r.notes.single.$2, {'n': 3, 'all': 3});
    });
  });

  group('a tree', () {
    test('lines between circles, the highest one the root, children from left to right', () async {
      final pen = Pen();
      final at = {'8': const Offset(300, 100), '3': const Offset(180, 220), '10': const Offset(420, 220), '1': const Offset(110, 340), '6': const Offset(250, 340)};
      for (final e in at.entries) {
        pen.circle(e.value, 28);
        pen.write(e.key, e.value);
      }
      Offset edge(Offset from, Offset to, double r) => from + (to - from) / (to - from).distance * r;
      for (final (p, c) in [('8', '3'), ('8', '10'), ('3', '1'), ('3', '6')]) {
        pen.line(edge(at[p]!, at[c]!, 30), edge(at[c]!, at[p]!, 30));
      }
      final r = await readInkDiagram(pen.strokes, pen.read);
      expect(r.mode, DiagramMode.tree);
      expect(r.text, '8(3(1,6),10)');
      expect(parseTree(r.text).tree.size, 5);
    });

    test('a child drawn on one side only keeps its side', () async {
      final pen = Pen();
      final at = {'A': const Offset(300, 100), 'B': const Offset(400, 230)};
      for (final e in at.entries) {
        pen.circle(e.value, 28);
        pen.write(e.key, e.value);
      }
      pen.line(const Offset(315, 126), const Offset(385, 204));
      final r = await readInkDiagram(pen.strokes, pen.read);
      expect(r.text, 'A(,B)');
    });
  });

  group('a graph', () {
    test('circles with weighted lines, and arrows when they have heads', () async {
      for (final directed in [false, true]) {
        final pen = Pen();
        final at = {'A': const Offset(100, 100), 'B': const Offset(400, 100), 'C': const Offset(250, 320)};
        for (final e in at.entries) {
          pen.circle(e.value, 28);
          pen.write(e.key, e.value);
        }
        Offset edge(Offset from, Offset to, double r) => from + (to - from) / (to - from).distance * r;
        void join(String a, String b, String w) {
          pen.line(edge(at[a]!, at[b]!, 31), edge(at[b]!, at[a]!, 31), head: directed);
          pen.write(w, (at[a]! + at[b]!) / 2 + const Offset(0, -16));
        }

        join('A', 'B', '4');
        join('B', 'C', '2');
        join('C', 'A', '1');
        final r = await readInkDiagram(pen.strokes, pen.read);
        expect(r.mode, DiagramMode.graph);
        final g = parseGraph(r.text).graph;
        expect(g.nodes.toSet(), {'A', 'B', 'C'});
        expect(g.edges.map((e) => '${e.from}${e.to}${e.weight}').toSet(), {'AB4.0', 'BC2.0', 'CA1.0'});
        expect(g.hasDirected, directed);
      }
    });
  });

  test('what the formula reader writes for a name is made plain', () {
    const reads = {
      'q_{0}': 'q0', 'q0.': 'q0', 'qO': 'q0', 'sl.': 's1', r'\mboxql': 'q1', r'\mathrm{A}': 'A', 'a, b': 'a,b', r'\circ': '0', 'x.': 'x', '12': '12', ' 0.1 ': '0.1',
    };
    for (final e in reads.entries) {
      expect(tidyDiagramLabel(e.key), e.value, reason: e.key);
    }
  });

  group('what is not a diagram', () {
    test('writing and a lone line make nothing', () async {
      final pen = Pen();
      pen.write('hello', const Offset(100, 100));
      pen.line(const Offset(10, 10), const Offset(200, 10));
      final r = await readInkDiagram(pen.strokes, pen.read);
      expect(r.isEmpty, isTrue);
    });

    test('a small o inside a circle is its name, not another state', () async {
      final pen = Pen();
      pen.circle(const Offset(100, 100), 30);
      pen.circle(const Offset(100, 100), 9); // a "0"
      pen.circle(const Offset(300, 100), 30);
      pen.write('1', const Offset(300, 100));
      pen.line(const Offset(131, 100), const Offset(268, 100), head: true);
      final sketch = readSketch(pen.strokes);
      expect(sketch.nodes, hasLength(2));
      expect(sketch.nodes.first.accepting, isFalse);
      expect(sketch.nodes.first.label, hasLength(1));
    });
  });
}
