// Trees for the advanced diagrams: read from text, built by inserting numbers (a search tree, an AVL tree, a heap), and told about.
//
// The text is one of:
//   A(B(D,E),C)            a tree, each node with its children in brackets; an empty place stays empty: 8(3(1,),10(,14)) is a binary tree
//   bst: 8 3 10 1 6 14     the numbers inserted one after the other into a binary search tree
//   avl: 1 2 3 4 5 6       the same with rotations, so that the tree stays balanced
//   minheap: 5 3 8 1       the numbers inserted into a heap (maxheap: too)
//   array: 1 3 2 - 5       a tree from its level order: the first is the root, then two for each node, - is a hole
// and for a search tree or a heap the lines after the first say what happens next: `insert 7`, `delete 3` (a heap: `extract`).

class TreeNode {
  String label;
  List<TreeNode?> children;

  TreeNode(this.label, [List<TreeNode?>? children]) : children = children ?? [];

  /// The nodes below, left to right (not the holes of a binary tree).
  Iterable<TreeNode> get kids => children.whereType<TreeNode>();

  bool get isLeaf => kids.isEmpty;
}

class Tree {
  final TreeNode? root;

  /// Whether the places of the children matter (left and right): then a node with one child has a hole.
  final bool binary;

  /// What kind of tree it is, as read: `tree`, `bst`, `avl`, `minheap`, `maxheap`, `array`.
  final String kind;

  const Tree(this.root, this.binary, this.kind);

  bool get isEmpty => root == null;

  /// How many nodes.
  int get size => _count(root);

  static int _count(TreeNode? n) => n == null ? 0 : 1 + n.kids.fold(0, (s, k) => s + _count(k));

  /// The most edges from the root down to a node; -1 for no tree.
  int get height => _height(root);

  static int _height(TreeNode? n) => n == null ? -1 : 1 + n.kids.fold(-1, (m, k) => _height(k) > m ? _height(k) : m);
}

class TreeReading {
  final Tree tree;
  final List<String> problems;

  const TreeReading(this.tree, this.problems);
}

/// A number when [s] is one, else null.
num? _number(String s) => num.tryParse(s.trim());

int _compare(String a, String b) {
  final x = _number(a), y = _number(b);
  if (x != null && y != null) return x.compareTo(y);
  return a.compareTo(b);
}

// ---- a tree from brackets ----

TreeReading _fromBrackets(String text) {
  final s = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  var i = 0;
  final problems = <String>[];
  var sawHole = false;

  // a node: its label, and its children in brackets
  TreeNode? node() {
    final start = i;
    while (i < s.length && !'(),'.contains(s[i])) {
      i++;
    }
    final label = s.substring(start, i).trim();
    if (label.isEmpty) {
      if (i < s.length && s[i] == '(') problems.add('a node has no name before "("');
      return null;
    }
    final out = TreeNode(label);
    if (i < s.length && s[i] == '(') {
      i++;
      while (true) {
        final child = node();
        if (child == null) sawHole = true;
        out.children.add(child);
        if (i < s.length && s[i] == ',') {
          i++;
          continue;
        }
        break;
      }
      if (i < s.length && s[i] == ')') {
        i++;
      } else {
        problems.add('a bracket is not closed');
      }
    }
    // trailing holes are not holes: A(B) is one child
    while (out.children.isNotEmpty && out.children.last == null) {
      out.children.removeLast();
    }
    return out;
  }

  final root = node();
  if (i < s.length) problems.add('what follows "${s.substring(i)}" is not part of the tree');
  // (a hole says that left and right matter: 8(3(1,),10(,14)); without holes a single child is simply the only one)
  return TreeReading(Tree(root, sawHole && _onlyTwo(root), 'tree'), problems);
}

bool _onlyTwo(TreeNode? n) => n == null || n.children.length <= 2 && n.kids.every(_onlyTwo);

// ---- a binary search tree, with and without rotations ----

TreeNode _bstInsert(TreeNode? n, String v) {
  if (n == null) return TreeNode(v, [null, null]);
  final c = _compare(v, n.label);
  if (c == 0) return n; // (a number is in the tree once)
  if (c < 0) {
    n.children[0] = _bstInsert(n.children[0], v);
  } else {
    n.children[1] = _bstInsert(n.children[1], v);
  }
  return n;
}

