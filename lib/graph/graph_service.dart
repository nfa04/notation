import '../util/apart.dart';

import 'package:flutter/foundation.dart';

import '../ai/ai_prompt.dart';
import '../ai/ai_service.dart';
import '../ai/text_provider.dart';
import '../automations/note_sorter.dart';
import '../data/note_data.dart';
import '../data/knowledge_repository.dart' show SavedGraph;
import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../llm/embedding_service.dart';
import '../search/pdf_indexer.dart';
import 'contradictions.dart';
import 'fact_extractor.dart';
import 'graph_builder.dart';
import 'graph_layout.dart';
import 'graph_model.dart';

/// Makes the graphs (see docs/graph-architecture.md) and keeps them. Nothing here runs on its own: [generate] is called by the
/// person.
class GraphService extends ChangeNotifier {
  final NoteRepository _notes;
  final AiService? ai;

  /// Whether the AI is switched on (the switch of the settings); off, nothing here runs and nothing is offered.
  final bool Function() enabled;

  /// The sentence model, and whether it is there to read with; without it a lexical stand-in reads.
  final TextEmbedder? embedder;
  final bool Function() embedderReady;

  /// Whether notes that cite the same source are joined (when citations are on).
  final bool Function() joinByCitations;

  /// Whether a key is a source of the library (for the `@key` of a sentence).
  final bool Function(String key)? isSource;

  GraphService(this._notes, {this.ai, bool Function()? enabled, this.embedder, bool Function()? embedderReady, bool Function()? joinByCitations, this.isSource})
      : enabled = enabled ?? (() => true),
        embedderReady = embedderReady ?? (() => false),
        joinByCitations = joinByCitations ?? (() => false);

  /// Sources cited by more notes than this say little about any two of them (a textbook everybody cites), so they join nobody.
  static const commonSource = 12;

