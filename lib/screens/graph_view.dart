import 'dart:math' as math;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../ai/text_provider.dart';
import '../export/file_dialogs.dart';
import '../graph/graph_diff.dart';
import '../graph/graph_export.dart';
import '../graph/graph_filter.dart';
import '../graph/graph_model.dart';
import '../graph/graph_service.dart';
import '../data/card_repository.dart';
import '../data/knowledge_repository.dart' show GraphVersion, SavedGraph;
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../graph/study.dart';
import 'graph_study.dart';
import '../style/platform_dialog.dart';

part 'graph_library.dart';

/// The graphs of the notes or of the facts in them, each kept as a tab, so that one can switch between them without making them again.
/// Making one is up to the person ("Generate graph", "New graph"), because it takes a while.
class GraphView extends StatefulWidget {
  final GraphService service;

  /// Opens a note at a page (zero-based; null: where it was left).
  final void Function(String noteId, int? page) onOpen;

  /// Keeps study cards for spaced repetition; null: not offered.
  final CardRepository? cards;

  const GraphView({super.key, required this.service, required this.onOpen, this.cards});

  @override
  State<GraphView> createState() => _GraphViewState();
}

Color _clusterColor(int cluster, Brightness brightness) {
  if (cluster < 0) return brightness == Brightness.dark ? const Color(0xFF9AA0A6) : const Color(0xFF80868B);
  final hue = (cluster * 47.0 + 12) % 360;
  return HSLColor.fromAHSL(1, hue, 0.62, brightness == Brightness.dark ? 0.62 : 0.46).toColor();
}

/// Asks for a new name of a graph (the controller lives as long as the dialog, which is longer than the pop that closes it).
class _RenameDialog extends StatefulWidget {
  final String name;
  const _RenameDialog(this.name);

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _field = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
    title: Text(tr('Rename the graph')),
    content: TextField(
      key: const ValueKey('graph-rename-field'),
      controller: _field,
      autofocus: true,
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('Cancel')),
      ),
      FilledButton(
        key: const ValueKey('graph-rename-go'),
        onPressed: () => Navigator.pop(context, _field.text),
        child: Text(tr('Rename')),
      ),
    ],
  );
}

class _GraphViewState extends State<GraphView> {
  /// The pictures of the tabs that were opened (null: the kept graph could not be read), by id.
  final Map<int, KnowledgeGraph?> _graphs = {};
  bool _loading = true;
  KnowledgeGraph? _seenMade;

  int _seenFinished = 0;
  bool get _generating => widget.service.runningMode != null;
  String get _what => widget.service.what;
  double? get _done => widget.service.done;
  String? get _problem => widget.service.problem;

  bool _noteHubs = false;

  final _search = TextEditingController();
  int? _selected;
  int? _topic;
  final _controller = TransformationController();
  Size? _fittedFor;

  /// What the graph in front is compared with (and what differs), or null. Belongs to the graph [graphId] as it was when it was set.
  ({String name, GraphDiff diff, int graphId})? _compare;
  ({String name, GraphDiff diff, int graphId})? get _activeCompare => _compare != null && _compare!.graphId == _id ? _compare : null;

  /// What the graph is narrowed to; starts again with another graph.
  GraphFilter _filter = const GraphFilter();
  Map<String, String> _noteTitles = {};
  KnowledgeGraph? _filteredOf;
  GraphFilter? _filteredBy;
  FilteredGraph _filtered = const FilteredGraph(null, []);

  /// The graph through the filter (kept until either changes).
  FilteredGraph _through(KnowledgeGraph g) {
    if (!identical(_filteredOf, g) || _filteredBy != _filter) {
      _filteredOf = g;
      _filteredBy = _filter;
      _filtered = _filter.apply(g);
    }
    return _filtered;
  }

  /// What the canvas was last laid out with, to move the picture to a node.
  Size _viewport = Size.zero;
  Offset _origin = Offset.zero;

  int? get _id => widget.service.selectedId;
  SavedGraph? get _saved =>
      widget.service.graphs.where((g) => g.id == _id).firstOrNull;

  /// What the tab in front is of (the facts, when there is none yet).
  String get _mode => _saved?.mode ?? 'facts';

  KnowledgeGraph? get _graph => _graphs[_id];

  @override
  void initState() {
    super.initState();
    _seenFinished = widget.service.finished;
    _seenMade = widget.service.lastMade;
    widget.service.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    widget.service.removeListener(_changed);
    _search.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await widget.service.refresh (
      force: true,
    ); // (a graph may have come from another device since the list was read)
final made = widget.service.lastMade, madeId = widget.service.lastMadeId;
    if(made != null && madeId != null) _graphs[madeId] = made;
    await _open(_id);
    if (mounted) setState(() => _loading = false);
    // (only the filter by note needs them: the graph is not held up for them)
    final titles = await widget.service.noteTitles();
    if (mounted) setState(() => _noteTitles = titles);
  }

  /// Reads the picture of tab [id] when it has not been read yet.
  Future<void> _open(int? id) async {
    if (id == null || _graphs.containsKey(id)) return;
    final g = await widget.service.load(id);
    _graphs[id] = g;
    if (mounted) setState(() {});
  }

  /// Another tab in front: what was chosen or filtered in the other graph does not carry over.
  void _selectTab(int id) {
    if (id == _id) return;
    widget.service.selectedId = id;
    setState(() {
      _compare = null;
      _selected = null;
      _topic = null;
      _filter = const GraphFilter();
      _fittedFor = null;
    });
    _open(id);
  }

