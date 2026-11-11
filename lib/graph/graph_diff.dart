import 'graph_model.dart';

/// What differs between two graphs of the same kind: what the notes gained, lost or changed. Nodes are told apart by their id (a fact's id
/// is its row in the facts table, a note's its own id), so two graphs made of the same notes line up; the hubs of topics have no lasting
/// id (they are numbered at each run) and are left out, as are the lines that only join a hub to what it holds.
class GraphDiff {
  /// Indexes into the newer graph's nodes: what is not in the older one, and what is in both with another title or text.
  final List<int> added;
  final List<int> changed;

  /// Nodes of the older graph that the newer one has no more.
  final List<GraphNode> removed;

  /// Lines between nodes that are in both graphs: new ones and ones that went.
  final int linesAdded;
  final int linesRemoved;

  /// Names of topics that are only in the newer graph, and only in the older one.
  final List<String> topicsNew;
  final List<String> topicsGone;

  const GraphDiff({
    required this.added,
    required this.changed,
    required this.removed,
    required this.linesAdded,
    required this.linesRemoved,
    required this.topicsNew,
    required this.topicsGone,
  });

  bool get isEmpty => added.isEmpty && changed.isEmpty && removed.isEmpty && linesAdded == 0 && linesRemoved == 0 && topicsNew.isEmpty && topicsGone.isEmpty;
}

/// What [after] has that [before] had not, and the other way round.
GraphDiff diffGraphs(KnowledgeGraph before, KnowledgeGraph after) {
  bool counts(GraphNode n) => n.kind != GraphNodeKind.topic;
  final old = {for (final n in before.nodes) if (counts(n)) n.id: n};
  final now = <String>{};
  final added = <int>[], changed = <int>[];
  for (var i = 0; i < after.nodes.length; i++) {
    final n = after.nodes[i];
    if (!counts(n)) continue;
    now.add(n.id);
    final was = old[n.id];
    if (was == null) {
      added.add(i);
    } else if (was.label != n.label || was.detail != n.detail) {
      changed.add(i);
    }
  }
  final removed = [for (final e in old.entries) if (!now.contains(e.key)) e.value];

  // lines: only between nodes that both graphs have (a node that came or went brings its lines with it)
  Set<String> linesOf(KnowledgeGraph g, Set<String> among) {
    final out = <String>{};
    for (final e in g.edges) {
      if (e.kind == GraphEdgeKind.member || e.kind == GraphEdgeKind.source) continue;
      final a = g.nodes[e.a].id, b = g.nodes[e.b].id;
      if (!among.contains(a) || !among.contains(b)) continue;
      out.add(a.compareTo(b) < 0 ? '$a\u0000$b\u0000${e.kind.index}' : '$b\u0000$a\u0000${e.kind.index}');
    }
    return out;
  }

  final both = {for (final id in old.keys) if (now.contains(id)) id};
  final lines0 = linesOf(before, both), lines1 = linesOf(after, both);

  final names0 = {for (final c in before.clusters) c.label}, names1 = {for (final c in after.clusters) c.label};
  return GraphDiff(
    added: added,
    changed: changed,
    removed: removed,
    linesAdded: lines1.difference(lines0).length,
    linesRemoved: lines0.difference(lines1).length,
    topicsNew: [for (final c in after.clusters) if (!names0.contains(c.label)) c.label],
    topicsGone: [for (final c in before.clusters) if (!names1.contains(c.label)) c.label],
  );
}
