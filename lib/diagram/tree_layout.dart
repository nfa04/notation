import 'dart:math' as math;
import 'dart:ui';

import 'diagram_layout.dart';
import 'node_link.dart';
import 'tree.dart';

const _rootColors = (Color(0xFFE8F5E9), Color(0xFF43A047));
const _innerColors = (Color(0xFFE3F2FD), Color(0xFF1E88E5));
const _leafColors = (Color(0xFFFFF3E0), Color(0xFFFB8C00));

/// A tree drawn from the top: the root above, every level below the one before. In a binary tree a node stands between its left and its right subtree
/// (in order from left to right); in other trees a node stands over the middle of its children. With [balance] every node has its balance factor beside it.
DiagramLayout layoutTree(Tree t, {bool balance = false}) {
  final root = t.root;
  if (root == null) return const DiagramLayout([], [], [], Size.zero);
  final ids = <TreeNode, int>{};
  final nodes = <TreeNode>[];
  final depth = <TreeNode, int>{};
  void collect(TreeNode n, int d) {
    ids[n] = nodes.length;
    nodes.add(n);
    depth[n] = d;
    for (final k in n.kids) {
      collect(k, d + 1);
    }
  }

  collect(root, 0);

  // the place of each node along the row
  final x = <TreeNode, double>{};
  if (t.binary) {
    var next = 0.0;
    void walk(TreeNode? n) {
      if (n == null) return;
      walk(n.children.isNotEmpty ? n.children[0] : null);
      x[n] = next++;
      for (final k in n.children.skip(1)) {
        walk(k);
      }
    }

    walk(root);
  } else {
    var leaf = 0.0;
    void walk(TreeNode n) {
      if (n.isLeaf) {
        x[n] = leaf++;
        return;
      }
      for (final k in n.kids) {
        walk(k);
      }
      x[n] = (x[n.kids.first]! + x[n.kids.last]!) / 2;
    }

    walk(root);
  }

  final widest = nodes.map((n) => nodeWidth(n.label, minDiameter: 44)).reduce(math.max);
  final gapX = widest + 16, gapY = 78.0;
  final shapes = [for (final n in nodes) NodeShape(Offset(x[n]! * gapX, depth[n]! * gapY), nodeWidth(n.label, minDiameter: 44) / 2, 22)];
  final factors = balance ? balanceFactors(t) : const <TreeNode, int>{};

  final boxes = <PlacedBox>[];
  final lines = <PlacedLine>[];
  final labels = <PlacedLabel>[];
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    final (fill, border) = i == 0 ? _rootColors : (n.isLeaf ? _leafColors : _innerColors);
    boxes.add(PlacedBox(node: i, rect: shapes[i].rect, text: n.label, fill: fill, border: border, bold: i == 0, radius: shapes[i].ry));
    if (balance) {
      final b = factors[n] ?? 0;
      labels.add(PlacedLabel(shapes[i].center + Offset(shapes[i].rx + 12, -shapes[i].ry), b > 0 ? '+$b' : '$b'));
    }
    for (final k in n.kids) {
      final j = ids[k]!;
      final a = shapes[i], b = shapes[j];
      lines.add(PlacedLine([a.edgeToward(b.center), b.edgeToward(a.center)], const Color(0xFF546E7A), width: 2.2));
    }
  }
  return framed(boxes, lines, labels);
}
