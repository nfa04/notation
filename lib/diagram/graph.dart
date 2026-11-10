// Graphs for the advanced diagrams: read from text, and the usual algorithms run on them (breadth first and depth first, shortest paths,
// spanning tree, cycles, components, topological order).
//
// The text, one statement to a line (`#` starts a comment):
//   A - B            a line between two nodes (a chain works: A - B - C)
//   A -> B           an arrow
//   A -3- B          a line with a weight (A -3-> B, or A - B : 3)
//   D                a node on its own (D, E: several)
//   start: A         where the algorithms begin (the first node otherwise)

class GraphEdge {
  final String from, to;
  final double? weight;
  final bool directed;

  const GraphEdge(this.from, this.to, {this.weight, this.directed = false});
}

class Graph {
  final List<String> nodes;
  final List<GraphEdge> edges;

  /// Where the algorithms begin.
  final String? start;

  const Graph(this.nodes, this.edges, this.start);

  bool get isEmpty => nodes.isEmpty;
  bool get hasDirected => edges.any((e) => e.directed);
  bool get weighted => edges.any((e) => e.weight != null);

  String? get origin => start ?? nodes.firstOrNull;

  /// The nodes reached from [node] along one edge (an undirected one both ways, an arrow its way), with the number of the edge.
  List<(String, int)> neighbours(String node) => [
        for (var i = 0; i < edges.length; i++) ...[
          if (edges[i].from == node) (edges[i].to, i),
          if (edges[i].to == node && !edges[i].directed && edges[i].from != edges[i].to) (edges[i].from, i),
        ],
      ];
}

class GraphReading {
  final Graph graph;
  final List<String> problems;

  const GraphReading(this.graph, this.problems);
}

// (a weight sits between dashes with no space round it: `A -3- B`; `1 - 2 - 3` is a chain of three nodes)
final _arrow = RegExp(r'\s*(<?)-+(?:(\d+(?:\.\d+)?)-+)?(>?)\s*');
final _name = RegExp(r'^[^\s<>,:\-]+$');

GraphReading parseGraph(String text) {
  final nodes = <String>[];
  final edges = <GraphEdge>[];
  final problems = <String>[];
  String? start;
  bool declare(String raw) {
    final n = raw.trim();
    if (!_name.hasMatch(n)) return false;
    if (!nodes.contains(n)) nodes.add(n);
    return true;
  }

  final lines = text.split('\n');
  for (var k = 0; k < lines.length; k++) {
    var line = lines[k].replaceFirst(RegExp(r'\s*(?:#|//).*$'), '').trim();
    if (line.isEmpty) continue;
    final head = RegExp(r'^(?:start|source|from|begin)\s*[:=]\s*(.+)$', caseSensitive: false).firstMatch(line);
    if (head != null) {
      if (declare(head.group(1)!)) {
        start ??= head.group(1)!.trim();
      } else {
        problems.add('line ${k + 1}: $line');
      }
      continue;
    }
    final arrows = _arrow.allMatches(line).toList();
    if (arrows.isEmpty) {
      var bad = false;
      for (final p in line.split(',')) {
        if (p.trim().isNotEmpty && !declare(p)) bad = true;
      }
      if (bad) problems.add('line ${k + 1}: $line');
      continue;
    }
    // `A - B : 3`
    double? tail;
    final colon = line.lastIndexOf(':');
    if (colon > 0 && arrows.length == 1 && colon > arrows.first.end - 1) {
      tail = double.tryParse(line.substring(colon + 1).trim());
      if (tail != null) line = line.substring(0, colon).trim();
    }
    final ms = _arrow.allMatches(line).toList();
    final names = <String>[];
    var from = 0;
    var bad = false;
    for (final m in ms) {
      final n = line.substring(from, m.start).trim();
      if (!declare(n)) bad = true;
      names.add(n);
      from = m.end;
    }
    final last = line.substring(from).trim();
    if (!declare(last)) bad = true;
    names.add(last);
    if (bad) {
      problems.add('line ${k + 1}: $line');
      continue;
    }
    for (var i = 0; i < ms.length; i++) {
      final back = ms[i].group(1)!.isNotEmpty, forward = ms[i].group(3)!.isNotEmpty;
      final w = ms[i].group(2) != null ? double.parse(ms[i].group(2)!) : tail;
      if (back && forward) {
        // (both ways)
        edges..add(GraphEdge(names[i], names[i + 1], weight: w, directed: true))..add(GraphEdge(names[i + 1], names[i], weight: w, directed: true));
      } else if (back) {
        edges.add(GraphEdge(names[i + 1], names[i], weight: w, directed: true));
      } else {
        edges.add(GraphEdge(names[i], names[i + 1], weight: w, directed: forward));
      }
    }
  }
  return GraphReading(Graph(nodes, edges, start), problems);
}

// ---- algorithms ----

