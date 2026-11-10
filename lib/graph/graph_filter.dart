import 'graph_model.dart';

/// What a graph is narrowed to on screen. Nothing is made again: the nodes and the lines that do not pass are left out of the picture.
class GraphFilter {
  /// The kinds of fact shown (Definition, Data...); empty: all.
  final Set<String> tags;

  /// The notes whose nodes are shown; empty: all. (A topic does not belong to a note, so it stays while any of its nodes does.)
  final Set<String> notes;

  /// The kinds of line that are left out.
  final Set<GraphEdgeKind> hiddenEdges;

  /// The weakest similarity a line of [GraphEdgeKind.similar] may have to be shown.
  final double minWeight;

  /// Leave out the nodes that stand for a topic or for a note of the facts graph (the facts alone remain).
  final bool hideHubs;

  /// Leave out the nodes that have no line left.
  final bool hideLoose;

  const GraphFilter({
    this.tags = const {},
    this.notes = const {},
    this.hiddenEdges = const {},
    this.minWeight = 0,
    this.hideHubs = false,
    this.hideLoose = false,
  });

  bool get active => tags.isNotEmpty || notes.isNotEmpty || hiddenEdges.isNotEmpty || minWeight > 0 || hideHubs || hideLoose;

  /// How many of the settings are in use (for the badge on the button).
  int get count => (tags.isNotEmpty ? 1 : 0) + (notes.isNotEmpty ? 1 : 0) + (hiddenEdges.isNotEmpty ? 1 : 0) + (minWeight > 0 ? 1 : 0) + (hideHubs ? 1 : 0) + (hideLoose ? 1 : 0);

  GraphFilter copyWith({Set<String>? tags, Set<String>? notes, Set<GraphEdgeKind>? hiddenEdges, double? minWeight, bool? hideHubs, bool? hideLoose}) => GraphFilter(
        tags: tags ?? this.tags,
        notes: notes ?? this.notes,
        hiddenEdges: hiddenEdges ?? this.hiddenEdges,
        minWeight: minWeight ?? this.minWeight,
        hideHubs: hideHubs ?? this.hideHubs,
        hideLoose: hideLoose ?? this.hideLoose,
      );

  /// What is left of [g]: the indexes of the nodes shown and the lines between them.
  FilteredGraph apply(KnowledgeGraph g) {
    if (!active) return FilteredGraph(null, g.edges);
    bool passes(GraphNode n) {
      if (hideHubs && (n.kind == GraphNodeKind.topic || (n.kind == GraphNodeKind.note && g.mode == 'facts'))) return false;
      if (tags.isNotEmpty && n.tag != null && !tags.contains(n.tag)) return false;
      if (notes.isNotEmpty && n.noteId != null && !notes.contains(n.noteId)) return false;
      return true;
    }

    final shown = <int>{for (var i = 0; i < g.nodes.length; i++) if (passes(g.nodes[i])) i};
    final edges = [
      for (final e in g.edges)
        if (shown.contains(e.a) && shown.contains(e.b) && !hiddenEdges.contains(e.kind) && !(e.kind == GraphEdgeKind.similar && e.weight < minWeight)) e,
    ];
    // a topic without a node to join is nothing to look at, whatever [hideLoose] says
    final joined = <int>{for (final e in edges) ...[e.a, e.b]};
    shown.removeWhere((i) => !joined.contains(i) && (hideLoose || g.nodes[i].kind == GraphNodeKind.topic));
    return FilteredGraph(shown, edges);
  }

  @override
  bool operator ==(Object other) =>
      other is GraphFilter && other.minWeight == minWeight && other.hideHubs == hideHubs && other.hideLoose == hideLoose && _same(other.tags, tags) && _same(other.notes, notes) && _same(other.hiddenEdges, hiddenEdges);

  @override
  int get hashCode => Object.hash(minWeight, hideHubs, hideLoose, tags.length, notes.length, hiddenEdges.length);

  static bool _same<T>(Set<T> a, Set<T> b) => a.length == b.length && a.containsAll(b);
}

/// A graph seen through a [GraphFilter].
class FilteredGraph {
  /// The indexes of the nodes shown; null: all of them.
  final Set<int>? nodes;
  final List<GraphEdge> edges;

  const FilteredGraph(this.nodes, this.edges);

  bool shows(int node) => nodes == null || nodes!.contains(node);

  int count(KnowledgeGraph g) => nodes?.length ?? g.nodes.length;
}
