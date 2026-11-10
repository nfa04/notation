import 'dart:convert';
import 'dart:math' as math;

import 'graph_model.dart';

/// A graph written out for other tools: as JSON ([graphToJson]) and as a picture ([graphToSvg]). Both are made from the whole graph as
/// it was kept (not from what the filter of the view shows), and read nothing but the graph and the titles of the notes it is about.

/// What the JSON says it is, so that a reader can tell it from other JSON.
const graphJsonFormat = 'notation-graph';

/// The graph as a JSON text.
///
/// ```
/// { "format": "notation-graph", "version": 1,
///   "name": "...", "kind": "facts" | "notes", "madeAt": "2026-11-08T10:00:00.000", "embedder": "lexical" | "<model>",
///   "topics": [ { "id": 0, "label": "...", "size": 12 } ],
///   "nodes":  [ { "id": "f12", "type": "fact" | "note" | "topic", "label": "...", "detail": "...", "tag": "Definition",
///                 "topic": 0 | null, "note": { "id": "...", "title": "...", "page": 3 }, "x": 10.5, "y": -4, "size": 1.2 } ],
///   "edges":  [ { "source": "f12", "target": "f13", "type": "similar" | "link" | "member" | "source" | "cites" | "contradicts", "weight": 0.71 } ] }
/// ```
///
/// An edge names its two nodes by `id`. `page` counts from 1; `detail`, `tag` and `note` are left out when a node has none, `topic` is
/// null for a node in no topic. [x] and [y] are the places the layout gave the nodes (the picture of the app), [size] how much the node
/// weighs. [noteTitles] (note id to title) fills in the title of the note a node is from.
String graphToJson(KnowledgeGraph graph, {required String name, Map<String, String> noteTitles = const {}}) {
  Map<String, Object?> node(GraphNode n) => {
        'id': n.id,
        'type': n.kind.name,
        'label': n.label,
        if (n.detail.isNotEmpty) 'detail': n.detail,
        if (n.tag != null && n.tag!.isNotEmpty) 'tag': n.tag,
        'topic': n.cluster < 0 ? null : n.cluster,
        if (n.noteId != null)
          'note': {
            'id': n.noteId,
            if (noteTitles[n.noteId] != null) 'title': noteTitles[n.noteId],
            if (n.page != null) 'page': n.page! + 1,
          },
        'x': _round(n.x),
        'y': _round(n.y),
        'size': _round(n.size),
      };
  final edges = <Map<String, Object?>>[];
  for (final e in graph.edges) {
    if (e.a < 0 || e.b < 0 || e.a >= graph.nodes.length || e.b >= graph.nodes.length) continue;
    edges.add({'source': graph.nodes[e.a].id, 'target': graph.nodes[e.b].id, 'type': e.kind.name, 'weight': _round(e.weight)});
  }
  return const JsonEncoder.withIndent('  ').convert({
    'format': graphJsonFormat,
    'version': 1,
    'name': name,
    'kind': graph.mode,
    'madeAt': graph.builtAt.toIso8601String(),
    'embedder': graph.embedder,
    'topics': [for (final c in graph.clusters) {'id': c.id, 'label': c.label, 'size': c.size}],
    'nodes': [for (final n in graph.nodes) node(n)],
    'edges': edges,
  });
}

double _round(double v) => (v * 100).roundToDouble() / 100;

/// The colour of a topic on a white page (the same hues as the view's), as `#rrggbb`.
String topicColor(int cluster) {
  if (cluster < 0) return '#80868b';
  final hue = (cluster * 47.0 + 12) % 360;
  return _hsl(hue, 0.62, 0.46);
}

String _hsl(double h, double s, double l) {
  final c = (1 - (2 * l - 1).abs()) * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = l - c / 2;
  final (r, g, b) = switch (h ~/ 60) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  String hex(double v) => ((v + m) * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${hex(r)}${hex(g)}${hex(b)}';
}

String _xml(String text) => text
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '') // (characters XML cannot carry)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _short(String text, int most) => text.length <= most ? text : '${text.substring(0, most - 1)}…';

String _num(double v) {
  final r = v.toStringAsFixed(1);
  return r.endsWith('.0') ? r.substring(0, r.length - 2) : r;
}

