import 'dart:math' as math;
import 'dart:ui';

import '../ink/ink_clusters.dart';
import '../ink/ink_grouping.dart';
import '../models/canvas_models.dart';
import 'advanced.dart';

// A drawing of circles and lines read as a diagram: a state diagram, a tree or a graph. Pure geometry: the circles are the nodes (two
// rings: a node that accepts), the lines between them are the edges (an arrowhead says which way; a line from nowhere into a node says
// where it starts; a loop on a node is an edge from the node to itself), and the handwriting inside the circles and beside the lines
// is what they are called. What the handwriting says is read by the caller ([readInkDiagram] is given a function for it), so that the
// geometry can be tried without a model.

/// A circle of the drawing.
class SketchNode {
  final Offset center;
  final double radius;
  final List<DrawingStroke> outline;

  /// The writing inside of it (or beside it), which names it.
  final List<DrawingStroke> label = [];

  /// A second ring was drawn inside: the node accepts.
  bool accepting = false;

  /// An arrow comes into it from nowhere: the node where a state diagram starts.
  bool starts = false;

  SketchNode(this.center, this.radius, this.outline);
}

/// A line between two circles (or from one to itself).
class SketchEdge {
  /// The circles at the two ends (indices into [InkSketch.nodes]); the two are the same for a loop.
  final int from, to;

  /// An arrowhead was drawn at the [to] end, at the [from] end too ([both]), or none ([known] false: the direction is the way the line
  /// was drawn).
  final bool known, both;
  final List<Offset> path;
  final List<DrawingStroke> strokes;
  final List<DrawingStroke> label = [];

  SketchEdge(this.from, this.to, this.path, this.strokes, {this.known = false, this.both = false});

  bool get isLoop => from == to;
}

class InkSketch {
  final List<SketchNode> nodes;
  final List<SketchEdge> edges;

  /// Strokes that belong to nothing (writing that is not near a line or a circle, a scribble).
  final List<DrawingStroke> loose;

  const InkSketch(this.nodes, this.edges, this.loose);

  bool get isEmpty => nodes.length < 2 && !(nodes.length == 1 && edges.isNotEmpty);
}

double _pathLength(List<Offset> p) {
  var s = 0.0;
  for (var i = 1; i < p.length; i++) {
    s += (p[i] - p[i - 1]).distance;
  }
  return s;
}