/// The order the nodes are reached in from [from] (breadth first), and the edges that were used to reach them.
({List<String> order, Set<int> edges}) breadthFirst(Graph g, String from) {
  final order = [from];
  final used = <int>{};
  final seen = {from};
  for (var i = 0; i < order.length; i++) {
    for (final (n, e) in g.neighbours(order[i])) {
      if (seen.add(n)) {
        order.add(n);
        used.add(e);
      }
    }
  }
  return (order: order, edges: used);
}

({List<String> order, Set<int> edges}) depthFirst(Graph g, String from) {
  final order = <String>[];
  final used = <int>{};
  final seen = <String>{};
  void visit(String n) {
    seen.add(n);
    order.add(n);
    for (final (m, e) in g.neighbours(n)) {
      if (!seen.contains(m)) {
        used.add(e);
        visit(m);
      }
    }
  }

  visit(from);
  return (order: order, edges: used);
}

/// The shortest way from [from] to every node (Dijkstra; an edge without a weight counts 1), or null when a weight is negative. Nodes that
/// cannot be reached are not in the maps. [via] is the edge that leads to a node on its shortest way.
({Map<String, double> distance, Map<String, int> via})? shortestPaths(Graph g, String from) {
  if (g.edges.any((e) => (e.weight ?? 1) < 0)) return null;
  final dist = <String, double>{from: 0};
  final via = <String, int>{};
  final done = <String>{};
  while (true) {
    String? u;
    for (final e in dist.entries) {
      if (!done.contains(e.key) && (u == null || e.value < dist[u]!)) u = e.key;
    }
    if (u == null) break;
    done.add(u);
    for (final (v, e) in g.neighbours(u)) {
      final d = dist[u]! + (g.edges[e].weight ?? 1);
      if (d < (dist[v] ?? double.infinity) - 1e-12) {
        dist[v] = d;
        via[v] = e;
      }
    }
  }
  return (distance: dist, via: via);
}

/// The way from [from] to [to] along the edges of [paths] (null when there is none): the nodes in order.
List<String>? pathTo(Graph g, ({Map<String, double> distance, Map<String, int> via}) paths, String from, String to) {
  if (!paths.distance.containsKey(to)) return null;
  final out = [to];
  var at = to;
  while (at != from) {
    final e = g.edges[paths.via[at]!];
    at = e.from == at ? e.to : e.from;
    out.add(at);
  }
  return out.reversed.toList();
}

/// A minimum spanning tree (forest) by Kruskal, for the edges taken as undirected: the edges and the total weight.
({Set<int> edges, double weight}) spanningTree(Graph g) {
  final order = [for (var i = 0; i < g.edges.length; i++) i]..sort((a, b) => (g.edges[a].weight ?? 1).compareTo(g.edges[b].weight ?? 1));
  final parent = {for (final n in g.nodes) n: n};
  String find(String x) => parent[x] == x ? x : parent[x] = find(parent[x]!);
  final used = <int>{};
  var total = 0.0;
  for (final i in order) {
    final e = g.edges[i];
    final a = find(e.from), b = find(e.to);
    if (a == b) continue;
    parent[a] = b;
    used.add(i);
    total += e.weight ?? 1;
  }
  return (edges: used, weight: total);
}

/// The parts of the graph that hang together (arrows taken as lines).
List<List<String>> components(Graph g) {
  final seen = <String>{};
  final out = <List<String>>[];
  for (final n in g.nodes) {
    if (seen.contains(n)) continue;
    final part = <String>[];
    final todo = [n];
    seen.add(n);
    while (todo.isNotEmpty) {
      final u = todo.removeLast();
      part.add(u);
      for (final e in g.edges) {
        final other = e.from == u ? e.to : (e.to == u ? e.from : null);
        if (other != null && seen.add(other)) todo.add(other);
      }
    }
    part.sort((a, b) => g.nodes.indexOf(a).compareTo(g.nodes.indexOf(b)));
    out.add(part);
  }
  return out;
}

/// Whether there is a way round: back to a node along edges that are not used twice (a line) or along arrows.
bool hasCycle(Graph g) {
  if (g.hasDirected) {
    final colour = <String, int>{}; // 1: on the way, 2: done
    bool visit(String n) {
      colour[n] = 1;
      for (final (m, _) in g.neighbours(n)) {
        if (colour[m] == 1) return true;
        if (colour[m] == null && visit(m)) return true;
      }
      colour[n] = 2;
      return false;
    }

    return g.nodes.any((n) => colour[n] == null && visit(n));
  }
  final seen = <String>{};
  bool visit(String n, int? via) {
    seen.add(n);
    for (final (m, e) in g.neighbours(n)) {
      if (e == via) continue;
      if (seen.contains(m) || visit(m, e)) return true;
    }
    return false;
  }

  return g.nodes.any((n) => !seen.contains(n) && visit(n, null));
}

