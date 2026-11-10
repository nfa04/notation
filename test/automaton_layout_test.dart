import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/diagram/automaton.dart';
import 'package:notes/diagram/automaton_layout.dart';
import 'package:notes/diagram/diagram_layout.dart';

void main() {
  DiagramLayout layout(String text) => layoutAutomaton(parseAutomaton(text).automaton);

  bool finite(DiagramLayout l) =>
      l.size.width.isFinite && l.size.height.isFinite && l.lines.every((x) => x.points.every((p) => p.dx.isFinite && p.dy.isFinite)) && l.boxes.every((b) => b.rect.isFinite);

  test('a state for each box, a ring for each accepting state, an arrow into the start', () {
    final l = layout('''
start: q0
accept: q2
q0 -a-> q1
q1 -b-> q2
q2 -a-> q2
q1 -a-> q0
''');
    expect(l.boxes.map((b) => b.text).toSet(), {'q0', 'q1', 'q2'});
    // arrows: 4 transitions + the ring of q2 + the arrow into q0
    expect(l.lines.length, 6);
    expect(l.labels.map((x) => x.text).toSet(), {'a', 'b'});
    expect(finite(l), isTrue);
  });

  test('the states are in columns from the start, to the right', () {
    final l = layout('>q0 -a-> q1\nq1 -a-> q2\nq2 -a-> *q3');
    final x = {for (final b in l.boxes) b.text: b.rect.center.dx};
    expect(x['q0']! < x['q1']!, isTrue);
    expect(x['q1']! < x['q2']!, isTrue);
    expect(x['q2']! < x['q3']!, isTrue);
  });

  test('no box lies on another', () {
    final l = layout('>s -a-> p\ns -b-> q\ns -c-> r\np -a-> t\nq -a-> t\nr -a-> t\nt -a-> s');
    for (var i = 0; i < l.boxes.length; i++) {
      for (var j = i + 1; j < l.boxes.length; j++) {
        expect(l.boxes[i].rect.overlaps(l.boxes[j].rect), isFalse, reason: '${l.boxes[i].text} ${l.boxes[j].text}');
      }
    }
  });

  test('two arrows between the same states do not lie on each other', () {
    final l = layout('>a -x-> b\nb -y-> a');
    final first = l.lines[0].points, second = l.lines[1].points;
    final mid1 = first[first.length ~/ 2 - 1], mid2 = second[second.length ~/ 2 - 1];
    expect((mid1 - mid2).distance > 10, isTrue);
  });

  test('states that nothing leads to are put at the end, in grey', () {
    final l = layout('>q0 -a-> *q1\nlost -a-> q0');
    final lost = l.boxes.firstWhere((b) => b.text == 'lost');
    expect(lost.rect.center.dx > l.boxes.firstWhere((b) => b.text == 'q1').rect.center.dx, isTrue);
  });

  test('a long name is a wide box, and the line comes to its edge', () {
    final l = layout('>{q0,q1} -a-> {q0,q1,q2}');
    expect(l.boxes.every((b) => b.rect.width > 52), isTrue);
    expect(finite(l), isTrue);
  });

  test('without a start state, and with nothing', () {
    expect(finite(layout('q0 -a-> q1')), isTrue);
    expect(layout('').isEmpty, isTrue);
    expect(finite(layout('q0')), isTrue);
  });

  test('the top left is at the margin', () {
    final l = layout('>q0 -a-> q0');
    final left = l.boxes.map((b) => b.rect.left).reduce((a, b) => a < b ? a : b);
    expect(left >= 0, isTrue);
    expect(l.size.width > 0 && l.size.height > 0, isTrue);
    for (final b in l.boxes) {
      expect(Rect.fromLTWH(0, 0, l.size.width, l.size.height).contains(b.rect.center), isTrue);
    }
  });
}
