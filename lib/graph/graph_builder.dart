import 'dart:math' as math;
import 'dart:typed_data';

import 'graph_model.dart';

/// One thing to put in the graph: a note or a fact, with the vector that says what it is about.
class GraphInput {
  final String id;
  final GraphNodeKind kind;
  final String label;
  final String detail;
  final String? noteId;
  final int? page;
  final String? tag;

  /// Length 1; null when there is nothing to read it from (the node then has no similar edges).
  final Float32List? vector;

  /// Words that tell what it is about (they name its topic).
  final List<String> keywords;

  const GraphInput({
    required this.id,
    required this.kind,
    required this.label,
    this.detail = '',
    this.noteId,
    this.page,
    this.tag,
    this.vector,
    this.keywords = const [],
  });
}

/// How the structure is made.
class GraphSettings {
  /// How many nearest neighbours each node is joined to at most.
  final int neighbours;

  /// The least cosine for two nodes to be joined.
  final double minSimilarity;

  /// A topic with fewer nodes than this is folded into the nearest bigger one.
  final int minTopicSize;

  /// Whether a topic gets a node of its own, joined to its members (only for topics of at least 3).
  final bool topicHubs;

  /// Whether a note gets a node, joined to the facts taken from it.
  final bool noteHubs;

  const GraphSettings({this.neighbours = 4, this.minSimilarity = 0.45, this.minTopicSize = 2, this.topicHubs = true, this.noteHubs = false});
}

/// The words that tell topics apart: lower case, three letters or more, without the little words of English, German and French.
const _little = {
  'the', 'and', 'for', 'are', 'was', 'were', 'with', 'from', 'that', 'this', 'these', 'those', 'which', 'has', 'have', 'had', 'can',
  'not', 'but', 'into', 'its', 'their', 'than', 'then', 'such', 'also', 'may', 'will', 'been', 'being', 'each', 'one', 'two', 'all',
  'der', 'die', 'das', 'und', 'ist', 'sind', 'war', 'mit', 'von', 'zu', 'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einer',
  'nicht', 'auch', 'auf', 'für', 'bei', 'als', 'oder', 'aber', 'wird', 'werden', 'sich', 'wie', 'kann', 'les', 'est', 'sont', 'une',
  'pour', 'dans', 'que', 'qui', 'avec', 'sur', 'aux',
};

List<String> telltaleWords(String text) => [
      for (final m in RegExp(r'[\p{L}\p{N}]{3,}', unicode: true).allMatches(text.toLowerCase()))
        if (!_little.contains(m[0]!) && !RegExp(r'^\d+$').hasMatch(m[0]!)) m[0]!,
    ];

