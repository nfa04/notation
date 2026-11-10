/// What a diagram is made of: boxes with text, and lines between them.
class DiagramNode {
  final int id;
  final String label;

  /// How far from the root in a tree (0 for the root); for a flowchart, unused.
  final int depth;

  /// A question in a flowchart ("Enough?"): drawn in its own colour.
  final bool decision;

  const DiagramNode(this.id, this.label, {this.depth = 0, this.decision = false});
}

class DiagramEdge {
  final int from, to;
  final String? label;

  const DiagramEdge(this.from, this.to, [this.label]);
}

enum DiagramKind { mindMap, flow }

class Diagram {
  final DiagramKind kind;
  final List<DiagramNode> nodes;
  final List<DiagramEdge> edges;

  const Diagram(this.kind, this.nodes, this.edges);

  bool get isEmpty => nodes.isEmpty;

  List<int> childrenOf(int id) => [for (final e in edges) if (e.from == id) e.to];
}

final _arrow = RegExp(r'\s*(?:-{1,2}>|=>)\s*');

/// Whether [text] is written as a flowchart (some line has an arrow) and not as an outline.
bool looksLikeFlow(String text) => text.split('\n').any((l) => _arrow.hasMatch(l) && l.split(_arrow).where((p) => p.trim().isNotEmpty).length >= 2);

/// The diagram [text] describes: a flowchart when it has arrows, else a mind map from the outline.
Diagram parseDiagram(String text, {String rootTitle = ''}) => looksLikeFlow(text) ? parseFlow(text) : parseOutline(text, rootTitle: rootTitle);

String _clean(String s) => s.replaceAll(RegExp(r'[*_`]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// A mind map from an outline: Markdown headings (`#`, `##`, ...) and/or a bulleted or numbered list nested by indentation. One top
/// entry is the centre; several get [rootTitle] (or "Mind map") as their centre.
Diagram parseOutline(String text, {String rootTitle = ''}) {
  // (level, label) of every entry; a heading is one level deeper than the list under it would be, so the list nests below it
  final entries = <(int, String)>[];
  var headingLevel = 0;
  var inCode = false;
  for (final raw in text.replaceAll('\t', '    ').split('\n')) {
    if (raw.trimLeft().startsWith('```')) {
      inCode = !inCode;
      continue;
    }
    if (inCode || raw.trim().isEmpty) continue;
    final heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$').firstMatch(raw);
    if (heading != null) {
      headingLevel = heading.group(1)!.length;
      final label = _clean(heading.group(2)!);
      if (label.isNotEmpty) entries.add((headingLevel - 1, label));
      continue;
    }
    final item = RegExp(r'^(\s*)(?:[-*+•]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+)$').firstMatch(raw);
    if (item != null) {
      final indent = item.group(1)!.length;
      final label = _clean(item.group(2)!);
      if (label.isNotEmpty) entries.add((headingLevel + indent ~/ 2, label));
      continue;
    }
    // a plain line: an entry on the level of the last heading's children
    final label = _clean(raw);
    if (label.isNotEmpty) entries.add((headingLevel + (raw.length - raw.trimLeft().length) ~/ 2, label));
  }
  if (entries.isEmpty) return const Diagram(DiagramKind.mindMap, [], []);

  // levels that skip (a list starting deeper than the heading above) are closed up: an entry is at most one level below the one before
  final fixed = <(int, String)>[];
  var last = -1;
  for (final (level, label) in entries) {
    var l = level < 0 ? 0 : level;
    if (l > last + 1) l = last + 1;
    fixed.add((l, label));
    last = l;
  }

  final nodes = <DiagramNode>[];
  final edges = <DiagramEdge>[];
  final top = fixed.where((e) => e.$1 == 0).length;
  final stack = <int>[]; // node ids by level
  var offset = 0;
  if (top != 1) {
    nodes.add(DiagramNode(0, rootTitle.trim().isEmpty ? 'Mind map' : _clean(rootTitle)));
    stack.add(0);
    offset = 1;
  }
  for (final (level, label) in fixed) {
    final depth = level + offset;
    final id = nodes.length;
    nodes.add(DiagramNode(id, label, depth: depth));
    while (stack.length > depth) {
      stack.removeLast();
    }
    if (stack.isNotEmpty) edges.add(DiagramEdge(stack.last, id));
    stack.add(id);
  }
  return Diagram(DiagramKind.mindMap, nodes, edges);
}

/// A flowchart from lines like `Start -> Check input -> Valid?`, with an optional label for the last arrow of a line after a colon
/// (`Valid? -> Save : yes`). A node is known by its text, so the same text on two lines is one box. A text ending in ? is a decision.
Diagram parseFlow(String text) {
  final nodes = <DiagramNode>[];
  final ids = <String, int>{};
  final edges = <DiagramEdge>[];
  int node(String label) => ids.putIfAbsent(label, () {
        nodes.add(DiagramNode(nodes.length, label, decision: label.endsWith('?')));
        return nodes.length - 1;
      });

  for (var line in text.split('\n')) {
    line = line.trim().replaceFirst(RegExp(r'^[-*+•]\s+'), '');
    if (line.isEmpty || line.startsWith('#')) continue;
    String? edgeLabel;
    // "A -> B : label": the label belongs to the last arrow
    final colon = line.lastIndexOf(RegExp(r'\s:\s|:\s'));
    if (colon > 0 && line.substring(0, colon).contains(_arrow) && !line.substring(colon + 1).contains(_arrow)) {
      edgeLabel = _clean(line.substring(colon + 1));
      line = line.substring(0, colon);
    }
    final parts = [for (final p in line.split(_arrow)) _clean(p)];
    if (parts.where((p) => p.isNotEmpty).length < 2) {
      // a line with one text and no arrow is a box of its own
      final only = parts.where((p) => p.isNotEmpty);
      if (only.length == 1 && !line.contains(_arrow)) node(only.first);
      continue;
    }
    final labels = parts.where((p) => p.isNotEmpty).toList();
    for (var i = 0; i + 1 < labels.length; i++) {
      final a = node(labels[i]), b = node(labels[i + 1]);
      final lab = i == labels.length - 2 && edgeLabel != null && edgeLabel.isNotEmpty ? edgeLabel : null;
      if (!edges.any((e) => e.from == a && e.to == b && e.label == lab)) edges.add(DiagramEdge(a, b, lab));
    }
  }
  return Diagram(DiagramKind.flow, nodes, edges);
}