TreeNode? _min(TreeNode n) => n.children[0] == null ? n : _min(n.children[0]!);

TreeNode? _bstDelete(TreeNode? n, String v) {
  if (n == null) return null;
  final c = _compare(v, n.label);
  if (c < 0) {
    n.children[0] = _bstDelete(n.children[0], v);
  } else if (c > 0) {
    n.children[1] = _bstDelete(n.children[1], v);
  } else {
    final l = n.children[0], r = n.children[1];
    if (l == null) return r;
    if (r == null) return l;
    // (the next larger one takes its place)
    final next = _min(r)!;
    n.label = next.label;
    n.children[1] = _bstDelete(r, next.label);
  }
  return n;
}

int _h(TreeNode? n) => n == null ? 0 : 1 + (_h(n.children[0]) > _h(n.children[1]) ? _h(n.children[0]) : _h(n.children[1]));

int _balance(TreeNode n) => _h(n.children[0]) - _h(n.children[1]);

TreeNode _rotateRight(TreeNode y) {
  final x = y.children[0]!;
  y.children[0] = x.children[1];
  x.children[1] = y;
  return x;
}

TreeNode _rotateLeft(TreeNode x) {
  final y = x.children[1]!;
  x.children[1] = y.children[0];
  y.children[0] = x;
  return y;
}

TreeNode _rebalance(TreeNode n) {
  final b = _balance(n);
  if (b > 1) {
    if (_balance(n.children[0]!) < 0) n.children[0] = _rotateLeft(n.children[0]!);
    return _rotateRight(n);
  }
  if (b < -1) {
    if (_balance(n.children[1]!) > 0) n.children[1] = _rotateRight(n.children[1]!);
    return _rotateLeft(n);
  }
  return n;
}

TreeNode _avlInsert(TreeNode? n, String v) {
  if (n == null) return TreeNode(v, [null, null]);
  final c = _compare(v, n.label);
  if (c == 0) return n;
  if (c < 0) {
    n.children[0] = _avlInsert(n.children[0], v);
  } else {
    n.children[1] = _avlInsert(n.children[1], v);
  }
  return _rebalance(n);
}

TreeNode? _avlDelete(TreeNode? n, String v) {
  if (n == null) return null;
  final c = _compare(v, n.label);
  if (c < 0) {
    n.children[0] = _avlDelete(n.children[0], v);
  } else if (c > 0) {
    n.children[1] = _avlDelete(n.children[1], v);
  } else {
    final l = n.children[0], r = n.children[1];
    if (l == null) return r;
    if (r == null) return l;
    final next = _min(r)!;
    n.label = next.label;
    n.children[1] = _avlDelete(r, next.label);
  }
  return _rebalance(n);
}

// ---- a heap ----

TreeNode? _fromArray(List<String?> a) {
  if (a.isEmpty || a.first == null) return null;
  final nodes = [for (final v in a) v == null ? null : TreeNode(v, [null, null])];
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    if (n == null) continue;
    for (final k in [2 * i + 1, 2 * i + 2]) {
      n.children[k - 2 * i - 1] = k < nodes.length ? nodes[k] : null;
    }
  }
  return nodes.first;
}

List<String> _heapInsert(List<String> a, String v, bool min) {
  final out = [...a, v];
  var i = out.length - 1;
  bool before(String x, String y) => min ? _compare(x, y) < 0 : _compare(x, y) > 0;
  while (i > 0) {
    final p = (i - 1) ~/ 2;
    if (!before(out[i], out[p])) break;
    final t = out[i];
    out[i] = out[p];
    out[p] = t;
    i = p;
  }
  return out;
}

List<String> _heapExtract(List<String> a, bool min) {
  if (a.isEmpty) return a;
  final out = [...a];
  out[0] = out.last;
  out.removeLast();
  bool before(String x, String y) => min ? _compare(x, y) < 0 : _compare(x, y) > 0;
  var i = 0;
  while (true) {
    var best = i;
    for (final k in [2 * i + 1, 2 * i + 2]) {
      if (k < out.length && before(out[k], out[best])) best = k;
    }
    if (best == i) break;
    final t = out[i];
    out[i] = out[best];
    out[best] = t;
    i = best;
  }
  return out;
}