/// The graph of [inputs] (without positions: see `layoutGraph`). [links] joins nodes by their ids (a note that links to another).
/// A pure function: the same input gives the same graph.
///
/// [shared] joins notes that cite the same sources: the two ids and how many sources they have in common.
KnowledgeGraph buildGraph(String mode, List<GraphInput> inputs, {List<(String, String)> links = const [], List<(String, String, int)> shared = const [], List<(String, String)> clashes = const [], GraphSettings settings = const GraphSettings(), String embedder = '', DateTime? now}) {
  final nodes = <GraphNode>[
    for (final i in inputs) GraphNode(id: i.id, kind: i.kind, label: i.label, detail: i.detail, noteId: i.noteId, page: i.page, tag: i.tag),
  ];
  final n = nodes.length;
  final index = {for (var i = 0; i < n; i++) nodes[i].id: i};
  final weights = <int, double>{}; // a * n + b (a < b) -> weight
  final kinds = <int, GraphEdgeKind>{};

  void join(int a, int b, double w, GraphEdgeKind kind) {
    if (a == b) return;
    final lo = math.min(a, b), hi = math.max(a, b);
    final key = lo * n + hi;
    final old = weights[key];
    if (old == null || w > old) {
      weights[key] = w;
      kinds[key] = kind;
    } else if (kind == GraphEdgeKind.contradicts) {
      kinds[key] = kind; // (the same two facts are close in meaning, and that is why they clash: the clash is what is told)
    } else if (kind == GraphEdgeKind.link || (kind == GraphEdgeKind.cites && kinds[key] != GraphEdgeKind.link)) {
      // what a person wrote down (a link, a citation) is told from a likeness that was only worked out
      kinds[key] = kind;
      if (kind == GraphEdgeKind.cites && w > weights[key]!) weights[key] = w;
    }
  }

  // ---- similar: each node to its nearest few
  final k = settings.neighbours;
  final bestId = List<List<int>>.generate(n, (_) => <int>[]);
  final bestSim = List<List<double>>.generate(n, (_) => <double>[]);
  void offer(int from, int to, double s) {
    final ids = bestId[from], sims = bestSim[from];
    var at = ids.length;
    while (at > 0 && sims[at - 1] < s) {
      at--;
    }
    if (at >= k) return;
    ids.insert(at, to);
    sims.insert(at, s);
    if (ids.length > k) {
      ids.removeLast();
      sims.removeLast();
    }
  }

  final vectors = [for (final i in inputs) i.vector];
  for (var a = 0; a < n; a++) {
    final va = vectors[a];
    if (va == null) continue;
    for (var b = a + 1; b < n; b++) {
      final vb = vectors[b];
      if (vb == null) continue;
      var s = 0.0;
      final len = math.min(va.length, vb.length);
      for (var d = 0; d < len; d++) {
        s += va[d] * vb[d];
      }
      if (s < settings.minSimilarity) continue;
      offer(a, b, s);
      offer(b, a, s);
    }
  }
  for (var a = 0; a < n; a++) {
    for (var j = 0; j < bestId[a].length; j++) {
      final b = bestId[a][j];
      final mutual = bestId[b].contains(a);
      join(a, b, bestSim[a][j] * (mutual ? 1.0 : 0.85), GraphEdgeKind.similar);
    }
  }
  // ---- links the person made
  for (final (from, to) in links) {
    final a = index[from], b = index[to];
    if (a != null && b != null) join(a, b, 1.0, GraphEdgeKind.link);
  }

  // ---- notes that cite the same source
  for (final (from, to, count) in shared) {
    final a = index[from], b = index[to];
    if (a != null && b != null) join(a, b, math.min(1.0, 0.55 + 0.15 * count), GraphEdgeKind.cites);
  }

  // ---- facts that disagree
  for (final (from, to) in clashes) {
    final a = index[from], b = index[to];
    if (a == null || b == null || a == b) continue;
    final lo = math.min(a, b), hi = math.max(a, b);
    weights[lo * n + hi] = math.max(weights[lo * n + hi] ?? 0, 0.6);
    kinds[lo * n + hi] = GraphEdgeKind.contradicts;
  }

  // ---- topics
  final adjacency = List<List<(int, double)>>.generate(n, (_) => []);
  for (final e in weights.entries) {
    final a = e.key ~/ n, b = e.key % n;
    adjacency[a].add((b, e.value));
    adjacency[b].add((a, e.value));
  }
  final label = _propagate(n, adjacency);
  _foldSmall(label, adjacency, settings.minTopicSize);

  // contiguous ids, biggest first; nodes alone have none (-1)
  final members = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    members.putIfAbsent(label[i], () => []).add(i);
  }
  final order = members.entries.where((e) => e.value.length >= math.max(2, settings.minTopicSize)).toList()
    ..sort((x, y) {
      final c = y.value.length.compareTo(x.value.length);
      return c != 0 ? c : x.key.compareTo(y.key);
    });
  final clusterOf = <int, int>{for (var c = 0; c < order.length; c++) order[c].key: c};
  for (var i = 0; i < n; i++) {
    nodes[i].cluster = clusterOf[label[i]] ?? -1;
  }
  final names = _nameTopics(inputs, nodes, order.length);
  final clusters = [for (var c = 0; c < order.length; c++) GraphCluster(c, names[c], order[c].value.length)];

  // ---- sizes: the more a node is joined, the bigger
  final degree = List<int>.filled(n, 0);
  for (final key in weights.keys) {
    degree[key ~/ n]++;
    degree[key % n]++;
  }
  for (var i = 0; i < n; i++) {
    nodes[i].size = 1 + math.min(4, math.sqrt(degree[i].toDouble())) * 0.45;
  }

  final edges = <GraphEdge>[
    for (final e in weights.entries) GraphEdge(e.key ~/ n, e.key % n, e.value, kinds[e.key]!),
  ]..sort((x, y) {
      final c = x.a.compareTo(y.a);
      return c != 0 ? c : x.b.compareTo(y.b);
    });

  // ---- hubs
  if (settings.topicHubs) {
    for (var c = 0; c < clusters.length; c++) {
      if (clusters[c].size < 3) continue;
      final hub = nodes.length;
      nodes.add(GraphNode(id: 'topic:$c', kind: GraphNodeKind.topic, label: clusters[c].label, cluster: c, size: 2 + math.min(3, math.log(clusters[c].size) * 0.7)));
      for (final m in order[c].value) {
        edges.add(GraphEdge(hub, m, 0.6, GraphEdgeKind.member));
      }
    }
  }
  if (settings.noteHubs) {
    final hubOf = <String, int>{};
    final firstCount = nodes.length;
    for (var i = 0; i < firstCount; i++) {
      final note = nodes[i].noteId;
      if (note == null || nodes[i].kind != GraphNodeKind.fact) continue;
      final hub = hubOf.putIfAbsent(note, () {
        nodes.add(GraphNode(id: 'note:$note', kind: GraphNodeKind.note, label: '', noteId: note, cluster: nodes[i].cluster, size: 1.8));
        return nodes.length - 1;
      });
      edges.add(GraphEdge(hub, i, 0.5, GraphEdgeKind.source));
    }
  }
  return KnowledgeGraph(mode: mode, builtAt: now ?? DateTime.now(), nodes: nodes, edges: edges, clusters: clusters, embedder: embedder);
}

