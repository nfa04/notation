import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/diagram/diagram.dart';
import 'package:notes/diagram/diagram_layout.dart';

List<String> labels(Diagram d) => [for (final n in d.nodes) n.label];
List<(String, String)> pairs(Diagram d) => [for (final e in d.edges) (d.nodes[e.from].label, d.nodes[e.to].label)];

void main() {
  group('outlines', () {
    test('a nested list under one top entry is a tree with that entry as its centre', () {
      final d = parseOutline('- Plants\n  - Roots\n    - Water\n  - Leaves\n- Animals'.replaceFirst('- Animals', ''));
      expect(d.kind, DiagramKind.mindMap);
      expect(labels(d), ['Plants', 'Roots', 'Water', 'Leaves']);
      expect(pairs(d), [('Plants', 'Roots'), ('Roots', 'Water'), ('Plants', 'Leaves')]);
      expect(d.nodes.map((n) => n.depth), [0, 1, 2, 1]);
    });

    test('several top entries get a centre of their own, named by the note', () {
      final d = parseOutline('- Plants\n- Animals\n  - Mammals', rootTitle: 'Biology');
      expect(labels(d), ['Biology', 'Plants', 'Animals', 'Mammals']);
      expect(pairs(d), [('Biology', 'Plants'), ('Biology', 'Animals'), ('Animals', 'Mammals')]);
      expect(parseOutline('- a\n- b').nodes.first.label, 'Mind map');
    });

    test('headings nest, and the list under a heading nests below it', () {
      final d = parseOutline('# Biology\n## Cells\n- Nucleus\n- Membrane\n## Genes\n1. DNA\n2. RNA');
      expect(pairs(d), [('Biology', 'Cells'), ('Cells', 'Nucleus'), ('Cells', 'Membrane'), ('Biology', 'Genes'), ('Genes', 'DNA'), ('Genes', 'RNA')]);
    });

    test('marks, tick boxes, code blocks and blank lines are not part of the words', () {
      final d = parseOutline('- **Bold** and `code`\n  - [x] done\n\n```\n- not an entry\n```\n  - [ ] open');
      expect(labels(d), ['Bold and code', 'done', 'open']);
    });

    test('an entry that starts too deep is brought up to the level under the one before it', () {
      final d = parseOutline('- A\n      - deep\n  - B');
      expect(pairs(d), [('A', 'deep'), ('A', 'B')]);
    });

    test('nothing in gives nothing out', () {
      expect(parseOutline('').isEmpty, isTrue);
      expect(parseOutline('\n  \n```\ncode\n```').isEmpty, isTrue);
    });
  });

  group('flowcharts', () {
    test('arrows make a chain, a text is one box wherever it comes up', () {
      final d = parseFlow('Start -> Read input -> Valid?\nValid? -> Save : yes\nValid? -> Ask again : no\nAsk again -> Read input');
      expect(d.kind, DiagramKind.flow);
      expect(labels(d), ['Start', 'Read input', 'Valid?', 'Save', 'Ask again']);
      expect(pairs(d), [('Start', 'Read input'), ('Read input', 'Valid?'), ('Valid?', 'Save'), ('Valid?', 'Ask again'), ('Ask again', 'Read input')]);
      expect(d.edges[2].label, 'yes');
      expect(d.edges[3].label, 'no');
      expect(d.edges[0].label, isNull);
      expect(d.nodes[2].decision, isTrue);
      expect(d.nodes[1].decision, isFalse);
    });

    test('the arrow can be written several ways; a lone text is a box; a repeated arrow is one edge', () {
      final d = parseFlow('A --> B\nB => C\nLonely\nA -> B');
      expect(labels(d), ['A', 'B', 'C', 'Lonely']);
      expect(d.edges.length, 2);
    });

    test('the kind is told from the arrows', () {
      expect(parseDiagram('A -> B').kind, DiagramKind.flow);
      expect(parseDiagram('- A\n  - B').kind, DiagramKind.mindMap);
      expect(looksLikeFlow('- note about x -> y'), isTrue);
      expect(looksLikeFlow('just -> '), isFalse);
    });
  });

  group('layout', () {
    bool overlap(Rect a, Rect b) => a.overlaps(b.deflate(0.5));

    test('a mind map has its centre in the middle and the branches on both sides, without boxes on top of each other', () {
      final d = parseOutline('- Plants\n  - Roots\n    - Water\n    - Minerals\n  - Leaves\n    - Light\n  - Stem\n  - Flowers\n    - Petals\n    - Pollen', rootTitle: 'x');
      final l = layoutMindMap(d);
      expect(l.boxes.length, d.nodes.length);
      final byNode = {for (final b in l.boxes) b.node: b};
      final root = byNode[0]!;
      final rightOf = [for (final c in d.childrenOf(0)) if (byNode[c]!.rect.center.dx > root.rect.center.dx) c];
      final leftOf = [for (final c in d.childrenOf(0)) if (byNode[c]!.rect.center.dx < root.rect.center.dx) c];
      expect(rightOf, isNotEmpty);
      expect(leftOf, isNotEmpty);
      for (final c in rightOf) {
        expect(byNode[c]!.rect.left, greaterThan(root.rect.right));
      }
      for (final c in leftOf) {
        expect(byNode[c]!.rect.right, lessThan(root.rect.left));
      }
      for (var i = 0; i < l.boxes.length; i++) {
        for (var j = i + 1; j < l.boxes.length; j++) {
          expect(overlap(l.boxes[i].rect, l.boxes[j].rect), isFalse, reason: '${l.boxes[i].text} / ${l.boxes[j].text}');
        }
      }
      expect(l.lines.length, d.edges.length);
      expect(l.size.width, greaterThan(300));
      expect(l.boxes.every((b) => b.rect.left >= -0.01 && b.rect.top >= -0.01 && b.rect.right <= l.size.width + 0.01 && b.rect.bottom <= l.size.height + 0.01), isTrue);
      // the first branch has a colour of its own
      expect(byNode[d.childrenOf(0)[0]]!.border, isNot(byNode[d.childrenOf(0)[1]]!.border));
      // a child is the colour of its branch
      expect(byNode[2]!.border, byNode[1]!.border);
    });

    test('the two sides of a mind map are about as tall as each other', () {
      final d = parseOutline([for (var i = 0; i < 8; i++) '- Branch $i\n  - a\n  - b'].join('\n'), rootTitle: 'x');
      final l = layoutMindMap(d);
      final root = l.boxes.firstWhere((b) => b.node == 0);
      final right = l.boxes.where((b) => b.rect.center.dx > root.rect.center.dx).length;
      final left = l.boxes.where((b) => b.rect.center.dx < root.rect.center.dx).length;
      expect((right - left).abs(), lessThanOrEqualTo(3));
    });

    test('a flowchart goes downwards: every arrow ends below where it starts, boxes do not touch, labels are on their arrows', () {
      final d = parseFlow('Start -> Read -> Valid?\nValid? -> Save : yes\nValid? -> Read : no\nSave -> End');
      final l = layoutFlow(d);
      final byNode = {for (final b in l.boxes) b.node: b};
      int id(String t) => d.nodes.firstWhere((n) => n.label == t).id;
      expect(byNode[id('Read')]!.rect.top, greaterThanOrEqualTo(byNode[id('Start')]!.rect.bottom));
      expect(byNode[id('Valid?')]!.rect.top, greaterThanOrEqualTo(byNode[id('Read')]!.rect.bottom));
      expect(byNode[id('Save')]!.rect.top, greaterThanOrEqualTo(byNode[id('Valid?')]!.rect.bottom));
      expect(byNode[id('End')]!.rect.top, greaterThanOrEqualTo(byNode[id('Save')]!.rect.bottom));
      for (var i = 0; i < l.boxes.length; i++) {
        for (var j = i + 1; j < l.boxes.length; j++) {
          expect(overlap(l.boxes[i].rect, l.boxes[j].rect), isFalse);
        }
      }
      expect(l.lines.length, 5);
      expect(l.labels.map((x) => x.text), ['yes', 'no']);
      // the arrow that goes back (no: Read) leaves on the right and is drawn to the right of every box
      final backLine = l.lines.firstWhere((x) => x.points.first.dx > byNode[id('Valid?')]!.rect.right - 1 && x.points.length >= 4 && x.points[1].dx > byNode[id('Valid?')]!.rect.right);
      expect(backLine.points[1].dx, greaterThan(l.boxes.map((b) => b.rect.right).reduce((a, b) => a > b ? a : b)));
    });

    test('boxes of one row are side by side and the row is centred', () {
      final l = layoutFlow(parseFlow('A -> B\nA -> C\nA -> D'));
      final row = l.boxes.where((b) => b.text != 'A').toList()..sort((a, b) => a.rect.left.compareTo(b.rect.left));
      expect(row.length, 3);
      expect(row.map((b) => b.rect.top).toSet().length, 1);
      final a = l.boxes.firstWhere((b) => b.text == 'A');
      expect((a.rect.center.dx - (row.first.rect.left + row.last.rect.right) / 2).abs(), lessThan(1));
    });

    test('a diagram with a cycle and nodes only in cycles still gets every box', () {
      final l = layoutFlow(parseFlow('A -> B\nB -> C\nC -> A'));
      expect(l.boxes.length, 3);
      expect(l.lines.length, 3);
    });

    test('a layout is scaled down to fit and never up', () {
      final l = layoutMindMap(parseOutline([for (var i = 0; i < 6; i++) '- B$i\n  - c\n    - d'].join('\n'), rootTitle: 'x'));
      final fitted = l.fitted(500);
      expect(fitted.size.width, lessThanOrEqualTo(501));
      expect(fitted.boxes.first.fontSize, lessThan(l.boxes.first.fontSize));
      expect(l.fitted(100000).size, l.size);
      // not smaller than the least scale
      expect(l.fitted(10).size.width, closeTo(l.size.width * 0.45, 0.01));
    });

    test('empty diagrams lay out as nothing', () {
      expect(layoutDiagram(parseOutline('')).isEmpty, isTrue);
      expect(layoutFlow(const Diagram(DiagramKind.flow, [], [])).isEmpty, isTrue);
    });

    test('label wrapping keeps words whole', () {
      expect(wrapLabel('the quick brown fox jumps', 10), ['the quick', 'brown fox', 'jumps']);
      expect(wrapLabel('extraordinarilylongword short', 10), ['extraordinarilylongword', 'short']);
      expect(wrapLabel('', 10), ['']);
      final big = boxSize('a much longer label that needs several lines to be shown properly');
      final small = boxSize('Hi');
      expect(big.height, greaterThan(small.height));
      expect(small.width, 90);
    });
  });
}