double _distanceToPath(Offset q, List<Offset> path) {
  var best = double.infinity;
  for (var i = 0; i < path.length; i++) {
    final a = path[i];
    if (i == path.length - 1) {
      best = math.min(best, (q - a).distance);
      break;
    }
    final b = path[i + 1];
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = len2 == 0 ? 0.0 : (((q - a).dx * ab.dx + (q - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    best = math.min(best, (q - (a + ab * t)).distance);
  }
  return best;
}

/// The circle a stroke draws, when it draws one: its centre and radius. Closed (it comes back to where it began), once or twice around,
/// and every point about as far from the middle as the others.
({Offset center, double radius})? _circleOf(DrawingStroke s) {
  final p = s.points;
  if (p.length < 8) return null;
  final b = strokeBounds(s);
  final w = b.width, h = b.height;
  if (w < 8 || h < 8) return null;
  final aspect = w / h;
  if (aspect < 0.55 || aspect > 1.8) return null;
  final path = _pathLength(p);
  final c = b.center;
  final m = (w + h) / 4;
  if ((p.first - p.last).distance > 0.25 * path) return null;
  if (path < 2 * math.pi * m * 0.7 || path > 2 * math.pi * m * 2.6) return null;
  var sum = 0.0, sum2 = 0.0, turned = 0.0;
  double? last;
  for (final q in p) {
    final d = (q - c).distance;
    sum += d;
    sum2 += d * d;
    final angle = math.atan2(q.dy - c.dy, q.dx - c.dx);
    if (last != null) {
      var da = angle - last;
      while (da > math.pi) {
        da -= 2 * math.pi;
      }
      while (da < -math.pi) {
        da += 2 * math.pi;
      }
      turned += da;
    }
    last = angle;
  }
  final mean = sum / p.length;
  final variance = math.max(0.0, sum2 / p.length - mean * mean);
  if (mean == 0 || math.sqrt(variance) / mean > 0.22) return null;
  if (turned.abs() < 5.2 || turned.abs() > 9.5) return null;
  return (center: c, radius: m);
}

/// Where [stroke] goes if it is a line with an arrowhead drawn on at one end in the same stroke: the point of the arrow and the line up to it.
({Offset tip, List<Offset> shaft, bool atEnd})? _hooked(List<Offset> p) {
  if (p.length < 6) return null;
  final total = _pathLength(p);
  if (total < 30) return null;
  // the tip is the point furthest from the start; a line that goes on after it for a short way has the barbs of an arrowhead there
  var tip = 0;
  var far = 0.0;
  for (var i = 0; i < p.length; i++) {
    final d = (p[i] - p.first).distance;
    if (d > far) {
      far = d;
      tip = i;
    }
  }
  if (tip >= p.length - 1) return null;
  final after = _pathLength(p.sublist(tip));
  if (after < 8 || after > 0.45 * total) return null;
  // the shaft arrives at the tip, the barbs go back to where it came from
  final shaft = p.sublist(0, tip + 1);
  if (_pathLength(shaft) < 20) return null;
  return (tip: p[tip], shaft: shaft, atEnd: true);
}

bool _isHead(DrawingStroke s) {
  final b = strokeBounds(s);
  return math.max(b.width, b.height) <= 34 && _pathLength(s.points) <= 80;
}

/// Reads the circles and lines of [strokes].
InkSketch readSketch(Iterable<DrawingStroke> strokes) {
  final all = [for (final s in strokes) if (s.points.length >= 2) s];
  final taken = <DrawingStroke>{};

  // 1. the circles: the biggest are nodes, a second ring inside one is the mark of an accepting node
  final candidates = <(DrawingStroke, Offset, double)>[];
  for (final s in all) {
    final c = _circleOf(s);
    if (c != null && c.radius >= 14) candidates.add((s, c.center, c.radius));
  }
  candidates.sort((a, b) => b.$3.compareTo(a.$3));
  final nodes = <SketchNode>[];
  final loops = <(DrawingStroke, Offset, double, int)>[];
  final biggest = candidates.isEmpty ? 0.0 : candidates.first.$3;
  for (final (s, c, r) in candidates) {
    SketchNode? inside;
    for (final n in nodes) {
      if ((c - n.center).distance < n.radius * 0.6) inside = n;
    }
    if (inside != null) {
      if (r >= inside.radius * 0.6 && (c - inside.center).distance < inside.radius * 0.35) {
        inside.accepting = true;
        inside.outline.add(s);
      } else {
        inside.label.add(s); // a 0 or an o in the circle
      }
      taken.add(s);
      continue;
    }
    // a small closed loop that touches a bigger circle is an arrow from the circle to itself
    var loopOn = -1;
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final gap = (c - n.center).distance - n.radius - r;
      if (r <= n.radius * 0.8 && gap < math.max(8.0, r * 0.5)) loopOn = i;
    }
    if (loopOn >= 0) {
      loops.add((s, c, r, loopOn));
      taken.add(s);
      continue;
    }
    if (r < biggest * 0.4) continue; // too small to be a state: writing
    nodes.add(SketchNode(c, r, [s]));
    taken.add(s);
  }

  int? nodeAt(Offset q, {double slack = 0.5}) {
    int? best;
    var bestGap = double.infinity;
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final gap = (q - n.center).distance - n.radius;
      if (gap <= n.radius * slack + 10 && gap < bestGap) {
        best = i;
        bestGap = gap;
      }
    }
    return best;
  }

  // 2. what is written inside of a circle names it
  for (final s in all) {
    if (taken.contains(s)) continue;
    final b = strokeBounds(s);
    for (final n in nodes) {
      if ((b.center - n.center).distance + math.max(b.width, b.height) / 2 <= n.radius * 1.05) {
        n.label.add(s);
        taken.add(s);
        break;
      }
    }
  }

  // 3. the lines: long enough, and at least one end at a circle
  final edges = <SketchEdge>[];
  final pool = [for (final s in all) if (!taken.contains(s)) s];
  final heads = <DrawingStroke>[];
  final lines = <(DrawingStroke, List<Offset>)>[];
  for (final s in pool) {
    if (_pathLength(s.points) < 30) continue;
    final hook = _hooked(s.points);
    final p = hook?.shaft ?? s.points;
    final start = nodeAt(p.first), end = nodeAt(p.last);
    if (start == null && end == null) continue;
    lines.add((s, p));
  }
  for (final (s, p) in lines) {
    taken.add(s);
    final hook = _hooked(s.points);
    var a = nodeAt(p.first), b = nodeAt(p.last);
    var path = p;
    var known = hook != null, both = false;
    // an arrowhead drawn as strokes of its own at one of the ends
    if (!known) {
      bool headAt(Offset tip) {
        for (final h in pool) {
          if (taken.contains(h) || h == s || !_isHead(h)) continue;
          for (final q in h.points) {
            if ((q - tip).distance <= 10) {
              heads.add(h);
              return true;
            }
          }
        }
        return false;
      }

      final atStart = headAt(p.first), atEnd = headAt(p.last);
      if (atStart && !atEnd) {
        path = p.reversed.toList();
        final t = a;
        a = b;
        b = t;
        known = true;
      } else if (atEnd) {
        known = true;
        both = atStart;
      }
      for (final h in heads) {
        taken.add(h);
      }
    }
    if (b == null || a == null) {
      // a line from nowhere into a circle with an arrowhead: where the diagram starts
      final into = b ?? a;
      if (into != null && known && _pathLength(path) >= 25) {
        nodes[into].starts = true;
      } else {
        taken.remove(s);
      }
      continue;
    }
    edges.add(SketchEdge(a, b, path, [s], known: known, both: both));
  }
  // the loops
  for (final (s, _, _, i) in loops) {
    edges.add(SketchEdge(i, i, s.points, [s], known: true));
  }
  // (an open loop, a line with both ends at the same circle, was taken as a line above)

  // 4. the writing that is left, in pieces that belong together, goes to the nearest line or circle
  final rest = [for (final s in all) if (!taken.contains(s)) s];
  final loose = <DrawingStroke>[];
  if (rest.isNotEmpty) {
    for (final cluster in _pieces(rest)) {
      final box = cluster.map(strokeBounds).reduce((a, b) => a.expandToInclude(b));
      final centre = box.center;
      final size = math.max(box.width, box.height);
      SketchEdge? nearEdge;
      var edgeGap = double.infinity;
      for (final e in edges) {
        final d = _distanceToPath(centre, e.path);
        if (d < edgeGap) {
          edgeGap = d;
          nearEdge = e;
        }
      }
      SketchNode? nearNode;
      var nodeGap = double.infinity;
      for (final n in nodes) {
        final d = (centre - n.center).distance - n.radius;
        if (d < nodeGap) {
          nodeGap = d;
          nearNode = n;
        }
      }
      final reach = 28.0 + size;
      if (nearEdge != null && edgeGap <= reach && edgeGap <= nodeGap + 6) {
        nearEdge.label.addAll(cluster);
      } else if (nearNode != null && nodeGap <= reach * 0.8 && nearNode.label.isEmpty) {
        nearNode.label.addAll(cluster);
      } else {
        loose.addAll(cluster);
      }
    }
  }
  return InkSketch(nodes, edges, loose);
}

/// Strokes that lie together (the letters of one label).
List<List<DrawingStroke>> _pieces(List<DrawingStroke> strokes) {
  // (clustering by the size of the letters: the same grouping the handwriting reader uses)
  final found = clusterStrokes(0, strokes, gap: 14);
  final used = <DrawingStroke>{};
  final out = <List<DrawingStroke>>[];
  for (final c in found) {
    out.add(c.strokes);
    used.addAll(c.strokes);
  }
  // a stroke that is not handwriting (the cluster step leaves it out) is a piece of its own
  for (final s in strokes) {
    if (!used.contains(s)) out.add([s]);
  }
  return out;
}

/// What was read from a drawing: the text of the diagram, which kind it is, and what could not be made out.
class InkReading {
  final DiagramMode mode;
  final String text;
  /// What could not be made out, as a sentence with {placeholders} (for `tr`) and what goes in them.
  final List<(String, Map<String, Object>)> notes;
  final int nodes, edges;

  const InkReading(this.mode, this.text, this.notes, this.nodes, this.edges);

  bool get isEmpty => text.trim().isEmpty;
}

/// What the formula reader wrote for the name or the weight of a node or a line, as plain text: `q_{1}` is `q1`, a full stop it adds at
/// the end goes, and the letters it mixes up with digits next to a state letter (`qO`, `sl`) are digits.
String tidyDiagramLabel(String raw) {
  var s = raw.trim();
  s = s.replaceAllMapped(RegExp(r'\\(?:mbox|mathrm|mathit|text|textrm|operatorname)\s*\{([^{}]*)\}'), (m) => m[1]!);
  s = s.replaceAll(RegExp(r'\\(?:mbox|mathrm|mathit|text|textrm)(?=[A-Za-z0-9])'), '');
  s = s.replaceAll(r'\circ', '0').replaceAll(r'\Delta', 'A').replaceAll(RegExp(r'\\[,;! ]'), '');
  s = s.replaceAll(RegExp(r'[_{}\s]'), '').replaceAll(RegExp(r'\^'), '');
  s = s.replaceAll(RegExp(r'[.:;]+$'), '');
  s = s.replaceAllMapped(RegExp(r'^([qspr])[Oo]$'), (m) => '${m[1]}0').replaceAllMapped(RegExp(r'^([qspr])[lI|]$'), (m) => '${m[1]}1');
  return s;
}

String _clean(String s) => s.replaceAll(RegExp(r'\s+'), '').replaceAll(RegExp(r'[(){}\[\]<>#:;]'), '');

String _edgeLabel(String s) => s.trim().replaceAll(RegExp(r'\s*[;/]\s*'), ',').replaceAll(RegExp(r'\s+'), '').replaceAll('->', '');

/// The kind of diagram a sketch is, given what the edges are called.
DiagramMode kindOf(InkSketch sketch, List<String> edgeLabels) {
  final nodes = sketch.nodes.length;
  final accepts = sketch.nodes.any((n) => n.accepting);
  final starts = sketch.nodes.any((n) => n.starts);
  final loops = sketch.edges.any((e) => e.isLoop);
  final directed = sketch.edges.any((e) => e.known);
  final labelled = edgeLabels.any((l) => l.isNotEmpty);
  final numbers = edgeLabels.where((l) => l.isNotEmpty).every((l) => num.tryParse(l) != null);
  if (accepts || starts) return DiagramMode.automaton;
  if (labelled && !numbers) return DiagramMode.automaton;
  if (loops) return DiagramMode.automaton;
  // a tree: connected, one edge fewer than nodes, no cycle; the lines have no weights and no arrowheads
  if (!directed && !labelled && sketch.edges.length == nodes - 1 && _connected(sketch)) return DiagramMode.tree;
  if (directed && !labelled && sketch.edges.length == nodes - 1 && _connected(sketch) && _hierarchy(sketch)) return DiagramMode.tree;
  return DiagramMode.graph;
}

bool _connected(InkSketch s) {
  if (s.nodes.isEmpty) return false;
  final seen = {0};
  final todo = [0];
  while (todo.isNotEmpty) {
    final n = todo.removeLast();
    for (final e in s.edges) {
      for (final (a, b) in [(e.from, e.to), (e.to, e.from)]) {
        if (a == n && seen.add(b)) todo.add(b);
      }
    }
  }
  return seen.length == s.nodes.length;
}

/// Arrows that all point down the page (from a node above to one below): the arrows of a tree.
bool _hierarchy(InkSketch s) => s.edges.every((e) => s.nodes[e.to].center.dy >= s.nodes[e.from].center.dy);

/// The text of the diagram that [sketch] draws, given what its nodes and lines are called, in the order of [SketchNode]s and
/// [SketchEdge]s. [forceMode] makes it a diagram of that kind whatever it looks like.
InkReading describeSketch(InkSketch sketch, List<String> nodeLabels, List<String> edgeLabels, {DiagramMode? forceMode}) {
  final notes = <(String, Map<String, Object>)>[];
  final n = sketch.nodes.length;
  final mode = forceMode ?? kindOf(sketch, edgeLabels);
  // the names: what was read, or q0, q1... (for a state diagram) in order from left to right; the same name twice gets a number
  final order = List.generate(n, (i) => i)..sort((a, b) => sketch.nodes[a].center.dx.compareTo(sketch.nodes[b].center.dx));
  final names = List<String>.filled(n, '');
  final used = <String>{};
  var unread = 0;
  for (final i in order) {
    var name = _clean(nodeLabels[i]);
    if (name.isEmpty) {
      unread++;
      name = mode == DiagramMode.automaton ? 'q${order.indexOf(i)}' : '${order.indexOf(i) + 1}';
    }
    var unique = name;
    var k = 2;
    while (!used.add(unique)) {
      unique = '$name${k++}';
    }
    names[i] = unique;
  }
  if (unread > 0) notes.add(('{n} of {all} circles have no readable name and are numbered.', {'n': unread, 'all': n}));
  final lines = <String>[];
  switch (mode) {
    case DiagramMode.automaton:
      final start = [for (var i = 0; i < n; i++) if (sketch.nodes[i].starts) names[i]];
      final accept = [for (var i = 0; i < n; i++) if (sketch.nodes[i].accepting) names[i]];
      if (start.isNotEmpty) lines.add('start: ${start.first}');
      if (accept.isNotEmpty) lines.add('accept: ${accept.join(', ')}');
      for (var i = 0; i < sketch.edges.length; i++) {
        final e = sketch.edges[i];
        final label = _edgeLabel(edgeLabels[i]);
        final arrow = label.isEmpty ? '->' : '-$label->';
        lines.add('${names[e.from]} $arrow ${names[e.to]}');
        if (e.both) lines.add('${names[e.to]} $arrow ${names[e.from]}');
      }
      // (a circle without any line still is a state)
      final touched = {for (final e in sketch.edges) ...[e.from, e.to]};
      for (var i = 0; i < n; i++) {
        if (!touched.contains(i)) lines.add(names[i]);
      }
    case DiagramMode.tree:
      lines.add(_treeText(sketch, names, notes));
    case DiagramMode.graph:
      final directed = sketch.edges.any((e) => e.known);
      for (var i = 0; i < sketch.edges.length; i++) {
        final e = sketch.edges[i];
        final w = num.tryParse(_edgeLabel(edgeLabels[i]));
        final link = directed && e.known ? (w == null ? '->' : '-$w->') : (w == null ? '-' : '-$w-');
        lines.add('${names[e.from]} $link ${names[e.to]}');
      }
      final touched = {for (final e in sketch.edges) ...[e.from, e.to]};
      for (var i = 0; i < n; i++) {
        if (!touched.contains(i)) lines.add(names[i]);
      }
    case DiagramMode.simple:
      break;
  }
  if (sketch.loose.isNotEmpty) notes.add(('Some writing was not next to a circle or a line and is left out.', const {}));
  return InkReading(mode, lines.join('\n'), notes, n, sketch.edges.length);
}

String _treeText(InkSketch s, List<String> names, List<(String, Map<String, Object>)> notes) {
  final n = s.nodes.length;
  if (n == 0) return '';
  // the root is the highest circle (or the one the arrows come from)
  var root = 0;
  for (var i = 1; i < n; i++) {
    if (s.nodes[i].center.dy < s.nodes[root].center.dy - 4) root = i;
  }
  final adjacent = List.generate(n, (_) => <int>[]);
  for (final e in s.edges) {
    if (e.isLoop) continue;
    adjacent[e.from].add(e.to);
    adjacent[e.to].add(e.from);
  }
  final children = List.generate(n, (_) => <int>[]);
  final seen = {root};
  final todo = [root];
  while (todo.isNotEmpty) {
    final p = todo.removeAt(0);
    final next = [for (final c in adjacent[p]) if (!seen.contains(c)) c]..sort((a, b) => s.nodes[a].center.dx.compareTo(s.nodes[b].center.dx));
    for (final c in next) {
      if (seen.add(c)) {
        children[p].add(c);
        todo.add(c);
      }
    }
  }
  if (seen.length < n) notes.add(('{n} circles are not joined to the rest and are left out of the tree.', {'n': n - seen.length}));
  final binary = [for (var i = 0; i < n; i++) children[i].length <= 2].every((b) => b);
  String build(int i) {
    final kids = children[i];
    if (kids.isEmpty) return names[i];
    if (binary) {
      // a single child sits on the side it was drawn on; the other place stays empty
      String left = '', right = '';
      if (kids.length == 2) {
        left = build(kids[0]);
        right = build(kids[1]);
      } else if (s.nodes[kids[0]].center.dx < s.nodes[i].center.dx) {
        left = build(kids[0]);
      } else {
        right = build(kids[0]);
      }
      return '${names[i]}($left,$right)';
    }
    return '${names[i]}(${kids.map(build).join(',')})';
  }

  return build(root);
}

/// Reads a drawing as a diagram. [read] reads the handwriting of some strokes (a name, a letter, a weight); a reading that fails leaves the
/// name empty, so that it is numbered and the person can type it in the dialog that follows.
Future<InkReading> readInkDiagram(Iterable<DrawingStroke> strokes, Future<String> Function(List<DrawingStroke>) read, {DiagramMode? forceMode}) async {
  final sketch = readSketch(strokes);
  if (sketch.isEmpty) return InkReading(DiagramMode.graph, '', const [], 0, 0);
  Future<String> safe(List<DrawingStroke> s) async {
    if (s.isEmpty) return '';
    try {
      return tidyDiagramLabel(await read(s));
    } catch (_) {
      return '';
    }
  }

  final nodeLabels = [for (final n in sketch.nodes) await safe(n.label)];
  final edgeLabels = [for (final e in sketch.edges) await safe(e.label)];
  return describeSketch(sketch, nodeLabels, edgeLabels, forceMode: forceMode);
}