/// Label propagation: every node takes the label that most of its neighbours (by the weight of the edges) have, until nothing
/// changes. A fixed order and ties going to the smaller label make the result the same every time.
List<int> _propagate(int n, List<List<(int, double)>> adjacency) {
  final label = List<int>.generate(n, (i) => i);
  for (var round = 0; round < 25; round++) {
    var changed = 0;
    for (var i = 0; i < n; i++) {
      if (adjacency[i].isEmpty) continue;
      final votes = <int, double>{};
      for (final (j, w) in adjacency[i]) {
        votes[label[j]] = (votes[label[j]] ?? 0) + w;
      }
      var best = label[i];
      var bestWeight = votes[best] ?? 0;
      for (final v in votes.entries) {
        if (v.value > bestWeight + 1e-9 || ((v.value - bestWeight).abs() <= 1e-9 && v.key < best)) {
          best = v.key;
          bestWeight = v.value;
        }
      }
      if (best != label[i]) {
        label[i] = best;
        changed++;
      }
    }
    if (changed == 0) break;
  }
  return label;
}

/// Topics with fewer than [minSize] nodes join the topic their edges lead to most.
void _foldSmall(List<int> label, List<List<(int, double)>> adjacency, int minSize) {
  if (minSize <= 1) return;
  final size = <int, int>{};
  for (final l in label) {
    size[l] = (size[l] ?? 0) + 1;
  }
  for (var i = 0; i < label.length; i++) {
    if ((size[label[i]] ?? 0) >= minSize) continue;
    final votes = <int, double>{};
    for (final (j, w) in adjacency[i]) {
      if ((size[label[j]] ?? 0) >= minSize) votes[label[j]] = (votes[label[j]] ?? 0) + w;
    }
    if (votes.isEmpty) continue;
    final best = (votes.entries.toList()..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key))).first.key;
    size[label[i]] = size[label[i]]! - 1;
    label[i] = best;
    size[best] = size[best]! + 1;
  }
}

/// The three most telling words of each topic: frequent in it, rare in the others.
List<String> _nameTopics(List<GraphInput> inputs, List<GraphNode> nodes, int count) {
  final tf = List<Map<String, double>>.generate(count, (_) => {});
  for (var i = 0; i < inputs.length; i++) {
    final c = nodes[i].cluster;
    if (c < 0) continue;
    for (final w in inputs[i].keywords.expand(telltaleWords)) {
      tf[c][w] = (tf[c][w] ?? 0) + 2;
    }
    for (final w in telltaleWords(inputs[i].label)) {
      tf[c][w] = (tf[c][w] ?? 0) + 1.5;
    }
    for (final w in telltaleWords(inputs[i].detail)) {
      tf[c][w] = (tf[c][w] ?? 0) + 0.3;
    }
  }
  final df = <String, int>{};
  for (final t in tf) {
    for (final w in t.keys) {
      df[w] = (df[w] ?? 0) + 1;
    }
  }
  return [
    for (var c = 0; c < count; c++)
      (() {
        final scored = [for (final e in tf[c].entries) (e.key, e.value * math.log(1 + count / df[e.key]!))]..sort((a, b) {
            final s = b.$2.compareTo(a.$2);
            return s != 0 ? s : a.$1.compareTo(b.$1);
          });
        final top = scored.take(3).map((e) => e.$1).toList();
        return top.isEmpty ? '#${c + 1}' : top.join(', ');
      })(),
  ];
}