  /// The pairs of [notes] that cite a source in common, with how many.
  static List<(String, String, int)> sharedSources(Map<String, Set<String>> cited, Set<String> notes) {
    final citedBy = <String, List<String>>{};
    for (final e in cited.entries) {
      if (!notes.contains(e.key)) continue;
      for (final key in e.value) {
        (citedBy[key] ??= []).add(e.key);
      }
    }
    final pairs = <(String, String), int>{};
    for (final group in citedBy.values) {
      if (group.length < 2 || group.length > commonSource) continue;
      group.sort();
      for (var i = 0; i < group.length; i++) {
        for (var j = i + 1; j < group.length; j++) {
          pairs.update((group[i], group[j]), (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    return [for (final e in pairs.entries) (e.key.$1, e.key.$2, e.value)];
  }

  /// Whether the study tools (flashcards, quiz, questions) can be used: they need a model that is ready.
  bool get canStudy => enabled() && ai?.provider?.state == ProviderState.ready;

  /// What the model answers to a request of the study tools. Throws when there is no model.
  Future<String> studyComplete(AiPrompt prompt, {int maxTokens = 900, AiCancel? cancel}) {
    final provider = ai?.provider;
    if (!enabled() || provider == null || provider.state != ProviderState.ready) throw StateError(noFactWriterMessage);
    return provider.complete(prompt, maxTokens: maxTokens, cancel: cancel);
  }

  /// How strictly things are joined (set in the graph's settings); null keeps what suits the mode and the reader.
  /// The folder (with its subfolders) whose notes the graph is made of; null: all notes.
  String? folderId;

  Future<List<FolderEntry>> folders() => _notes.listFolders();

  /// The titles of the notes by id (for the filter by note).
  Future<Map<String, String>> noteTitles() async => {for (final n in await _notes.listNotes()) n.id: n.title.isEmpty ? tr('Untitled') : n.title};

  double? similarity;
  int neighbours = 4;
  int minTopicSize = 2;

  /// The least cosine used when [similarity] is not set.
  double defaultSimilarity(String mode) {
    final real = embedder != null && embedderReady();
    return real ? (mode == 'notes' ? 0.5 : 0.55) : (mode == 'notes' ? 0.3 : 0.35);
  }

  void resetTuning() {
    similarity = null;
    neighbours = 4;
    minTopicSize = 2;
    notifyListeners();
  }

  // The graphs that were kept (see [generate]); the view shows them as tabs.
  List<SavedGraph> _saved = const [];
  bool _listed = false;

  /// The kept graphs, oldest first (after [refresh]).
  List<SavedGraph> get graphs => _saved;

  /// The tab that was looked at last, so that it is the one shown when the view is opened again.
  int? selectedId;

  /// Reads the list of kept graphs (once; a graph made, renamed or removed here keeps it up to date).
  Future<void> refresh({bool force = false}) async {
    if (_listed && !force) return;
    _saved = await _notes.knowledge.listGraphs();
    _listed = true;
    if (selectedId != null && !_saved.any((g) => g.id == selectedId)) selectedId = null;
    selectedId ??= _saved.isEmpty ? null : _saved.last.id;
  }

  /// The picture of the kept graph [id] (null: there is none).

  Future<KnowledgeGraph?> load(int id) async {
    final payload = await _notes.knowledge.loadGraph(id);
    return payload == null ? null : KnowledgeGraph.decode(payload);
  }

  Future<void> rename(int id, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    await _notes.knowledge.renameGraph(id, clean);
    _saved = [
      for (final g in _saved)
        if (g.id == id) g.named(clean) else g,
    ];
    notifyListeners();
  }

  /// Forgets the kept graph [id]; the notes and their facts stay.
  Future<void> remove(int id) async {
    await _notes.knowledge.deleteGraph(id);
    _saved = [
      for (final g in _saved)
        if (g.id != id) g,
    ];
    if (selectedId == id) selectedId = _saved.isEmpty ? null : _saved.last.id;
    if (_lastMadeId == id) {
      _lastMadeId = null;
      _lastMade = null;
    }
    notifyListeners();
  }

  /// What a new graph is called: its kind and what it is made of, with a number when another has that name.
  Future<String> _nameFor(String mode, String? folder) async {
    final scope = folder == null
        ? tr('All notes')
        : (await folders())
                  .where((f) => f.id == folder)
                  .map((f) => f.name)
                  .firstOrNull ??
              tr('All notes');
    final base = '${mode == 'notes' ? tr('Notes') : tr('Facts')}: $scope';
    final taken = {for (final g in _saved) g.name};
    if (!taken.contains(base)) return base;
    for (var n = 2; ; n++) {
      if (!taken.contains('$base ($n)')) return '$base ($n)';
    }
  }

  // The run in progress lives here, not in the view, so that it goes on when the person looks at another tab.
  String? _runningMode;
  String _what = '';
  double? _done;
  String? _problem;
  AiCancel? _cancel;
  int _finished = 0; KnowledgeGraph? _lastMade;
  int? _lastMadeId;
  int? _replacing;

  /// The mode ('notes' or 'facts') being made, or null.
  String? get runningMode => _runningMode;
  String get what => _what;
  double? get done => _done;

  /// Why the last run made nothing, if it did not.
  String? get problem => _problem;

  /// Counts the runs that ended; a view that sees it change looks at [lastMade].
  int get finished => _finished;

  /// The graph the last run made and the id it was kept under (null: none this session).
 KnowledgeGraph? get lastMade => _lastMade;
  int? get lastMadeId => _lastMadeId;

  /// The kept graph the run in progress makes again (null: it makes a new one).
  int? get replacing => _replacing;

  void stop() => _cancel?.cancel();

  /// Starts [generate] in the background and reports through the listeners; one run at a time.
  Future<void> start(String mode, {bool noteHubs = false, int? replace}) async {
    if (_runningMode != null) return;
    if (!enabled()) {
      _problem = tr('The AI features are turned off.');
      notifyListeners();
      return;
    }
    final cancel = _cancel = AiCancel();
    _runningMode = mode;
    _replacing = replace;
    _problem = null;
    _notice = null;
    _unread = 0;
    _what = tr('Starting...');
    _done = null;
    notifyListeners();
    try {
      final graph = await generate(mode, noteHubs: noteHubs,
        replace: replace, cancel: cancel, progress: (what, done) {
        _what = what;
        _done = done;
        notifyListeners();
      });
      if (graph == null &&!cancel.cancelled) {
        _problem = mode == 'facts' && _unread > 0
            ? tr('The AI model did not write any facts that could be used. A bigger model, or another one, may do better.')
            : tr('There is nothing to make a graph of yet: the notes have no text.');
      }
      if (graph != null && _unread > 0) _notice = trCount(_unread, 'One part of the notes gave no usable facts.', '{n} parts of the notes gave no usable facts.');
    } catch (e) {
      _problem = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      _runningMode = null;
      _replacing = null;
      _finished++;
      notifyListeners();
    }
  }

  int _unread = 0;
  String? _notice;

  /// Something the last run wants to say although it made a graph (parts of the notes the model could not use).
  String? get notice => _notice;

  /// Whether the model that writes facts can be used now.
  bool get canWrite => enabled() && ai?.provider?.state == ProviderState.ready;

  /// Who writes the facts: the provider that is chosen (as everywhere else) and its model, for the screen.
  String get writerName {
    final provider = ai?.provider;
    if (provider == null) return tr('No AI provider');
    var name = tr(provider.label);
    if (provider is SelectableModels) {
      final models = provider as SelectableModels;
      final chosen = models.modelOptions.where((o) => o.id == models.selectedModelId).firstOrNull;
      if (chosen != null) name = '$name - ${tr(chosen.label)}';
    }
    return name;
  }

  Future<bool> _allFactsUpToDate(List<NoteSummary> notes, FactExtractor extractor) async {
    // (a note whose facts are kept needs no model: it is only the first time, or after a change, that one is asked for)
    for (final n in notes) {
      final state = await _notes.knowledge.factState(n.id);
      if (state == null || state.extractor != FactExtractor.version) return false;
    }
    return true;
  }

  /// Makes the graph of [mode] ('notes' or 'facts') now and keeps it as a new one, or in the place of the kept graph [replace]
  /// (which keeps its name). The facts are written by the chosen AI provider (and
  /// there are none without one: [StateError]). [progress] is told what is going on and how far (0..1, null when not known). Cancelling
  /// [cancel] stops at the next step and keeps the old graph.
  Future<KnowledgeGraph?> generate(
    String mode, {
    bool noteHubs = false,
    int? replace,
    void Function(String what, double? done)? progress,
    AiCancel? cancel,
  }) async {
    if (!enabled()) throw StateError(tr('The AI features are turned off.'));
    final real = embedder != null && embedderReady();
    final TextEmbedder emb = real ? embedder! : const LexicalEmbedder();
    final settings = GraphSettings(minSimilarity: similarity ?? defaultSimilarity(mode), neighbours: neighbours, minTopicSize: minTopicSize, noteHubs: noteHubs && mode == 'facts', topicHubs: mode == 'facts');
    Set<String>? inFolder;
    if (folderId != null) {
      final folders = await _notes.listFolders();
      inFolder = {folderId!};
      for (var grew = true; grew;) {
        grew = false;
        for (final f in folders) {
          if (f.parentId != null && inFolder.contains(f.parentId) && inFolder.add(f.id)) grew = true;
        }
      }
    }
    final notes = [for (final n in await _notes.listNotes()) if (!n.locked && (inFolder == null || (n.folderId != null && inFolder.contains(n.folderId)))) n];
    if (notes.isEmpty) return null;
    final titles = {for (final n in notes) n.id: n.title.isEmpty ? tr('Untitled') : n.title};

    progress?.call(tr('Reading the PDFs...'), null);
    await PdfIndexer(_notes).run(stop: () => cancel?.cancelled ?? false); // so that the text of PDFs counts too
    final inputs = <GraphInput>[];
    final inFacts = <StoredFact>[];
    if (mode == 'notes') {
      final sorter = NoteSorter(_notes, emb, ready: () => true);
      for (var i = 0; i < notes.length; i++) {
        if (cancel?.cancelled ?? false) return null;
        progress?.call(tr('Reading the notes...'), i / notes.length);
        final n = notes[i];
        final text = await _notes.text.noteText(n.id, limit: 1500);
        inputs.add(GraphInput(
          id: n.id,
          kind: GraphNodeKind.note,
          label: titles[n.id]!,
          detail: text.length > 220 ? '${text.substring(0, 220)}…' : text,
          noteId: n.id,
          vector: await sorter.vectorOf(n.id),
          keywords: telltaleWords(text).take(40).toList(),
        ));
      }
    } else {
      final extractor = FactExtractor(_notes, emb, ai: ai);
      if (!extractor.canWrite && !await _allFactsUpToDate(notes, extractor)) throw StateError(noFactWriterMessage);
      for (var i = 0; i < notes.length; i++) {
        if (cancel?.cancelled ?? false) return null;
        progress?.call(tr('Taking the facts out of "{title}" ({model})...', {'title': titles[notes[i].id], 'model': writerName}), i / notes.length);
        await extractor.extract(notes[i].id, cancel: cancel);
      }
      _unread = extractor.unreadWindows;
      progress?.call(tr('Joining the facts...'), null);
      final wanted = {for (final n in notes) n.id};
      for (final f in await _notes.knowledge.allFacts()) {
        if (!wanted.contains(f.noteId)) continue;
        inFacts.add(f);
        inputs.add(GraphInput(
          id: 'f${f.id}',
          kind: GraphNodeKind.fact,
          label: f.title,
          detail: f.sentence,
          noteId: f.noteId,
          page: f.page,
          tag: f.tag,
          vector: f.vector,
          keywords: f.keywords,
        ));
      }
    }
    if (inputs.isEmpty) return null;
    if (cancel?.cancelled ?? false) return null;

    progress?.call(tr('Placing everything...'), null);
    final links = mode == 'notes' ? await _notes.knowledge.noteLinks() : const <(String, String)>[];
    // (two facts of different notes that give different numbers for the same thing)
    final clashes = mode == 'facts'
        ? [
            for (final c in findContradictions([for (final f in inFacts) f])) ('f${c.a.id}', 'f${c.b.id}'),
          ]
        : const <(String, String)>[];
    final shared = mode == 'notes' && joinByCitations() ? sharedSources(await _notes.knowledge.noteCitations(isSource: isSource), {for (final n in notes) n.id}) : const <(String, String, int)>[];
    // (only plain data may go into the closure: the embedder holds a model and cannot be sent to the isolate)
    final modelId = emb.modelId;
    final encoded = await runApart(() {
      final g = buildGraph(mode, inputs, links: links, shared: shared, clashes: clashes, settings: settings, embedder: modelId);
      layoutGraph(g, iterations: inputs.length > 2500 ? 70 : 150);
      return g.encode();
    });
    final graph = KnowledgeGraph.decode(encoded)!;
    // a note hub carries the title of its note
    final named = KnowledgeGraph(
      mode: graph.mode,
      builtAt: graph.builtAt,
      embedder: graph.embedder,
      clusters: graph.clusters,
      edges: graph.edges,
      nodes: [
        for (final n in graph.nodes)
          n.kind == GraphNodeKind.note && n.label.isEmpty
              ? (GraphNode(id: n.id, kind: n.kind, label: titles[n.noteId] ?? '', noteId: n.noteId, cluster: n.cluster, x: n.x, y: n.y, size: n.size))
              : n,
      ],
    );
    await refresh();
    final id = await _notes.knowledge.saveGraph(
      name: replace != null && _saved.any((g) => g.id == replace)
          ? ''
          : await _nameFor(mode, folderId),
      mode: mode,
      folderId: folderId,
      payload: named.encode(),
      replace: replace,);
    await refresh(force: true);
    _lastMade = named;
    _lastMadeId = selectedId = id;
    return named;
  }
}
