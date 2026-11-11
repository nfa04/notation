import 'dart:convert';

/// What a node of the graph stands for.
enum GraphNodeKind { note, fact, topic }

/// Why two nodes are joined.
enum GraphEdgeKind {
  /// Their meaning is close.
  similar,

  /// One note links to the other.
  link,

  /// A topic and a node in it.
  member,

  /// A note and a fact taken from it.
  source,

  /// Two notes that cite the same source. (After the others: graphs that were kept are read by the number.)
  cites,

  /// Two facts of different notes that give different numbers for the same thing. (Last: graphs that were kept are read by the number.)
  contradicts,
}

/// A node of the knowledge graph: a fact, a note, or a hub that joins a topic or a note. [x] and [y] come from the layout.
class GraphNode {
  final String id;
  final GraphNodeKind kind;
  final String label;

  /// The longer text (a fact's sentence), if any.
  final String detail;

  /// The note it is from (a note's own id for a note), and the page in it (zero-based), if known.
  final String? noteId;
  final int? page;

  /// A fact's kind (Fact, Definition, Data, Method, Result, Claim).
  final String? tag;

  /// Its topic, or -1 when it belongs to none.
  int cluster;
  double x, y;
  double size;

  GraphNode({
    required this.id,
    required this.kind,
    required this.label,
    this.detail = '',
    this.noteId,
    this.page,
    this.tag,
    this.cluster = -1,
    this.x = 0,
    this.y = 0,
    this.size = 1,
  });
}

/// A line between two nodes, [weight] telling how strong the link is (similarity, or 1 for a link written in a note).
class GraphEdge {
  /// Indexes into [KnowledgeGraph.nodes].
  final int a, b;
  final double weight;
  final GraphEdgeKind kind;

  const GraphEdge(this.a, this.b, this.weight, this.kind);
}

/// A topic: a group of nodes that are about the same thing.
class GraphCluster {
  final int id;
  final String label;
  final int size;

  /// Whether the name was written by a model (else it is the topic's most telling words).
  final bool named;
  const GraphCluster(this.id, this.label, this.size, {this.named = false});
}

/// A built graph with its layout: what the view draws, and what is kept between runs.
class KnowledgeGraph {
  /// 'notes' or 'facts'.
  final String mode;
  final DateTime builtAt;
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  final List<GraphCluster> clusters;

  /// How the vectors were made ('lexical' when there was no sentence model), for the view to say.
  final String embedder;

  KnowledgeGraph({required this.mode, required this.builtAt, required this.nodes, required this.edges, required this.clusters, this.embedder = ''});

  bool get isEmpty => nodes.isEmpty;

  String encode() => jsonEncode({
        'v': 1,
        'mode': mode,
        'at': builtAt.millisecondsSinceEpoch,
        'emb': embedder,
        'nodes': [
          for (final n in nodes)
            [n.id, n.kind.index, n.label, n.detail, n.noteId, n.page, n.tag, n.cluster, _r(n.x), _r(n.y), _r(n.size)],
        ],
        'edges': [
          for (final e in edges) [e.a, e.b, _r(e.weight), e.kind.index],
        ],
        'clusters': [
          for (final c in clusters) [c.id, c.label, c.size, if (c.named) 1],
        ],
      });

  static double _r(double v) => (v * 100).roundToDouble() / 100;

  static KnowledgeGraph? decode(String source) {
    try {
      final m = jsonDecode(source) as Map;
      if (m['v'] != 1) return null;
      return KnowledgeGraph(
        mode: m['mode'] as String,
        builtAt: DateTime.fromMillisecondsSinceEpoch(m['at'] as int),
        embedder: m['emb'] as String? ?? '',
        nodes: [
          for (final n in (m['nodes'] as List).cast<List>())
            GraphNode(
              id: n[0] as String,
              kind: GraphNodeKind.values[n[1] as int],
              label: n[2] as String,
              detail: n[3] as String,
              noteId: n[4] as String?,
              page: n[5] as int?,
              tag: n[6] as String?,
              cluster: n[7] as int,
              x: (n[8] as num).toDouble(),
              y: (n[9] as num).toDouble(),
              size: (n[10] as num).toDouble(),
            ),
        ],
        edges: [
          for (final e in (m['edges'] as List).cast<List>()) GraphEdge(e[0] as int, e[1] as int, (e[2] as num).toDouble(), GraphEdgeKind.values[e[3] as int]),
        ],
        clusters: [
          for (final c in (m['clusters'] as List).cast<List>()) GraphCluster(c[0] as int, c[1] as String, c[2] as int, named: c.length > 3 && c[3] == 1),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}