// ---- reading ----

/// The tree [text] describes.
TreeReading parseTree(String text) {
  final lines = [
    for (final l in text.split('\n'))
      if (l.replaceFirst(RegExp(r'\s*(?:#|//).*$'), '').trim().isNotEmpty) l.replaceFirst(RegExp(r'\s*(?:#|//).*$'), '').trim(),
  ];
  if (lines.isEmpty) return const TreeReading(Tree(null, false, 'tree'), []);
  final head = RegExp(r'^(bst|avl|minheap|maxheap|heap|array|binary|tree)\s*:\s*(.*)$', caseSensitive: false).firstMatch(lines.first);
  if (head == null) return _fromBrackets(lines.join(' '));
  var kind = head.group(1)!.toLowerCase();
  if (kind == 'heap') kind = 'minheap';
  final rest = head.group(2)!;
  final problems = <String>[];
  if (kind == 'tree' || kind == 'binary') {
    final r = _fromBrackets(rest.isEmpty ? lines.skip(1).join(' ') : rest);
    return TreeReading(Tree(r.tree.root, kind == 'binary' ? true : r.tree.binary, 'tree'), r.problems);
  }
  List<String> items(String s) => [for (final p in s.split(RegExp(r'[\s,;]+'))) if (p.isNotEmpty) p];
  final start = items(rest);

  if (kind == 'array') {
    final cells = [for (final p in start) RegExp(r'^(?:-|_|null|none)$', caseSensitive: false).hasMatch(p) ? null : p];
    if (cells.isNotEmpty && cells.first == null) problems.add('the first place is the root, it cannot be a hole');
    return TreeReading(Tree(_fromArray(cells), true, 'array'), problems);
  }

  if (kind == 'minheap' || kind == 'maxheap') {
    final min = kind == 'minheap';
    var heap = <String>[];
    for (final v in start) {
      heap = _heapInsert(heap, v, min);
    }
    for (var n = 1; n < lines.length; n++) {
      final m = RegExp(r'^(insert|add|\+|extract|delete|pop|remove)\s*(.*)$', caseSensitive: false).firstMatch(lines[n]);
      if (m == null) {
        problems.add('line ${n + 1}: ${lines[n]}');
        continue;
      }
      if (RegExp(r'^(insert|add|\+)$', caseSensitive: false).hasMatch(m.group(1)!)) {
        for (final v in items(m.group(2)!)) {
          heap = _heapInsert(heap, v, min);
        }
      } else {
        heap = _heapExtract(heap, min);
      }
    }
    return TreeReading(Tree(_fromArray(heap), true, kind), problems);
  }

  // a search tree
  final avl = kind == 'avl';
  TreeNode? root;
  for (final v in start) {
    root = avl ? _avlInsert(root, v) : _bstInsert(root, v);
  }
  for (var n = 1; n < lines.length; n++) {
    final m = RegExp(r'^(insert|add|\+|delete|remove|-)\s*(.*)$', caseSensitive: false).firstMatch(lines[n]);
    if (m == null) {
      problems.add('line ${n + 1}: ${lines[n]}');
      continue;
    }
    final add = RegExp(r'^(insert|add|\+)$', caseSensitive: false).hasMatch(m.group(1)!);
    for (final v in items(m.group(2)!)) {
      root = add ? (avl ? _avlInsert(root, v) : _bstInsert(root, v)) : (avl ? _avlDelete(root, v) : _bstDelete(root, v));
    }
  }
  return TreeReading(Tree(root, true, kind), problems);
}

// ---- what is worth telling ----

List<String> preorder(Tree t) {
  final out = <String>[];
  void walk(TreeNode? n) {
    if (n == null) return;
    out.add(n.label);
    n.children.forEach(walk);
  }

  walk(t.root);
  return out;
}

List<String> postorder(Tree t) {
  final out = <String>[];
  void walk(TreeNode? n) {
    if (n == null) return;
    n.children.forEach(walk);
    out.add(n.label);
  }

  walk(t.root);
  return out;
}

/// Left subtree, node, right subtree (for a tree with two children at most; with more, the first child, the node, the others).
List<String> inorder(Tree t) {
  final out = <String>[];
  void walk(TreeNode? n) {
    if (n == null) return;
    if (n.children.isEmpty) {
      out.add(n.label);
      return;
    }
    walk(n.children.first);
    out.add(n.label);
    for (final k in n.children.skip(1)) {
      walk(k);
    }
  }

  walk(t.root);
  return out;
}