  /// Asks what to make the graph of and how strictly to join things (sliders like the thresholds of OpenKnowledgeBase), then makes it:
  /// a new tab, or, with [again], the same tab made over.
  Future<void> _generate({SavedGraph? again}) async {
    final service = widget.service;
    final folders = await service.folders();
    if (!mounted) return;
    var mode = again?.mode ?? _mode;
    if (again != null) service.folderId = again.folderId;
    if (service.folderId != null && !folders.any((f) => f.id == service.folderId)) service.folderId = null;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setLocal) {
        Widget slider(String label, String hint, double value, double min, double max, int? divisions, String shown, ValueChanged<double> on) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [Expanded(child: Text(label)), Text(shown)]),
                Slider.adaptive(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: (v) => setLocal(() => on(v))),
                Text(hint, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
              ],
            );
        final sim = service.similarity ?? service.defaultSimilarity(mode);
        return PlatformAlertDialog(
          key: const ValueKey('graph-create-dialog'),
          title: Text.verbatim(
              again == null
                  ?tr('Make the graph')
                  : tr('Make "{name}" again', {'name': again.name}),),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (again == null) ...[
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: [
                        ButtonSegment(
                          value: 'facts',
                          label: Text(
                            'Facts',
                            key: const ValueKey('graph-mode-facts'),
                          ),
                        ),
                        ButtonSegment(
                          value: 'notes',
                          label: Text(
                            'Notes',
                            key: const ValueKey('graph-mode-notes'),
                          ),
                        ),
                      ],
                      selected: {mode},
                      onSelectionChanged: (v) => setLocal(() => mode = v.first),
                    ),
                    const SizedBox(height: 16),
                  ],
              Text(tr('Notes to use')),
              DropdownButton<String?>(
                key: const ValueKey('graph-scope'),
                isExpanded: true,
                value: service.folderId,
                items: [
                  DropdownMenuItem(value: null, child: Text(tr('All notes'))),
                  for (final f in folders) DropdownMenuItem(value: f.id, child: Text(f.name)),
                ],
                onChanged: (v) => setLocal(() => service.folderId = v),
              ),
              if (!service.hasSentenceModel)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(tr('No sentence model is installed: topics will follow shared words, not meaning (Settings, AI and models).'), key: const ValueKey('graph-create-lexical'), style: Theme.of(context).textTheme.bodySmall),
                ),
              if (service.canWrite)
                CheckboxListTile.adaptive(
                  key: const ValueKey('graph-name-topics'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: service.nameTopics,
                  onChanged: (v) => setLocal(() => service.nameTopics = v ?? false),
                  title: Text(tr('Name the topics with the AI model')),
                  subtitle: Text(tr('One short request for every 20 topics. A topic that stays about the same keeps its name when the graph is made again.')),
                ),
              if (mode == 'facts')
                CheckboxListTile.adaptive(
                  key: const ValueKey('graph-note-hubs'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _noteHubs,
                  onChanged: (v) => setLocal(() => _noteHubs = v ?? false),
                  title: Text(tr('Show the notes as nodes')),
                  subtitle: Text(tr('Each note becomes a square node joined to the facts taken from it.')),
                ),
              const SizedBox(height: 16),
              slider(tr('Similarity threshold'), tr('Higher: fewer, more certain links.'), sim, 0.2, 0.95, 75, sim.toStringAsFixed(2), (v) => service.similarity = (v * 100).round() / 100),
              slider(tr('Links per node'), tr('The most links one node gets to similar ones.'), service.neighbours.toDouble(), 1, 10, 9, '${service.neighbours}', (v) => service.neighbours = v.round()),
              slider(tr('Smallest topic'), tr('Smaller topics are folded into the nearest bigger one.'), service.minTopicSize.toDouble(), 2, 8, 6, '${service.minTopicSize}', (v) => service.minTopicSize = v.round()),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => setLocal(service.resetTuning), child: Text(tr('Reset'))),
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            FilledButton(key: const ValueKey('graph-create-go'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Generate'))),
          ],
        );
      }),
    );
    if (go == true) await service.start(mode, noteHubs: _noteHubs, replace: again?.id);
  }


  /// Narrows the graph (what is shown, not what is made); changes show at once behind the dialog.
  Future<void> _filterDialog(KnowledgeGraph g) {
    void change(GraphFilter f) {
      setState(() {
        _filter = f;
        final sel = _selected;
        if (sel != null && !_through(g).shows(sel)) _selected = null;
      });
    }

    final tags = ({for (final n in g.nodes) if (n.tag != null) n.tag!}.toList()..sort());
    final edgeKinds = [for (final k in const [GraphEdgeKind.similar, GraphEdgeKind.link, GraphEdgeKind.cites, GraphEdgeKind.contradicts]) if (g.edges.any((e) => e.kind == k)) k];
    final noteIds = ({for (final n in g.nodes) if (n.noteId != null) n.noteId!}.toList()..sort((a, b) => (_noteTitles[a] ?? a).toLowerCase().compareTo((_noteTitles[b] ?? b).toLowerCase())));
    String edgeName(GraphEdgeKind k) => switch (k) {
          GraphEdgeKind.similar => tr('Similar meaning'),
          GraphEdgeKind.link => tr('Links written in notes'),
          GraphEdgeKind.cites => tr('Same source cited'),
          GraphEdgeKind.contradicts => tr('Possible contradictions'),
          _ => '',
        };
    Set<T> toggled<T>(Set<T> set, T v) => set.contains(v) ? ({...set}..remove(v)) : {...set, v};

    return showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setLocal) {
        void update(GraphFilter f) {
          change(f);
          setLocal(() {});
        }

        final f = _filter;
        final hasSimilar = edgeKinds.contains(GraphEdgeKind.similar);
        final hubs = g.nodes.any((n) => n.kind == GraphNodeKind.topic || (n.kind == GraphNodeKind.note && g.mode == 'facts'));
        return PlatformAlertDialog(
          key: const ValueKey('graph-filter-dialog'),
          title: Text(tr('Filter the graph')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (tags.isNotEmpty) ...[
                  Text(tr('Kinds of fact')),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final t in tags)
                      FilterChip(
                        key: ValueKey('graph-filter-tag-$t'),
                        label: Text.verbatim(t),
                        selected: f.tags.contains(t),
                        onSelected: (_) => update(f.copyWith(tags: toggled(f.tags, t))),
                      ),
                  ]),
                  const SizedBox(height: 12),
                ],
                if (edgeKinds.length > 1) ...[
                  Text(tr('Show lines for')),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final k in edgeKinds)
                      FilterChip(
                        key: ValueKey('graph-filter-edge-${k.name}'),
                        label: Text.verbatim(edgeName(k)),
                        selected: !f.hiddenEdges.contains(k),
                        onSelected: (_) => update(f.copyWith(hiddenEdges: toggled(f.hiddenEdges, k))),
                      ),
                  ]),
                  const SizedBox(height: 12),
                ],
                if (hasSimilar && !f.hiddenEdges.contains(GraphEdgeKind.similar)) ...[
                  Row(children: [Expanded(child: Text(tr('Weakest similarity shown'))), Text.verbatim(f.minWeight == 0 ? tr('all') : f.minWeight.toStringAsFixed(2))]),
                  Slider.adaptive(
                    key: const ValueKey('graph-filter-weight'),
                    value: f.minWeight,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    onChanged: (v) => update(f.copyWith(minWeight: (v * 20).round() / 20)),
                  ),
                ],
                if (hubs)
                  SwitchListTile.adaptive(
                    key: const ValueKey('graph-filter-hubs'),
                    contentPadding: EdgeInsets.zero,
                    value: f.hideHubs,
                    onChanged: (v) => update(f.copyWith(hideHubs: v)),
                    title: Text(tr('Hide topics and notes as nodes')),
                    subtitle: Text(tr('Only the facts remain.')),
                  ),
                SwitchListTile.adaptive(
                  key: const ValueKey('graph-filter-loose'),
                  contentPadding: EdgeInsets.zero,
                  value: f.hideLoose,
                  onChanged: (v) => update(f.copyWith(hideLoose: v)),
                  title: Text(tr('Hide nodes without lines')),
                ),
                if (noteIds.length > 1)
                  ExpansionTile(
                    key: const ValueKey('graph-filter-notes'),
                    tilePadding: EdgeInsets.zero,
                    initiallyExpanded: f.notes.isNotEmpty,
                    title: Text(f.notes.isEmpty ? tr('Notes: all') : trCount(f.notes.length, 'Notes: {n} chosen', 'Notes: {n} chosen')),
                    children: [
                      for (final id in noteIds)
                        CheckboxListTile.adaptive(
                          key: ValueKey('graph-filter-note-$id'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: f.notes.contains(id),
                          onChanged: (_) => update(f.copyWith(notes: toggled(f.notes, id))),
                          title: Text.verbatim(_noteTitles[id] ?? id, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(key: const ValueKey('graph-filter-reset'), onPressed: f.active ? () => update(const GraphFilter()) : null, child: Text(tr('Reset'))),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Done'))),
          ],
        );
      }),
    );
  }

  /// The pairs of facts that give different numbers for the same thing, to look at and to open.
  Future<void> _clashDialog(KnowledgeGraph g) {
    final pairs = [for (final e in g.edges) if (e.kind == GraphEdgeKind.contradicts) e];
    Widget side(int i) {
      final n = g.nodes[i];
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text.verbatim(n.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text.verbatim('${n.detail}\n${_noteTitles[n.noteId] ?? ''}', maxLines: 4, overflow: TextOverflow.ellipsis),
        isThreeLine: true,
        onTap: () {
          Navigator.pop(context);
          _select(g, i);
        },
      );
    }

    return showDialog<void>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        key: const ValueKey('graph-clash-dialog'),
        title: Text(tr('Facts that disagree')),
        content: SizedBox(
          width: 520,
          child: ListView(shrinkWrap: true, children: [
            Text(tr('These facts come from different notes, are about the same thing and give different numbers. One of them may be out of date, or both may be right in their own place.'),
                style: Theme.of(context).textTheme.bodySmall),
            for (final e in pairs) ...[
              const Divider(height: 24),
              side(e.a),
              Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.compare_arrows, size: 18, color: Theme.of(context).colorScheme.error)),
              side(e.b),
            ],
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
      ),
    );
  }

  /// The run is the service's; when one ends the graph it made is shown.
  void _changed() {
    if (!mounted) return;
    setState(() {
      if (widget.service.finished != _seenFinished) {
        _seenFinished = widget.service.finished;
        final made =widget.service.lastMade,
            madeId = widget.service.lastMadeId;
        if (made != null && madeId != null && !identical(made, _seenMade)) {
          // (a graph was made: its tab is in front)
          _seenMade = made;
          _graphs[madeId] = made;
        _compare = null;
        _selected = null;
        _topic = null;
        _filter = const GraphFilter();
        _fittedFor = null;
        // made over: say what is new since the picture before
        if (widget.service.lastReplaced == madeId) Future.microtask(() => _compareWithLatestVersion(madeId));
      }
    }
    });
  }

  /// Shows what differs between [before] and the graph in front, under the name [name].
  void _showCompare(String name, KnowledgeGraph before) {
    final now = _graph, id = _id;
    if (now == null || id == null) return;
    setState(() => _compare = (name: name, diff: diffGraphs(before, now), graphId: id));
  }

  /// Compares graph [graphId] (in front) with the picture it had before it was made again last.
  Future<void> _compareWithLatestVersion(int graphId) async {
    final g = widget.service.graphs.where((g) => g.id == graphId).firstOrNull;
    if (g == null) return;
    final versions = await widget.service.versionsOf(g.uid);
    if (versions.isEmpty || !mounted) return;
    final before = await widget.service.loadVersion(versions.first.id);
    if (before == null || !mounted || _id != graphId || _graph == null) return;
    _showCompare(tr('the picture before ({when})', {'when': _ago(versions.first.builtAt)}), before);
  }

  /// Offers what the graph in front can be compared with: its earlier pictures and the other graphs of the same kind.
  Future<void> _pickCompare(SavedGraph g) async {
    final versions = await widget.service.versionsOf(g.uid);
    final others = [for (final o in widget.service.graphs) if (o.id != g.id && o.mode == g.mode) o];
    if (!mounted) return;
    if (versions.isEmpty && others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Nothing to compare with yet: make this graph again, or make a second graph of the same kind.'))));
      return;
    }
    final pick = await showDialog<Object>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const ValueKey('graph-compare-dialog'),
        title: Text(tr('Compare with')),
        children: [
          for (final v in versions)
            SimpleDialogOption(
              key: ValueKey('graph-compare-version-${v.id}'),
              onPressed: () => Navigator.pop(context, v),
              child: Text.verbatim(tr('Earlier picture: {when} ({n} nodes)', {'when': _ago(v.builtAt), 'n': v.nodes})),
            ),
          for (final o in others)
            SimpleDialogOption(
              key: ValueKey('graph-compare-graph-${o.id}'),
              onPressed: () => Navigator.pop(context, o),
              child: Text.verbatim(o.name),
            ),
        ],
      ),
    );
    if (pick is GraphVersion) {
      final before = await widget.service.loadVersion(pick.id);
      if (before != null && mounted) _showCompare(tr('the picture of {when}', {'when': _ago(pick.builtAt)}), before);
    } else if (pick is SavedGraph) {
      final before = _graphs[pick.id] ?? await widget.service.load(pick.id);
      if (before != null && mounted) _showCompare(pick.name, before);
    }
  }

  /// The library: all graphs and their earlier pictures. What it hands back (open, compare) is done here; what it changed itself (renames,
  /// deletions, a picture brought back) is read again.
  Future<void> _openLibrary() async {
    final result = await Navigator.of(context).push<GraphLibraryResult>(MaterialPageRoute(builder: (_) => GraphLibrary(service: widget.service, frontId: _id)));
    if (!mounted) return;
    await widget.service.refresh(force: true);
    _graphs.clear(); // (a picture may have been brought back, a graph renamed or removed: the front one is read again below, the others when opened)
    if (result != null && result.action == GraphLibraryAction.open) widget.service.selectedId = result.graphId;
    setState(() {
      _compare = null;
      _selected = null;
      _topic = null;
      _filter = const GraphFilter();
      _fittedFor = null;
    });
    await _open(_id);
    if (!mounted || result == null) return;
    switch (result.action) {
      case GraphLibraryAction.open:
        break;
      case GraphLibraryAction.compareGraph:
        final other = widget.service.graphs.where((g) => g.id == result.graphId).firstOrNull;
        final before = other == null ? null : (_graphs[other.id] ?? await widget.service.load(other.id));
        if (before != null && other != null && mounted) _showCompare(other.name, before);
      case GraphLibraryAction.compareVersion:
        // (the picture belongs to a graph that is not in front: bring that graph to the front first)
        if (_id != result.graphId) _selectTab(result.graphId);
        await _open(result.graphId);
        final version = result.versionId == null ? null : await widget.service.loadVersion(result.versionId!);
        final when = (await widget.service.allVersions()).where((v) => v.id == result.versionId).firstOrNull;
        if (version != null && mounted && _id == result.graphId) _showCompare(tr('the picture of {when}', {'when': when == null ? '' : _ago(when.builtAt)}), version);
    }
  }

  Widget _compareBanner(BuildContext context, KnowledgeGraph graph, ({String name, GraphDiff diff, int graphId}) c) {
    final scheme = Theme.of(context).colorScheme;
    final d = c.diff;
    return Container(
      key: const ValueKey('graph-compare-banner'),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(Icons.compare_arrows, size: 18, color: scheme.onSecondaryContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text.verbatim(
              d.isEmpty
                  ? tr('Compared with {name}: nothing differs.', {'name': c.name})
                  : tr('Compared with {name}: {added} new, {removed} gone, {changed} changed.', {'name': c.name, 'added': d.added.length, 'removed': d.removed.length, 'changed': d.changed.length}),
              key: const ValueKey('graph-compare-summary'),
              style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
            ),
          ),
        ),
        if (!d.isEmpty) TextButton(key: const ValueKey('graph-compare-changes'), onPressed: () => _changesSheet(graph, c), child: Text(tr('Changes'))),
        IconButton(key: const ValueKey('graph-compare-close'), tooltip: tr('Close'), icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _compare = null)),
      ]),
    );
  }

  /// The list of what differs: new, changed and gone nodes (a new or changed one can be tapped to go to it), and topics that came or went.
  Future<void> _changesSheet(KnowledgeGraph graph, ({String name, GraphDiff diff, int graphId}) c) {
    final d = c.diff;
    const shown = 200;
    Widget heading(String text) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text.verbatim(text, style: Theme.of(context).textTheme.titleSmall));
    List<Widget> nodes(List<int> list) => [
          for (final i in list.take(shown))
            ListTile(
              dense: true,
              title: Text.verbatim(graph.nodes[i].label.isEmpty ? graph.nodes[i].detail : graph.nodes[i].label, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.pop(context);
                _select(graph, i);
              },
            ),
          if (list.length > shown) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(trCount(list.length - shown, '...and {n} more', '...and {n} more'))),
        ];
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scroll) => ListView(
          key: const ValueKey('graph-changes'),
          controller: scroll,
          children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text.verbatim(tr('Compared with {name}', {'name': c.name}), style: Theme.of(context).textTheme.titleMedium)),
            if (d.linesAdded > 0 || d.linesRemoved > 0)
              Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text.verbatim(tr('{added} new links, {removed} links gone between nodes that are in both.', {'added': d.linesAdded, 'removed': d.linesRemoved}))),
            if (d.added.isNotEmpty) ...[heading(tr('New ({n})', {'n': d.added.length})), ...nodes(d.added)],
            if (d.changed.isNotEmpty) ...[heading(tr('Changed ({n})', {'n': d.changed.length})), ...nodes(d.changed)],
            if (d.removed.isNotEmpty) ...[
              heading(tr('Gone ({n})', {'n': d.removed.length})),
              for (final n in d.removed.take(shown))
                ListTile(
                  dense: true,
                  title: Text.verbatim(n.label.isEmpty ? n.detail : n.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: n.detail.isEmpty || n.label.isEmpty ? null : Text.verbatim(n.detail, maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
              if (d.removed.length > shown) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(trCount(d.removed.length - shown, '...and {n} more', '...and {n} more'))),
            ],
            if (d.topicsNew.isNotEmpty) ...[heading(tr('New topics')), for (final t in d.topicsNew.take(shown)) ListTile(dense: true, title: Text.verbatim(t))],
            if (d.topicsGone.isNotEmpty) ...[heading(tr('Topics that are gone')), for (final t in d.topicsGone.take(shown)) ListTile(dense: true, title: Text.verbatim(t))],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(SavedGraph g) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(g.name),
    );
    if (name != null) await widget.service.rename(g.id, name);
  }

  /// Saves the graph of tab [g] as a file: its structure as JSON, or the picture as SVG (the whole graph, not what the filter shows).
  Future<void> _export(SavedGraph g, {required bool svg}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final graph = _graphs[g.id] ?? await widget.service.load(g.id);
      if (graph == null) return;
      final text = svg
          ? graphToSvg(graph, name: g.name)
          : graphToJson(
              graph,
              name: g.name,
              noteTitles: await widget.service.noteTitles(),
            );
      final base = g.name
          .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]+'), '-')
          .trim();
      final path = await saveWithDialog(
        dialogTitle: svg ? tr('Export as SVG') : tr('Export as JSON'),
        fileName: '${base.isEmpty ? 'Graph' : base}.${svg ? 'svg' : 'json'}',
        extension: svg ? 'svg' : 'json',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
      if (path != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text.verbatim(tr('Exported to {path}', {'path': path})),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text.verbatim(
            tr('Could not export the graph: {error}', {'error': e}),
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    }
  }

  Future<void> _delete(SavedGraph g) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text(tr('Delete the graph?')),
        content: Text.verbatim(
          tr(
            '"{name}" is removed. The notes and their facts stay; the graph can be made again.',
            {'name': g.name},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            key: const ValueKey('graph-delete-go'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await widget.service.remove(g.id);
    if (!mounted) return;
    _graphs.remove(g.id);
    setState(() {
      _compare = null;
      _selected = null;
      _topic = null;
      _filter = const GraphFilter();
      _fittedFor = null;
    });
    _open(_id);
  }

  /// The tabs: one per kept graph (the one in front has a menu to rename, make again and delete it) and a button for a new one.
  Widget _tabs(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saved = widget.service.graphs;
    return SizedBox(
      height: 48,
      child: ListView(
        key: const ValueKey('graph-tabs'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final g in saved)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Semantics(
                selected: g.id == _id,
                button: true,
                child: Material(
                  color: g.id == _id
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                  shape: StadiumBorder(
                    side: BorderSide(
                      color: g.id == _id
                          ? Colors.transparent
                          : scheme.outlineVariant,
                    ),
                  ),
                  child: InkWell(
                    key: ValueKey('graph-tab-${g.id}'),
                    customBorder: const StadiumBorder(),
                    onTap: () => _selectTab(g.id),
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: 12,
                        right: g.id == _id ? 2 : 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            g.mode == 'notes'
                                ? Icons.description_outlined
                                : Icons.lightbulb_outline,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 220),
                            child: Text.verbatim(
                              g.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (g.id == _id)
                            PopupMenuButton<String>(
                              key: const ValueKey('graph-tab-menu'),
                              tooltip: tr('This graph'),
                              padding: EdgeInsets.zero,
                              iconSize: 18,
                              icon: const Icon(Icons.more_vert),
                              onSelected: (v) {
                                switch (v) {
                                  case 'rename':
                                    _rename(g);
                                  case 'again':
                                    _generate(again: g);
                                  case 'compare':
                                    _pickCompare(g);
                                  case 'json':
                                    _export(g, svg: false);
                                  case 'svg':
                                    _export(g, svg: true);
                                  case 'delete':
                                    _delete(g);
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  key: const ValueKey('graph-tab-rename'),
                                  value: 'rename',
                                  child: Text(tr('Rename')),
                                ),
                                PopupMenuItem(
                                  key: const ValueKey('graph-tab-again'),
                                  value: 'again',
                                  enabled: !_generating,
                                  child: Text(tr('Generate again')),
                                ),
                                PopupMenuItem(
                                  key: const ValueKey('graph-tab-compare'),
                                  value: 'compare',
                                  child: Text(tr('Compare with...')),
                                ),
                                PopupMenuItem(
                                  key: const ValueKey('graph-tab-json'),
                                  value: 'json',
                                  child: Text(tr('Export as JSON')),
                                ),
                                PopupMenuItem(
                                  key: const ValueKey('graph-tab-svg'),
                                  value: 'svg',
                                  child: Text(tr('Export as SVG')),
                                ),
                                PopupMenuItem(
                                  key: const ValueKey('graph-tab-delete'),
                                  value: 'delete',
                                  child: Text(tr('Delete')),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          IconButton(
            key: const ValueKey('graph-new'),
            tooltip: tr('Make a new graph'),
            icon: const Icon(Icons.add),
            visualDensity: VisualDensity.compact,
            onPressed: _generating ? null : _generate,
          ),
        ],
      ),);
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return tr('just now');
    if (d.inMinutes < 60) return tr('{n} mins ago', {'n': d.inMinutes});
    if (d.inHours < 24) return tr('{n} hours ago', {'n': d.inHours});
    return tr('{n} days ago', {'n': d.inDays});
  }

  /// The nodes that match the search or the chosen topic; null when everything shows.
  Set<int>? _lit(KnowledgeGraph g) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty && _topic == null) return null;
    final f = _through(g);
    return {
      for (var i = 0; i < g.nodes.length; i++)
        if (f.shows(i) && (q.isEmpty || '${g.nodes[i].label} ${g.nodes[i].detail}'.toLowerCase().contains(q)) && (_topic == null || g.nodes[i].cluster == _topic)) i,
    };
  }

  /// What stands out: the matches of the search or the topic, else the chosen node with the nodes joined to it (null: everything).
  Set<int>? _focus(KnowledgeGraph g) {
    final lit = _lit(g);
    final i = _selected;
    if (lit != null || i == null || i >= g.nodes.length) return lit;
    return {
      i,
      for (final e in _through(g).edges)
        if (e.a == i) e.b else if (e.b == i) e.a,
    };
  }

  /// Chooses node [i] and moves the picture to it when it is out of sight (zoomed in enough to read it).
  void _select(KnowledgeGraph g, int i) {
    setState(() => _selected = i);
    if (_viewport.isEmpty) return;
    final n = g.nodes[i];
    final scale = math.max(_controller.value.getMaxScaleOnAxis(), 0.7);
    _controller.value = Matrix4.identity()
      ..translateByDouble(_viewport.width / 2 - scale * (n.x - _origin.dx), _viewport.height / 2 - scale * (n.y - _origin.dy), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// Enter in the search: goes to the first match.
  void _goToFirstMatch(KnowledgeGraph g) {
    final lit = _lit(g);
    if (lit == null || lit.isEmpty) return;
    _select(g, (lit.toList()..sort()).first);
  }

  @override
  Widget build(BuildContext context) {
    final graph = _graph;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Graph', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_mode == 'facts' && widget.service.ai != null && widget.service.ai!.providers.length > 1)
            PopupMenuButton<String>(
              key: const ValueKey('graph-provider'),
              tooltip: tr('Who writes the facts (the model is chosen in the Settings)'),
              icon: const Icon(Icons.swap_horiz),
              enabled: !_generating,
              onSelected: widget.service.ai!.chooseProvider,
              itemBuilder: (context) => [
                for (final p in widget.service.ai!.providers)
                  CheckedPopupMenuItem(value: p.id, checked: p.id == widget.service.ai!.provider?.id, enabled: p.state != ProviderState.unavailable, child: Text(p.label)),
              ],
            ),
          if (widget.service.graphs.isNotEmpty)
            IconButton(key: const ValueKey('graph-library'), tooltip: tr('Graph library'), icon: const Icon(Icons.collections_bookmark_outlined), onPressed: _openLibrary),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : Column(
              children: [
                if (widget.service.graphs.isNotEmpty) _tabs(context),
                if (_generating || widget.service.graphs.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  // (a row that wraps: the buttons do not fit side by side on a phone, or with big text)
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_generating)
                          TextButton.icon(key: const ValueKey('graph-stop'), onPressed: widget.service.stop, icon: const Icon(Icons.stop), label: const Text('Stop'))
                        else if (widget.service.graphs.isEmpty)
                          FilledButton.icon(
                            key: const ValueKey('graph-generate'),
                            onPressed: _generate,
                            icon: const Icon(Icons.hub_outlined, size: 18),
                            label: const Text( 'Generate graph'),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_generating)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: _done),
                        const SizedBox(height: 4),
                        Text.verbatim(
                          _what,
                          key: const ValueKey('graph-progress'),
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                if (_mode == 'facts')
                  ListenableBuilder(
                    listenable: widget.service.ai ?? widget.service,
                    builder: (context, _) => Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text.verbatim(
                          widget.service.canWrite ? tr('Facts are written by: {model}', {'model': widget.service.writerName}) : tr('No AI model is ready to write the facts.'),
                          key: const ValueKey('graph-writer'),
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ),
                if (!_generating && widget.service.notice != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Text.verbatim(
                      widget.service.notice!,
                      key: const ValueKey('graph-notice'),
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (_problem != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text.verbatim(
                      _problem!,
                      key: const ValueKey('graph-problem'),
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                Expanded(child: _id != null && !_graphs.containsKey(_id)
                      ? const Center(
                          child: CircularProgressIndicator.adaptive(),
                        )
                      : graph == null || graph.isEmpty ? _empty(context) : _body(context, graph)),
              ],
            ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub_outlined, size: 48, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text.verbatim(
                tr(
                    widget.service.graphs.isEmpty
                        ? 'A graph shows what your notes say, grouped by topic (facts), or which notes belong together (notes). Making one reads all notes, so it is not made on its own; each one is kept as a tab.'
                        :
                  _mode == 'facts'
                      ? 'The graph of facts shows what your notes say, grouped by topic. Making it reads all notes, so it is not made on its own.'
                      : 'The graph of notes shows which notes belong together and which link to each other. It is not made on its own.',
                ),
                textAlign: TextAlign.center,
                key: const ValueKey('graph-empty'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        )),
      ),
    );
  }

  Widget _body(BuildContext context, KnowledgeGraph graph) {
    final scheme = Theme.of(context).colorScheme;
    final lit = _focus(graph);
    final matches = _lit(graph);
    final phone = MediaQuery.sizeOf(context).width < 700;
    final main = Expanded(
          flex: 3,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('graph-search'),
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _goToFirstMatch(graph),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixText: _search.text.trim().isEmpty ? null : trCount(matches?.length ?? 0, '{n} match', '{n} matches'),
                          hintText: tr('Find in the graph'),
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text.verbatim(
                      '${trCount(_through(graph).count(graph), '{n} node', '{n} nodes')}${_filter.active ? ' / ${graph.nodes.length}' : ''}  -  ${trCount(graph.clusters.length, '{n} topic', '{n} topics')}  -  ${_ago(graph.builtAt)}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    if (graph.edges.any((e) => e.kind == GraphEdgeKind.contradicts))
                      IconButton(
                        key: const ValueKey('graph-clashes'),
                        tooltip: tr('Facts that disagree'),
                        icon: Badge(label: Text.verbatim('${graph.edges.where((e) => e.kind == GraphEdgeKind.contradicts).length}'), child: Icon(Icons.warning_amber_rounded, color: scheme.error)),
                        onPressed: () => _clashDialog(graph),
                      ),
                    IconButton(
                      key: const ValueKey('graph-filter'),
                      tooltip: tr('Filter the graph'),
                      icon: Badge(isLabelVisible: _filter.active, label: Text.verbatim('${_filter.count}'), child: const Icon(Icons.filter_list)),
                      onPressed: () => _filterDialog(graph),
                    ),
                    IconButton(tooltip: tr('Show everything'), icon: const Icon(Icons.fit_screen_outlined), onPressed: () => setState(() => _fittedFor = null)),
                  ],
                ),
              ),
              if (_activeCompare != null) _compareBanner(context, graph, _activeCompare!),
              if (graph.embedder == 'lexical')
                // (the picture says how it was made; whether the model is there now is asked again when the model's state changes)
                ListenableBuilder(
                  listenable: (widget.service.embedder is Listenable ? widget.service.embedder as Listenable : null) ?? widget.service,
                  builder: (context, _) {
                    final now = widget.service.hasSentenceModel;
                    return Container(
                      key: ValueKey(now ? 'graph-lexical-stale' : 'graph-lexical'),
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                      decoration: BoxDecoration(color: scheme.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
                      child: Row(children: [
                        Icon(Icons.info_outline, size: 16, color: scheme.onTertiaryContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tr(now
                                ? 'This graph was made before the sentence model was installed, so its topics follow shared words. Make it again to use the model.'
                                : 'Made from the words alone, so topics follow shared words, not meaning. Install the sentence model (Settings, AI and models) and make the graph again for better topics.'),
                            style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
                          ),
                        ),
                        if (now && _saved != null)
                          TextButton(key: const ValueKey('graph-lexical-again'), onPressed: _generating ? null : () => _generate(again: _saved), child: Text(tr('Generate again'))),
                      ]),
                    );
                  },
                ),
              Expanded(child: _canvas(context, graph, lit)),
            ],
          ),
        );
    // a phone has no room beside the picture: what is known about the chosen note goes under it
    if (phone) return Column(children: [main, const Divider(height: 1), Expanded(flex: 2, child: _side(context, graph))]);
    return Row(children: [main, const VerticalDivider(width: 1), SizedBox(width: 300, child: _side(context, graph))]);
  }

  Widget _canvas(BuildContext context, KnowledgeGraph g, Set<int>? lit) {
    final minX = g.nodes.map((n) => n.x).reduce(math.min) - 80, maxX = g.nodes.map((n) => n.x).reduce(math.max) + 80;
    final minY = g.nodes.map((n) => n.y).reduce(math.min) - 80, maxY = g.nodes.map((n) => n.y).reduce(math.max) + 80;
    final size = Size(maxX - minX, maxY - minY);
    _origin = Offset(minX, minY);
    return LayoutBuilder(
      builder: (context, box) {
        _viewport = box.biggest;
        if (_fittedFor != box.biggest || _fittedFor == null) {
          final scale = math.min(box.maxWidth / size.width, box.maxHeight / size.height).clamp(0.05, 2.0);
          _controller.value = Matrix4.identity()
            ..translateByDouble((box.maxWidth - size.width * scale) / 2, (box.maxHeight - size.height * scale) / 2, 0, 1)
            ..scaleByDouble(scale, scale, 1, 1);
          _fittedFor = box.biggest;
        }
        return ClipRect(
          child: InteractiveViewer(
            key: const ValueKey('graph-canvas'),
            transformationController: _controller,
            constrained: false,
            minScale: 0.05,
            maxScale: 8,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => setState(() => _selected = _hit(g, d.localPosition + Offset(minX, minY))),
              child: RepaintBoundary(
                child: CustomPaint(
                  size: size,
                  painter: _GraphPainter(g, _through(g), Offset(minX, minY), _controller, _selected, lit, Theme.of(context).colorScheme, Theme.of(context).brightness, added: _activeCompare == null ? null : {..._activeCompare!.diff.added}, changed: _activeCompare == null ? null : {..._activeCompare!.diff.changed}),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  int? _hit(KnowledgeGraph g, Offset p) {
    final scale = _controller.value.getMaxScaleOnAxis();
    int? best;
    var bestDistance = double.infinity;
    final f = _through(g);
    for (var i = 0; i < g.nodes.length; i++) {
      if (!f.shows(i)) continue;
      final n = g.nodes[i];
      final d = (Offset(n.x, n.y) - p).distance;
      final reach = 5.0 * n.size + 8 / scale;
      if (d <= reach && d < bestDistance) {
        best = i;
        bestDistance = d;
      }
    }
    return best;
  }

  /// The facts of a topic (or of all of the graph when [cluster] is null), as the study tools read them.
  List<StudyFact> _factsOf(KnowledgeGraph g, int? cluster) => [
    for (final n in g.nodes)
      if (n.kind == GraphNodeKind.fact && n.detail.isNotEmpty && (cluster == null || n.cluster == cluster)) StudyFact(n.label, n.detail),
  ];

  Widget _studyButtons(KnowledgeGraph g, int? cluster, String title) {
    if (g.mode != 'facts') return const SizedBox.shrink();
    final facts = _factsOf(g, cluster);
    if (facts.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (tool, icon, label) in [
          (StudyTool.cards, Icons.style_outlined, 'Flashcards'),
          (StudyTool.quiz, Icons.quiz_outlined, 'Quiz'),
          (StudyTool.ask, Icons.question_answer_outlined, 'Ask'),
        ])
          OutlinedButton.icon(
            key: ValueKey('graph-study-${tool.name}'),
            onPressed: () => showGraphStudy(context, service: widget.service, cards: widget.cards, title: title, facts: facts, tool: tool),
            icon: Icon(icon, size: 16),
            label: Text(label),
          ),
      ],
    );
  }

  Widget _side(BuildContext context, KnowledgeGraph g) {
    final scheme = Theme.of(context).colorScheme;
    final i = _selected;
    if (i != null && i < g.nodes.length) {
      final n = g.nodes[i];
      final neighbours = <int>[
        for (final e in _through(g).edges)
          if (e.a == i) e.b else if (e.b == i) e.a,
      ];
      return ListView(
        key: const ValueKey('graph-details'),
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(child: Text.verbatim(n.label, style: Theme.of(context).textTheme.titleMedium)),
              IconButton(tooltip: tr('Close'), icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _selected = null)),
            ],
          ),
          if (n.tag != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Chip(label: Text.verbatim(n.tag!), visualDensity: VisualDensity.compact),
            ),
          if (n.detail.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: SelectableText(n.detail)),
          for (final e in g.edges)
            if (e.kind == GraphEdgeKind.contradicts && (e.a == i || e.b == i))
              Card(
                key: const ValueKey('graph-clash'),
                color: scheme.errorContainer,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.warning_amber_rounded, color: scheme.error),
                  title: Text(tr('Says something else in {note}', {'note': _noteTitles[g.nodes[e.a == i ? e.b : e.a].noteId] ?? tr('another note')})),
                  subtitle: Text.verbatim(g.nodes[e.a == i ? e.b : e.a].detail, maxLines: 4, overflow: TextOverflow.ellipsis),
                  onTap: () => _select(g, e.a == i ? e.b : e.a),
                ),
              ),
          if (n.cluster >= 0 && n.cluster < g.clusters.length)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text.verbatim('${tr('Topic')}: ${g.clusters[n.cluster].label}', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ),
          if (n.noteId != null)
            FilledButton.tonalIcon(
              key: const ValueKey('graph-open-note'),
              onPressed: () => widget.onOpen(n.noteId!, n.page),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(n.page == null ? 'Open the note' : 'Open the note at the page'),
            ),
          if (n.kind == GraphNodeKind.topic) FilledButton.tonal(onPressed: () => setState(() => _topic = n.cluster), child: const Text('Show only this topic')),
          if (n.kind == GraphNodeKind.topic) Padding(padding: const EdgeInsets.only(top: 8), child: _studyButtons(g, n.cluster, n.label)),
          if (neighbours.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(trCount(neighbours.length, 'Joined to {n} node', 'Joined to {n} nodes'), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            for (final j in neighbours.take(12))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(radius: 5, backgroundColor: _clusterColor(g.nodes[j].cluster, Theme.of(context).brightness)),
                title: Text.verbatim(g.nodes[j].label, maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => _select(g, j),
              ),
          ],
        ],
      );
    }
    return ListView(
      key: const ValueKey('graph-topics'),
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(child: Text('Topics', style: Theme.of(context).textTheme.titleSmall)),
            if (_topic != null) TextButton(key: const ValueKey('graph-all-topics'), onPressed: () => setState(() => _topic = null), child: const Text('All')),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _studyButtons(g, _topic, _topic != null && _topic! < g.clusters.length ? g.clusters[_topic!].label : tr('All facts')),
        ),
        for (final c in g.clusters.take(60))
          ListTile(
            key: ValueKey('graph-topic-${c.id}'),
            dense: true,
            selected: _topic == c.id,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 6, backgroundColor: _clusterColor(c.id, Theme.of(context).brightness)),
            title: Text.verbatim(c.label, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Text.verbatim('${c.size}', style: TextStyle(color: scheme.onSurfaceVariant)),
            onTap: () => setState(() => _topic = _topic == c.id ? null : c.id),
          ),
      ],
    );
  }
}

bool _sameSet(Set<int>? a, Set<int>? b) => a == null || b == null ? a == b : a.length == b.length && a.containsAll(b);

class _GraphPainter extends CustomPainter {
  final KnowledgeGraph graph;
  final FilteredGraph filtered;
  final Offset origin;
  final TransformationController controller;
  final int? selected;
  final Set<int>? lit;
  final ColorScheme scheme;
  final Brightness brightness;

  /// Nodes that are new, or changed, against what the graph is compared with (ringed), when it is compared.
  final Set<int>? added, changed;

  _GraphPainter(this.graph, this.filtered, this.origin, this.controller, this.selected, this.lit, this.scheme, this.brightness, {this.added, this.changed}) : super(repaint: controller);

  static final _labels = <String, TextPainter>{};

  /// The nodes from the biggest to the smallest, worked out once per graph (the painter is made again at every change, and paints at every pan).
  static final _importance = Expando<List<int>>();

  TextPainter _label(String text, double size, Color color, {bool bold = false}) {
    final key = '$text|${size.round()}|${color.toARGB32()}|$bold';
    return _labels.putIfAbsent(key, () {
      if (_labels.length > 800) _labels.clear();
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.bold : FontWeight.normal),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: size * 14);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = controller.value.getMaxScaleOnAxis();
    canvas.translate(-origin.dx, -origin.dy);
    final dim = lit != null;
    bool on(int i) => !dim || lit!.contains(i);

    // edges: when zoomed out only the stronger ones
    final minWeight = scale < 0.3 ? 0.75 : (scale < 0.6 ? 0.6 : 0.0);
    final edgePaint = Paint()..style = PaintingStyle.stroke;
    for (final e in filtered.edges) {
      if (e.kind == GraphEdgeKind.similar && e.weight < minWeight) continue;
      final a = graph.nodes[e.a], b = graph.nodes[e.b];
      final active = on(e.a) && on(e.b);
      final touches = selected != null && (e.a == selected || e.b == selected);
      var color = switch (e.kind) {
        GraphEdgeKind.link => scheme.primary,
        GraphEdgeKind.cites => scheme.tertiary,
        GraphEdgeKind.contradicts => scheme.error,
        GraphEdgeKind.similar => scheme.onSurface.withValues(alpha: 0.10 + 0.30 * e.weight),
        _ => scheme.onSurface.withValues(alpha: 0.10),
      };
      if (!active) color = color.withValues(alpha: color.a * 0.15);
      if (touches && e.kind != GraphEdgeKind.contradicts) color = scheme.primary;
      edgePaint
        ..color = color
        ..strokeWidth = (e.kind == GraphEdgeKind.contradicts ? 3.0 : e.kind == GraphEdgeKind.link || e.kind == GraphEdgeKind.cites || touches ? 2.2 : 1.0 + e.weight) / math.max(scale, 0.5);
      canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), edgePaint);
    }

    final fill = Paint();
    for (var i = 0; i < graph.nodes.length; i++) {
      if (!filtered.shows(i)) continue;
      final n = graph.nodes[i];
      final base = _clusterColor(n.cluster, brightness);
      fill.color = on(i) ? base : base.withValues(alpha: 0.18);
      final r = 5.0 * n.size;
      final p = Offset(n.x, n.y);
      if (n.kind == GraphNodeKind.topic) {
        canvas.drawCircle(p, r, fill);
        canvas.drawCircle(
          p,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 / math.max(scale, 0.5)
            ..color = scheme.surface,
        );
      } else if (n.kind == GraphNodeKind.note && graph.mode == 'facts') {
        canvas.drawRect(Rect.fromCenter(center: p, width: r * 1.6, height: r * 1.6), fill);
      } else {
        canvas.drawCircle(p, r, fill);
      }
      final ring = (added?.contains(i) ?? false) ? (brightness == Brightness.dark ? const Color(0xFF5BD68A) : const Color(0xFF1E8E4E)) : ((changed?.contains(i) ?? false) ? (brightness == Brightness.dark ? const Color(0xFFFFC53D) : const Color(0xFFC47F00)) : null);
      if (ring != null) {
        canvas.drawCircle(
          p,
          r + 3 / math.max(scale, 0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5 / math.max(scale, 0.5)
            ..color = on(i) ? ring : ring.withValues(alpha: 0.3),
        );
      }
      if (i == selected) {
        canvas.drawCircle(
          p,
          r + 4 / math.max(scale, 0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5 / math.max(scale, 0.5)
            ..color = scheme.onSurface,
        );
      }
    }

    // labels at a size that does not change with the zoom; few when far away
    final fontSize = 12 / math.max(scale, 0.35);
    final labelled = <Rect>[];
    void label(int i, {bool bold = false, bool force = false}) {
      final n = graph.nodes[i];
      if (n.label.isEmpty) return;
      final tp = _label(n.label, fontSize, on(i) ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.25), bold: bold);
      final at = Offset(n.x + 5.0 * n.size + 2, n.y - tp.height / 2);
      final rect = (at & tp.size).inflate(2);
      if (!force && labelled.any(rect.overlaps)) return;
      labelled.add(rect);
      tp.paint(canvas, at);
    }

    final byImportance = _importance[graph] ??= ([for (var i = 0; i < graph.nodes.length; i++) i]..sort((a, b) => graph.nodes[b].size.compareTo(graph.nodes[a].size)));
    for (final i in byImportance) {
      final n = graph.nodes[i];
      final show = n.kind == GraphNodeKind.topic ? scale > 0.2 : (graph.mode == 'notes' ? scale > 0.35 : scale > 0.9);
      if (show && filtered.shows(i) && on(i) && i != selected) label(i, bold: n.kind == GraphNodeKind.topic);
    }
    if (selected != null) label(selected!, bold: true, force: true);
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) => old.graph != graph || !_sameSet(old.added, added) || !_sameSet(old.changed, changed) || old.filtered != filtered || old.selected != selected || old.lit != lit || old.brightness != brightness;
}