/// Whether the nodes can be given two colours so that no edge joins two of the same colour (arrows taken as lines).
bool isBipartite(Graph g) {
  final colour = <String, int>{};
  for (final s in g.nodes) {
    if (colour.containsKey(s)) continue;
    colour[s] = 0;
    final todo = [s];
    while (todo.isNotEmpty) {
      final u = todo.removeLast();
      for (final e in g.edges) {
        final v = e.from == u ? e.to : (e.to == u ? e.from : null);
        if (v == null) continue;
        if (!colour.containsKey(v)) {
          colour[v] = 1 - colour[u]!;
          todo.add(v);
        } else if (colour[v] == colour[u]) {
          return false;
        }
      }
    }
  }
  return true;
}

/// The nodes in an order where every arrow goes forward, or null when there is a way round (or no arrows).
List<String>? topologicalOrder(Graph g) {
  if (!g.hasDirected || g.edges.any((e) => !e.directed)) return null;
  final indegree = {for (final n in g.nodes) n: 0};
  for (final e in g.edges) {
    indegree[e.to] = indegree[e.to]! + 1;
  }
  final ready = [for (final n in g.nodes) if (indegree[n] == 0) n];
  final out = <String>[];
  while (ready.isNotEmpty) {
    final u = ready.removeAt(0);
    out.add(u);
    for (final e in g.edges.where((e) => e.from == u)) {
      indegree[e.to] = indegree[e.to]! - 1;
      if (indegree[e.to] == 0) ready.add(e.to);
    }
  }
  return out.length == g.nodes.length ? out : null;
}

/// The strongly connected components (Tarjan), for arrows.
List<List<String>> stronglyConnected(Graph g) {
  var counter = 0;
  final index = <String, int>{}, low = <String, int>{};
  final stack = <String>[];
  final on = <String>{};
  final out = <List<String>>[];
  void visit(String v) {
    index[v] = low[v] = counter++;
    stack.add(v);
    on.add(v);
    for (final (w, _) in g.neighbours(v)) {
      if (!index.containsKey(w)) {
        visit(w);
        low[v] = low[v]! < low[w]! ? low[v]! : low[w]!;
      } else if (on.contains(w)) {
        low[v] = low[v]! < index[w]! ? low[v]! : index[w]!;
      }
    }
    if (low[v] == index[v]) {
      final part = <String>[];
      String w;
      do {
        w = stack.removeLast();
        on.remove(w);
        part.add(w);
      } while (w != v);
      part.sort((a, b) => g.nodes.indexOf(a).compareTo(g.nodes.indexOf(b)));
      out.add(part);
    }
  }

  for (final n in g.nodes) {
    if (!index.containsKey(n)) visit(n);
  }
  out.sort((a, b) => g.nodes.indexOf(a.first).compareTo(g.nodes.indexOf(b.first)));
  return out;
}

String _num(double d) => d == d.roundToDouble() ? '${d.round()}' : '$d';

/// How a weight is written.
String weightText(double d) => _num(d);

/// Things to tell about [g] as (name, value) pairs; [from] is where the algorithms begin.
List<(String, String)> graphFacts(Graph g) {
  if (g.isEmpty) return const [];
  final from = g.origin!;
  final out = <(String, String)>[
    ('Nodes', '${g.nodes.length}'),
    ('Edges', '${g.edges.length}'),
    ('Kind', '${g.hasDirected ? 'directed' : 'undirected'}${g.weighted ? ', weighted' : ''}'),
  ];
  final parts = components(g);
  out.add(('Components', '${parts.length}${parts.length > 1 ? ': ${[for (final p in parts) '{${p.join(', ')}}'].join(' ')}' : ''}'));
  out.add(('Has a cycle', hasCycle(g) ? 'yes' : 'no'));
  out.add(('Bipartite', isBipartite(g) ? 'yes' : 'no'));
  if (g.hasDirected) {
    final topo = topologicalOrder(g);
    out.add(('Topological order', topo == null ? 'none (there is a cycle)' : topo.join(' ')));
    out.add(('Strongly connected', '${stronglyConnected(g).length} parts'));
  } else {
    final degree = [for (final n in g.nodes) '$n: ${g.edges.fold(0, (s, e) => s + (e.from == n ? 1 : 0) + (e.to == n ? 1 : 0))}'];
    out.add(('Degrees', degree.join(', ')));
  }
  out.add(('Start', from));
  out.add(('Breadth first', breadthFirst(g, from).order.join(' ')));
  out.add(('Depth first', depthFirst(g, from).order.join(' ')));
  final paths = shortestPaths(g, from);
  if (paths != null) {
    out.add((
      'Shortest paths',
      [
        for (final n in g.nodes)
          if (n != from) paths.distance.containsKey(n) ? '$n ${_num(paths.distance[n]!)}' : '$n —',
      ].join(', ')
    ));
  } else {
    out.add(('Shortest paths', 'not for negative weights'));
  }
  if (!g.hasDirected) {
    final t = spanningTree(g);
    out.add(('Spanning tree', '${t.edges.length} edges, total ${_num(t.weight)}'));
  }
  return out;
}