/// The graph as an SVG picture: the lines, the nodes in the colour of their topic (a square for a note among facts, a ring for a topic),
/// the names of the topics and notes beside them (and of every fact while there are not too many to read), and a list of the topics to
/// the right. Each node carries its text as a `<title>`, which a browser shows when the pointer rests on it.
String graphToSvg(KnowledgeGraph graph, {required String name}) {
  const margin = 60.0;
  var minX = 0.0, minY = 0.0, maxX = 100.0, maxY = 100.0;
  if (graph.nodes.isNotEmpty) {
    minX = graph.nodes.map((n) => n.x).reduce(math.min);
    maxX = graph.nodes.map((n) => n.x).reduce(math.max);
    minY = graph.nodes.map((n) => n.y).reduce(math.min);
    maxY = graph.nodes.map((n) => n.y).reduce(math.max);
  }
  // the room for the names beside the nodes on the right edge
  final graphWidth = maxX - minX + 2 * margin + 160;
  final graphHeight = maxY - minY + 2 * margin;
  const legendWidth = 280.0;
  final legendRows = graph.clusters.length.clamp(0, 40);
  final width = graphWidth + legendWidth;
  final height = math.max(graphHeight, 90.0 + legendRows * 22);
  double px(double x) => x - minX + margin;
  double py(double y) => y - minY + margin;

  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${_num(width)} ${_num(height)}" width="${_num(width)}" height="${_num(height)}" font-family="sans-serif">')
    ..writeln('<title>${_xml(name)}</title>')
    ..writeln('<rect width="100%" height="100%" fill="#ffffff"/>');

  // lines first, so that the nodes lie over them; a group for each kind keeps the file small
  String stroke(GraphEdge e) => switch (e.kind) {
        GraphEdgeKind.link => 'stroke="#6750a4" stroke-opacity="0.8" stroke-width="2.2"',
        GraphEdgeKind.cites => 'stroke="#7d5260" stroke-opacity="0.8" stroke-width="2.2"',
        GraphEdgeKind.contradicts => 'stroke="#b3261e" stroke-width="3" stroke-dasharray="6 4"',
        GraphEdgeKind.similar => 'stroke="#1c1b1f" stroke-opacity="${(0.10 + 0.30 * e.weight).clamp(0.0, 1.0).toStringAsFixed(2)}" stroke-width="${(1 + e.weight).toStringAsFixed(2)}"',
        _ => 'stroke="#1c1b1f" stroke-opacity="0.10" stroke-width="1"',
      };
  out.writeln('<g fill="none" stroke-linecap="round">');
  for (final e in graph.edges) {
    if (e.a < 0 || e.b < 0 || e.a >= graph.nodes.length || e.b >= graph.nodes.length) continue;
    final a = graph.nodes[e.a], b = graph.nodes[e.b];
    out.writeln('<line x1="${_num(px(a.x))}" y1="${_num(py(a.y))}" x2="${_num(px(b.x))}" y2="${_num(py(b.y))}" ${stroke(e)}/>');
  }
  out.writeln('</g>');

  final labelAll = graph.nodes.length <= 300;
  out.writeln('<g>');
  for (final n in graph.nodes) {
    final x = px(n.x), y = py(n.y), r = 5.0 * n.size;
    final color = topicColor(n.cluster);
    final tip = _xml(n.detail.isEmpty ? n.label : '${n.label}\n${n.detail}');
    final shape = switch (n.kind) {
      GraphNodeKind.topic => '<circle cx="${_num(x)}" cy="${_num(y)}" r="${_num(r)}" fill="$color" stroke="#ffffff" stroke-width="2">',
      GraphNodeKind.note when graph.mode == 'facts' =>
        '<rect x="${_num(x - r * 0.8)}" y="${_num(y - r * 0.8)}" width="${_num(r * 1.6)}" height="${_num(r * 1.6)}" fill="$color">',
      _ => '<circle cx="${_num(x)}" cy="${_num(y)}" r="${_num(r)}" fill="$color">',
    };
    out.writeln('$shape<title>$tip</title>${shape.startsWith('<rect') ? '</rect>' : '</circle>'}');
    final named = n.kind != GraphNodeKind.fact || labelAll;
    if (named && n.label.isNotEmpty) {
      final topic = n.kind == GraphNodeKind.topic;
      out.writeln('<text x="${_num(x + r + 3)}" y="${_num(y + 3.5)}" font-size="${topic ? 13 : 10}"${topic ? ' font-weight="bold"' : ''} fill="#1c1b1f">${_xml(_short(n.label, 48))}</text>');
    }
  }
  out.writeln('</g>');

  // the topics
  final lx = graphWidth + 10;
  out.writeln('<g>');
  out.writeln('<text x="${_num(lx)}" y="40" font-size="14" font-weight="bold" fill="#1c1b1f">${_xml(_short(name, 34))}</text>');
  var row = 0;
  for (final c in graph.clusters.take(40)) {
    final y = 70.0 + row++ * 22;
    out.writeln('<circle cx="${_num(lx + 6)}" cy="${_num(y - 4)}" r="6" fill="${topicColor(c.id)}"/>');
    out.writeln('<text x="${_num(lx + 20)}" y="${_num(y)}" font-size="12" fill="#1c1b1f">${_xml(_short(c.label, 30))} (${c.size})</text>');
  }
  out.writeln('</g>');
  out.writeln('</svg>');
  return out.toString();
}
