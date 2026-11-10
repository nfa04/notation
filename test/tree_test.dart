import 'package:flutter_test/flutter_test.dart';
import 'package:notes/diagram/tree.dart';
import 'package:notes/diagram/tree_layout.dart';

Tree parse(String text) => parseTree(text).tree;
String show(TreeNode? n) {
  if (n == null) return '';
  final kids = [...n.children];
  while (kids.isNotEmpty && kids.last == null) {
    kids.removeLast();
  }
  return kids.isEmpty ? n.label : '${n.label}(${kids.map(show).join(',')})';
}
String shape(Tree t) => show(t.root);

void main() {
  group('brackets', () {
    test('a tree with any number of children', () {
      final t = parse('A(B(D,E),C,F(G))');
      expect(t.size, 7);
      expect(t.height, 2);
      expect(t.binary, isFalse);
      expect(shape(t), 'A(B(D,E),C,F(G))');
    });

    test('a hole makes it a binary tree', () {
      final t = parse('8(3(1,6(4,7)),10(,14(13,)))');
      expect(t.binary, isTrue);
      expect(shape(t), '8(3(1,6(4,7)),10(,14(13)))');
      expect(t.root!.children[1]!.children[0], isNull);
    });

    test('names with spaces, one node, nothing, and mistakes', () {
      expect(parse('root node(left one, right one)').root!.label, 'root node');
      expect(parse('x').size, 1);
      expect(parse('').isEmpty, isTrue);
      final r = parseTree('A(B,C');
      expect(r.problems, isNotEmpty);
      expect(r.tree.size, 3);
      expect(parseTree('A(B) C').problems, isNotEmpty);
    });
  });

  group('search trees', () {
    test('numbers are inserted one after the other', () {
      final t = parse('bst: 8 3 10 1 6 14 4 7 13');
      expect(inorder(t), ['1', '3', '4', '6', '7', '8', '10', '13', '14']);
      expect(preorder(t), ['8', '3', '1', '6', '4', '7', '10', '14', '13']);
      expect(postorder(t), ['1', '4', '7', '6', '3', '13', '14', '10', '8']);
      expect(levelorder(t), ['8', '3', '10', '1', '6', '14', '4', '7', '13']);
      expect(t.height, 3);
      expect(t.binary, isTrue);
    });

    test('a number is only in the tree once; text is compared as text', () {
      expect(parse('bst: 5 3 5 3').size, 2);
      expect(inorder(parse('bst: pear apple fig')), ['apple', 'fig', 'pear']);
      expect(inorder(parse('bst: 10 9 100 2')), ['2', '9', '10', '100']); // (numbers, not text: 100 is after 10)
    });

    test('operations after the first line', () {
      expect(inorder(parse('bst: 5 3 8 1 4\ninsert 6 7\ndelete 3')), ['1', '4', '5', '6', '7', '8']);
      // a node with two children: the next larger one takes its place
      final t = parse('bst: 5 3 8 7 9\ndelete 8');
      expect(shape(t), '5(3,9(7))');
      expect(parse('bst: 5\ndelete 5').isEmpty, isTrue);
      expect(parseTree('bst: 5\nfrobnicate').problems, ['line 2: frobnicate']);
    });
  });

  group('AVL trees', () {
    test('the rotations keep it balanced', () {
      final t = parse('avl: 1 2 3 4 5 6 7');
      expect(shape(t), '4(2(1,3),6(5,7))');
      expect(t.height, 2);
    });

    test('all four cases', () {
      expect(shape(parse('avl: 3 2 1')), '2(1,3)'); // left left
      expect(shape(parse('avl: 1 2 3')), '2(1,3)'); // right right
      expect(shape(parse('avl: 3 1 2')), '2(1,3)'); // left right
      expect(shape(parse('avl: 1 3 2')), '2(1,3)'); // right left
    });

    test('a sorted list stays shallow, and deleting rebalances', () {
      final t = parse('avl: ${List.generate(31, (i) => i + 1).join(' ')}');
      expect(t.height, 4);
      expect(balanceFactors(t).values.every((b) => b.abs() <= 1), isTrue);
      final d = parse('avl: 1 2 3 4 5\ndelete 1\ndelete 2');
      expect(balanceFactors(d).values.every((b) => b.abs() <= 1), isTrue);
      expect(inorder(d), ['3', '4', '5']);
    });

    test('a plain search tree does not rotate', () {
      expect(parse('bst: 1 2 3 4 5').height, 4);
    });
  });

  group('heaps', () {
    test('a min-heap is built by inserting', () {
      final t = parse('minheap: 5 3 8 1 9 2');
      expect(levelorder(t), ['1', '3', '2', '5', '9', '8']);
      expect(treeFacts(t).firstWhere((f) => f.$1 == 'Min-heap').$2, 'yes');
    });

    test('a max-heap, and what happens next', () {
      final t = parse('maxheap: 5 3 8 1\ninsert 9\nextract');
      expect(levelorder(t), ['8', '3', '5', '1']);
    });

    test('a tree from an array', () {
      final t = parse('array: 1 3 2 5 4 - 6');
      expect(levelorder(t), ['1', '3', '2', '5', '4', '6']);
      expect(shape(t), '1(3(5,4),2(,6))');
      expect(treeFacts(t).firstWhere((f) => f.$1 == 'Min-heap').$2, 'no'); // (a hole: not complete)
      expect(treeFacts(parse('array: 1 3 2 5 4')).firstWhere((f) => f.$1 == 'Min-heap').$2, 'yes');
      expect(parseTree('array: - 1 2').problems, isNotEmpty);
    });
  });

  group('facts', () {
    String fact(Tree t, String name) => treeFacts(t).firstWhere((f) => f.$1 == name).$2;

    test('shapes', () {
      expect(fact(parse('bst: 4 2 6 1 3 5 7'), 'Shape'), 'full, complete, perfect');
      expect(fact(parse('bst: 4 2 6 1'), 'Shape'), 'complete');
      expect(fact(parse('bst: 1 2 3'), 'Shape'), '—');
    });

    test('search tree and balance', () {
      expect(fact(parse('bst: 4 2 6'), 'Search tree'), 'yes');
      expect(fact(parse('4(6,2)'), 'Search tree'), 'no');
      expect(fact(parse('bst: 1 2 3'), 'Balanced (AVL)'), 'no');
      expect(fact(parse('avl: 1 2 3'), 'Balanced (AVL)'), 'yes');
    });

    test('counts and walks', () {
      final t = parse('A(B(D,E),C)');
      expect(fact(t, 'Nodes'), '5');
      expect(fact(t, 'Leaves'), '3');
      expect(fact(t, 'Preorder'), 'A B D E C');
      expect(fact(t, 'Postorder'), 'D E B C A');
      expect(fact(t, 'Inorder'), 'D B E A C');
      expect(fact(t, 'Level order'), 'A B C D E');
    });

    test('a tree with more than two children has no inorder', () {
      expect(treeFacts(parse('A(B,C,D)')).any((f) => f.$1 == 'Inorder'), isFalse);
      expect(treeFacts(parse('')), isEmpty);
    });
  });

  group('layout', () {
    test('a node under its parent, the left one on the left', () {
      final l = layoutTree(parse('bst: 4 2 6 1 3 5 7'));
      expect(l.boxes.length, 7);
      expect(l.lines.length, 6);
      final at = {for (final b in l.boxes) b.text: b.rect.center};
      expect(at['4']!.dy < at['2']!.dy, isTrue);
      expect(at['2']!.dx < at['4']!.dx && at['4']!.dx < at['6']!.dx, isTrue);
      expect(at['1']!.dx < at['3']!.dx, isTrue);
      expect((at['4']!.dx - (at['2']!.dx + at['6']!.dx) / 2).abs() < 1, isTrue);
    });

    test('no box lies on another', () {
      for (final text in ['bst: 8 3 10 1 6 14 4 7 13', 'A(B(D,E,F),C(G),H)', 'avl: 1 2 3 4 5 6 7 8 9 10', 'minheap: 9 8 7 6 5 4 3 2 1']) {
        final l = layoutTree(parse(text));
        for (var i = 0; i < l.boxes.length; i++) {
          for (var j = i + 1; j < l.boxes.length; j++) {
            expect(l.boxes[i].rect.overlaps(l.boxes[j].rect), isFalse, reason: '$text ${l.boxes[i].text} ${l.boxes[j].text}');
          }
        }
      }
    });

    test('a general tree is centred over its children', () {
      final l = layoutTree(parse('A(B,C,D)'));
      final at = {for (final b in l.boxes) b.text: b.rect.center};
      expect((at['A']!.dx - at['C']!.dx).abs() < 1, isTrue);
    });

    test('balance factors beside the nodes', () {
      final l = layoutTree(parse('bst: 1 2 3'), balance: true);
      expect(l.labels.map((x) => x.text), ['-2', '-1', '0']);
    });

    test('nothing', () {
      expect(layoutTree(parse('')).isEmpty, isTrue);
    });
  });
}
