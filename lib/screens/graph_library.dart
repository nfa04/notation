part of 'graph_view.dart';

/// What the library asks the graph view to do when it closes.
enum GraphLibraryAction {
  /// Bring the graph [GraphLibraryResult.graphId] to the front.
  open,

  /// Compare the graph in front with the earlier picture [GraphLibraryResult.versionId] of graph [GraphLibraryResult.graphId].
  compareVersion,

  /// Compare the graph in front with the graph [GraphLibraryResult.graphId].
  compareGraph,
}

class GraphLibraryResult {
  final GraphLibraryAction action;
  final int graphId;
  final int? versionId;
  const GraphLibraryResult(this.action, this.graphId, [this.versionId]);
}

/// Every graph that is kept, with the earlier pictures of each (what it was before it was made again): to open, rename, delete, compare
/// and go back to. The graph view has the graphs as tabs; this is the whole shelf, with what the tabs do not show.
class GraphLibrary extends StatefulWidget {
  final GraphService service;

  /// The graph in front in the view (the one the others are compared with), and its kind.
  final int? frontId;

  const GraphLibrary({super.key, required this.service, required this.frontId});

  @override
  State<GraphLibrary> createState() => _GraphLibraryState();
}

class _GraphLibraryState extends State<GraphLibrary> {
  List<GraphVersion> _versions = const [];
  Map<String, String> _folders = {};
  bool _loading = true;

  GraphService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _service.refresh(force: true);
    final versions = await _service.allVersions();
    final folders = {for (final f in await _service.folders()) f.id: f.name};
    if (!mounted) return;
    setState(() {
      _versions = versions;
      _folders = folders;
      _loading = false;
    });
  }

  SavedGraph? get _front => _service.graphs.where((g) => g.id == widget.frontId).firstOrNull;

  String _scope(SavedGraph g) => g.folderId == null ? tr('All notes') : (_folders[g.folderId] ?? tr('All notes'));

  Future<bool> _sure(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => PlatformAlertDialog(
          title: Text(title),
          content: Text.verbatim(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            FilledButton(key: const ValueKey('graph-library-confirm'), onPressed: () => Navigator.pop(context, true), child: Text(tr('Delete'))),
          ],
        ),
      ) ==
      true;

  Future<void> _rename(SavedGraph g) async {
    final name = await showDialog<String>(context: context, builder: (context) => _RenameDialog(g.name));
    if (name == null) return;
    await _service.rename(g.id, name);
    await _load();
  }

  Future<void> _delete(SavedGraph g) async {
    if (!await _sure(tr('Delete the graph?'), tr('"{name}" is removed. The notes and their facts stay; the graph can be made again.', {'name': g.name}))) return;
    await _service.remove(g.id);
    await _load();
  }

  Future<void> _deleteVersion(GraphVersion v) async {
    if (!await _sure(tr('Delete this earlier picture?'), tr('The picture of {when} is removed. The graph itself stays.', {'when': _GraphViewState._ago(v.builtAt)}))) return;
    await _service.deleteVersion(v.id);
    await _load();
  }

  Future<void> _restore(GraphVersion v, SavedGraph g) async {
    final id = await _service.restoreVersion(v.id);
    if (!mounted) return;
    if (id == null) {
      await _load();
      return;
    }
    Navigator.pop(context, GraphLibraryResult(GraphLibraryAction.open, id));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final graphs = _service.graphs;
    final front = _front;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Graph library'), style: const TextStyle(fontWeight: FontWeight.bold))),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : graphs.isEmpty
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(tr('No graphs are kept yet. Make one in the graph view.'), key: const ValueKey('graph-library-empty'), textAlign: TextAlign.center)))
              : ListView(
                  key: const ValueKey('graph-library-list'),
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final g in graphs.reversed)
                      Card(
                        key: ValueKey('graph-library-${g.id}'),
                        child: ExpansionTile(
                          shape: const Border(),
                          collapsedShape: const Border(),
                          leading: Icon(g.mode == 'notes' ? Icons.description_outlined : Icons.lightbulb_outline),
                          title: Text.verbatim(g.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: g.id == widget.frontId ? const TextStyle(fontWeight: FontWeight.bold) : null),
                          subtitle: Text.verbatim(
                            '${g.mode == 'notes' ? tr('Notes') : tr('Facts')} - ${_scope(g)} - ${_GraphViewState._ago(g.builtAt)}'
                            '${_versions.where((v) => v.graphUid == g.uid).isEmpty ? '' : ' - ${trCount(_versions.where((v) => v.graphUid == g.uid).length, '{n} earlier picture', '{n} earlier pictures')}'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: PopupMenuButton<String>(
                            key: ValueKey('graph-library-menu-${g.id}'),
                            tooltip: tr('This graph'),
                            onSelected: (v) {
                              switch (v) {
                                case 'open':
                                  Navigator.pop(context, GraphLibraryResult(GraphLibraryAction.open, g.id));
                                case 'compare':
                                  Navigator.pop(context, GraphLibraryResult(GraphLibraryAction.compareGraph, g.id));
                                case 'rename':
                                  _rename(g);
                                case 'delete':
                                  _delete(g);
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(key: ValueKey('graph-library-open-${g.id}'), value: 'open', child: Text(tr('Open'))),
                              if (front != null && front.id != g.id && front.mode == g.mode)
                                PopupMenuItem(key: ValueKey('graph-library-compare-${g.id}'), value: 'compare', child: Text(tr('Compare the graph in front with this one'))),
                              PopupMenuItem(value: 'rename', child: Text(tr('Rename'))),
                              PopupMenuItem(key: ValueKey('graph-library-delete-${g.id}'), value: 'delete', child: Text(tr('Delete'))),
                            ],
                          ),
                          children: [
                            for (final v in _versions.where((v) => v.graphUid == g.uid))
                              ListTile(
                                key: ValueKey('graph-version-${v.id}'),
                                dense: true,
                                contentPadding: const EdgeInsets.only(left: 72, right: 8),
                                title: Text.verbatim(tr('Picture of {when}', {'when': _GraphViewState._ago(v.builtAt)})),
                                subtitle: Text.verbatim(trCount(v.nodes, '{n} node', '{n} nodes'), style: TextStyle(color: scheme.onSurfaceVariant)),
                                trailing: Wrap(
                                  children: [
                                    IconButton(
                                      key: ValueKey('graph-version-compare-${v.id}'),
                                      tooltip: tr('Compare with the graph as it is now'),
                                      icon: const Icon(Icons.compare_arrows),
                                      onPressed: () => Navigator.pop(context, GraphLibraryResult(GraphLibraryAction.compareVersion, g.id, v.id)),
                                    ),
                                    IconButton(key: ValueKey('graph-version-restore-${v.id}'), tooltip: tr('Bring this picture back'), icon: const Icon(Icons.restore), onPressed: () => _restore(v, g)),
                                    IconButton(key: ValueKey('graph-version-delete-${v.id}'), tooltip: tr('Delete'), icon: const Icon(Icons.delete_outline), onPressed: () => _deleteVersion(v)),
                                  ],
                                ),
                              ),
                            if (!_versions.any((v) => v.graphUid == g.uid))
                              Padding(
                                padding: const EdgeInsets.only(left: 72, right: 16, bottom: 12),
                                child: Align(alignment: Alignment.centerLeft, child: Text(tr('No earlier pictures: they are kept when the graph is made again.'), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12))),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }
}