List<String> levelorder(Tree t) {
  final out = <String>[];
  final queue = <TreeNode>[?t.root];
  for (var i = 0; i < queue.length; i++) {
    out.add(queue[i].label);
    queue.addAll(queue[i].kids);
  }
  return out;
}

/// The balance factor (height of the left subtree minus that of the right) of every node, by label in the order of a preorder walk.
Map<TreeNode, int> balanceFactors(Tree t) {
  final out = <TreeNode, int>{};
  void walk(TreeNode? n) {
    if (n == null) return;
    out[n] = _balance2(n);
    n.children.forEach(walk);
  }

  walk(t.root);
  return out;
}

int _balance2(TreeNode n) => _hOf(n.children.isNotEmpty ? n.children.first : null) - _hOf(n.children.length > 1 ? n.children[1] : null);

int _hOf(TreeNode? n) => n == null ? 0 : 1 + n.children.map(_hOf).fold(0, (m, x) => x > m ? x : m);

/// Things to tell about [t] as (name, value) pairs.
List<(String, String)> treeFacts(Tree t) {
  if (t.isEmpty) return const [];
  final out = <(String, String)>[
    ('Nodes', '${t.size}'),
    ('Height', '${t.height}'),
    ('Leaves', '${_leaves(t.root!)}'),
  ];
  final binary = _onlyTwo(t.root);
  if (binary) {
    final complete = _isComplete(t);
    final full = _isFull(t.root);
    final shape = [if (full) 'full', if (complete) 'complete', if (_isPerfect(t)) 'perfect'];
    out.add(('Shape', shape.isEmpty ? '—' : shape.join(', ')));
    final values = inorder(t);
    final numeric = values.every((v) => _number(v) != null);
    final ordered = [for (var i = 0; i + 1 < values.length; i++) _compare(values[i], values[i + 1])];
    out.add(('Search tree', ordered.every((c) => c < 0) && t.binary ? 'yes' : 'no'));
    final balance = balanceFactors(t);
    out.add(('Balanced (AVL)', balance.values.every((b) => b.abs() <= 1) ? 'yes' : 'no'));
    if (t.kind == 'minheap' || t.kind == 'maxheap' || t.kind == 'array' || complete) {
      out.add(('Min-heap', _heapOk(t.root, true) && complete ? 'yes' : 'no'));
      out.add(('Max-heap', _heapOk(t.root, false) && complete ? 'yes' : 'no'));
    }
    if (!numeric && t.kind != 'tree') out.add(('Order', 'compared as text'));
  }
  out.add(('Preorder', preorder(t).join(' ')));
  if (binary) out.add(('Inorder', inorder(t).join(' ')));
  out.add(('Postorder', postorder(t).join(' ')));
  out.add(('Level order', levelorder(t).join(' ')));
  return out;
}

int _leaves(TreeNode n) => n.isLeaf ? 1 : n.kids.fold(0, (s, k) => s + _leaves(k));

bool _isFull(TreeNode? n) => n == null || (n.kids.isEmpty || n.kids.length == 2 && n.children.length == 2) && n.kids.every(_isFull);

/// Whether the levels are full except the last, which is filled from the left.
bool _isComplete(Tree t) {
  final queue = <TreeNode?>[t.root];
  var gap = false;
  for (var i = 0; i < queue.length; i++) {
    final n = queue[i];
    if (n == null) {
      gap = true;
      continue;
    }
    if (gap) return false;
    final l = n.children.isNotEmpty ? n.children[0] : null, r = n.children.length > 1 ? n.children[1] : null;
    queue
      ..add(l)
      ..add(r);
  }
  return true;
}

bool _isPerfect(Tree t) => _isFull(t.root) && _isComplete(t) && t.size == (1 << (t.height + 1)) - 1;

bool _heapOk(TreeNode? n, bool min) {
  if (n == null) return true;
  for (final k in n.kids) {
    if (min ? _compare(k.label, n.label) < 0 : _compare(k.label, n.label) > 0) return false;
    if (!_heapOk(k, min)) return false;
  }
  return true;
}
