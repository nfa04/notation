import 'package:material_symbols_icons/symbols.dart';
import 'dart:async';

import '../widgets/paper.dart';
import 'package:flutter/material.dart' hide Text;

import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../data/tag_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../search/pdf_indexer.dart';
import '../search/search_filter.dart';
import '../search/search_memory.dart';
import '../ai/citations.dart' show quoteQuery;
import '../ai/note_knowledge.dart';
import '../search/search_query.dart';
import '../style/platform_dialog.dart';

/// Search across all notes: plain words or a regular expression, in titles, written documents, text boxes and the text of PDFs.
/// Tapping a result opens the note at that place with the search still on in it.
class SearchView extends StatefulWidget {
  final NoteRepository repository;

  /// Opens a note at [page] (0-based, -1 for no page in particular) with [query] marked in it.
  final void Function(String noteId, SearchQuery query, int page) onOpen;

  /// The search as it was left, and told whenever it changes.
  final SearchQuery? initial;
  final ValueChanged<SearchQuery>? onChanged;

  /// Where to look, as it was left, and told whenever it changes.
  final SearchFilter? initialFilter;
  final ValueChanged<SearchFilter>? onFilterChanged;

  /// The tags of notes, to filter by; null: no tags.
  final TagRepository? tags;

  /// Finds notes by what they say (not by their words); null: that way of searching is not offered.
  final NoteKnowledge? knowledge;

  const SearchView({super.key, required this.repository, required this.onOpen, this.initial, this.onChanged, this.initialFilter, this.onFilterChanged, this.tags, this.knowledge});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  late final _text = TextEditingController(text: widget.initial?.text ?? '');
  late bool _regex = widget.initial?.regex ?? false;
  late bool _case = widget.initial?.caseSensitive ?? false;
  late bool _word = widget.initial?.wholeWord ?? false;
  late SearchFilter _filter = widget.initialFilter ?? SearchFilter();
  late bool _showFilters = !_filter.isDefault;
  SearchOrder _order = SearchOrder.relevance;
  late final SearchMemory _memory = SearchMemory(widget.repository.settings);
  List<SavedSearch> _recent = const [];
  Map<String, Set<String>> _tagsOfNotes = {};
  Map<String, int> _tagCounts = {};

  Timer? _debounce;
  RunningSearch? _running;
  SearchResults? _results;

  /// Nothing was found as typed, so these are the matches of similar words (typos allowed).
  bool get _similar => _results?.similar ?? false;

  /// Search by meaning: what the notes say about the words, not the words themselves.
  bool _meaning = false;
  Retrieval? _found;
  int _asked = 0;
  String? _failure;
  bool _busy = false;

  Map<String, NoteSummary> _notes = {};
  Map<String, FolderEntry> _folders = {};
  late final PdfIndexer _indexer = PdfIndexer(widget.repository);
  String? _reading;
  bool _gone = false;

  /// All the text there is to search, kept while this screen is open: it is read from the database once, not at every letter typed.
  /// It is read again when a note changed or text was read from a PDF or handwriting since.
  List<SearchSource>? _sources;
  int _sourcesVersion = -1;
  bool _sourcesStale = true;
  final List<StreamSubscription<String>> _changeSubs = [];

  Future<List<SearchSource>> _allSources() async {
    final text = widget.repository.text;
    if (_sources == null || _sourcesStale || _sourcesVersion != text.indexVersion) {
      _sourcesStale = false;
      _sourcesVersion = text.indexVersion;
      _sources = await text.searchSources();
    }
    return _sources!;
  }

  SearchQuery get _query => SearchQuery(_text.text, regex: _regex, caseSensitive: _case, wholeWord: _word);

  @override
  void initState() {
    super.initState();
    for (final stream in [widget.repository.changes, widget.repository.saved]) {
      _changeSubs.add(stream.listen((_) => _sourcesStale = true));
    }
    _load();
  }

  Future<void> _load() async {
    final notes = await widget.repository.listNotes();
    final folders = await widget.repository.listFolders();
    final tagsOfNotes = await widget.tags?.all() ?? <String, Set<String>>{};
    final tagCounts = await widget.tags?.counts() ?? <String, int>{};
    final recent = await _memory.recent();
    if (_gone) return;
    setState(() {
      _notes = {for (final n in notes) n.id: n};
      _folders = {for (final f in folders) f.id: f};
      _tagsOfNotes = tagsOfNotes;
      _tagCounts = tagCounts;
      _recent = recent;
    });
    if (!_query.isEmpty) _search();
    unawaited(_readPdfs());
  }

  Future<void> _readPdfs() async {
    await _indexer.run(
      stop: () => _gone,
      progress: (done, all) {
        if (_gone) return;
        setState(() => _reading = all == 0 || done == all ? null : tr('Reading PDFs: {done} of {all}', {'done': done, 'all': all}));
      },
    );
    if (!_gone && !_query.isEmpty) _search();
  }

  void _changed() {
    widget.onChanged?.call(_query);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
    setState(() {});
  }

  /// The notes and passages that fit what was typed, by meaning.
  Future<void> _searchMeaning() async {
    final knowledge = widget.knowledge;
    final text = _text.text.trim();
    _running?.cancel();
    final turn = ++_asked;
    if (knowledge == null || text.isEmpty) {
      setState(() {
        _found = null;
        _failure = null;
        _busy = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final allowed = {for (final s in _filter.apply(await _allSources(), _notes, _folders, tagsOfNotes: _tagsOfNotes)) s.noteId};
      final r = await knowledge.retrieve(text, notes: 12, passages: 36);
      if (_gone || turn != _asked) return;
      // (it always names the closest notes, however far off: only those about as close as the best are shown)
      final best = r.notes.where((n) => allowed.contains(n.id)).toList();
      final top = best.isEmpty ? 0.0 : best.map((n) => n.score).reduce((a, b) => a > b ? a : b);
      final shown = [for (final n in best) if (n.score >= 0.2 && n.score >= top * 0.5) n];
      final ids = {for (final n in shown) n.id};
      setState(() {
        _found = Retrieval(shown, [for (final p in r.passages) if (ids.contains(p.noteId) && p.score >= 0.15) p]);
        _busy = false;
      });
    } catch (e) {
      if (_gone || turn != _asked) return;
      setState(() {
        _found = null;
        _busy = false;
        _failure = tr('The search failed.');
      });
    }
  }

  Future<void> _search() async {
    if (_meaning) return _searchMeaning();
    final query = _query;
    _running?.cancel();
    if (query.isEmpty || query.problem != null) {
      setState(() {
        _results = null;
        _failure = null;
        _busy = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    final all = await _allSources();
    if (_gone) return;
    final sources = _filter.apply(all, _notes, _folders, tagsOfNotes: _tagsOfNotes);
    final run = RunningSearch.start(query, sources);
    _running = run;
    try {
      final r = await run.results;
      if (_gone || _running != run) return;
      setState(() {
        _results = r;
        _busy = false;
      });
    } catch (e) {
      if (_gone || searchWasCancelled(e) || _running != run) return;
      setState(() {
        _results = null;
        _busy = false;
        _failure = e is SearchTooSlow ? tr('That pattern takes too long to try.') : tr('The search failed.');
      });
    }
  }

  @override
  void dispose() {
    _gone = true;
    for (final sub in _changeSubs) {
      sub.cancel();
    }
    _debounce?.cancel();
    _running?.cancel();
    _text.dispose();
    super.dispose();
  }

  String _where(NoteSummary? n) {
    final names = <String>[];
    var id = n?.folderId;
    while (id != null && names.length < 6) {
      final f = _folders[id];
      if (f == null) break;
      names.insert(0, f.name);
      id = f.parentId;
    }
    return names.join(' / ');
  }

  String _placeLabel(SearchHit h) => switch (h.place) {
        SearchPlace.title => tr('Title'),
        SearchPlace.pdfName => tr('PDF name'),
        SearchPlace.document => tr('Document'),
        SearchPlace.textBox => tr('Text box, page {n}', {'n': h.page + 1}),
        SearchPlace.pdfText => tr('PDF, page {n}', {'n': h.page + 1}),
        SearchPlace.handwriting => tr('Handwriting, page {n}', {'n': h.page + 1}),
      };

  Future<void> _remember() async {
    await _memory.remember(_query, _filter);
    final recent = await _memory.recent();
    if (!_gone) setState(() => _recent = recent);
  }

  /// Puts [s] in the page, as if it had been typed and set there, and runs it.
  void _apply(SavedSearch s) {
    _text.text = s.query.text;
    setState(() {
      _regex = s.query.regex;
      _case = s.query.caseSensitive;
      _word = s.query.wholeWord;
      _filter = s.filter;
      _showFilters = !s.filter.isDefault;
    });
    widget.onFilterChanged?.call(s.filter);
    widget.onChanged?.call(_query);
    _search();
  }

  Future<void> _saveCurrent() async {
    final query = _query;
    if (query.isEmpty || query.problem != null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: query.text),
    );
    if (name == null || name.trim().isEmpty) return;
    await _memory.save(SavedSearch(name.trim(), query, _filter));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(tr('Saved as "{name}"', {'name': name.trim()}))));
  }

  Future<void> _showSaved() async {
    final picked = await showDialog<SavedSearch>(
      context: context,
      builder: (_) => _SavedSearchesDialog(memory: _memory),
    );
    if (picked != null) _apply(picked);
  }

  Future<void> _pickTags() async {
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _TagPickDialog(counts: _tagCounts, chosen: _filter.tags),
    );
    if (picked != null) _setFilter(_filter.copyWith(tags: picked));
  }

  String _orderLabel(SearchOrder o) => switch (o) {
        SearchOrder.relevance => tr('Best match'),
        SearchOrder.changed => tr('Recently changed'),
        SearchOrder.mostMatches => tr('Most matches'),
        SearchOrder.title => tr('Title'),
      };

  void _setFilter(SearchFilter f) {
    setState(() => _filter = f);
    widget.onFilterChanged?.call(f);
    if (!_query.isEmpty) _search();
  }

  String _placeGroupLabel(SearchPlace first) => switch (first) {
        SearchPlace.title || SearchPlace.pdfName => tr('Titles'),
        SearchPlace.document => tr('Documents'),
        SearchPlace.textBox => tr('Text boxes'),
        SearchPlace.pdfText => tr('PDF text'),
        SearchPlace.handwriting => tr('Handwriting'),
      };

  String _ageLabel(SearchAge a) => switch (a) {
        SearchAge.any => tr('Any time'),
        SearchAge.day => tr('Past day'),
        SearchAge.week => tr('Past week'),
        SearchAge.month => tr('Past month'),
        SearchAge.year => tr('Past year'),
      };

  /// The folders as a list in tree order, each with how deep it lies.
  List<(FolderEntry, int)> _folderTree() {
    final children = <String?, List<FolderEntry>>{};
    for (final f in _folders.values) {
      children.putIfAbsent(_folders.containsKey(f.parentId) ? f.parentId : null, () => []).add(f);
    }
    for (final l in children.values) {
      l.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    final out = <(FolderEntry, int)>[];
    void walk(String? parent, int depth) {
      for (final f in children[parent] ?? const <FolderEntry>[]) {
        out.add((f, depth));
        if (depth < 12) walk(f.id, depth + 1);
      }
    }

    walk(null, 0);
    return out;
  }

  Widget _filterRow(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: 84, child: Text.verbatim(label, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ]),
      );

  Widget _filterPanel() {
    final f = _filter;
    final tree = _folderTree();
    return Padding(
      key: const ValueKey('search-filters'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _filterRow(
          tr('Look in'),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final group in searchPlaceGroups)
              FilterChip(
                key: ValueKey('search-place-${group.first.name}'),
                label: Text.verbatim(_placeGroupLabel(group.first)),
                selected: group.every(f.places.contains),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (on) {
                  final next = {...f.places};
                  on ? next.addAll(group) : next.removeAll(group);
                  if (next.isEmpty) return; // looking nowhere finds nothing
                  _setFilter(f.copyWith(places: next));
                },
              ),
          ]),
        ),
        _filterRow(
          tr('Type'),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final (k, label) in [(SearchKind.any, 'All'), (SearchKind.notes, 'Notes'), (SearchKind.pdfs, 'PDFs')])
              ChoiceChip(
                key: ValueKey('search-kind-${k.name}'),
                label: Text.verbatim(tr(label)),
                selected: f.kind == k,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => _setFilter(f.copyWith(kind: k)),
              ),
          ]),
        ),
        _filterRow(
          tr('Changed'),
          DropdownButton<SearchAge>(
            key: const ValueKey('search-age'),
            value: f.age,
            isDense: true,
            items: [for (final a in SearchAge.values) DropdownMenuItem(value: a, child: Text.verbatim(_ageLabel(a)))],
            onChanged: (a) => a == null ? null : _setFilter(f.copyWith(age: a)),
          ),
        ),
        if (tree.isNotEmpty)
          _filterRow(
            tr('Folder'),
            DropdownButton<String?>(
              key: const ValueKey('search-folder'),
              value: tree.any((e) => e.$1.id == f.folderId) ? f.folderId : null,
              isDense: true,
              items: [
                DropdownMenuItem<String?>(value: null, child: Text.verbatim(tr('All folders'))),
                for (final (folder, depth) in tree)
                  DropdownMenuItem<String?>(value: folder.id, child: Text.verbatim('${'    ' * depth}${folder.name}')),
              ],
              onChanged: (id) => _setFilter(id == null ? f.copyWith(clearFolder: true) : f.copyWith(folderId: id)),
            ),
          ),
        if (widget.tags != null && (_tagCounts.isNotEmpty || f.tags.isNotEmpty))
          _filterRow(
            tr('Tags'),
            Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final t in (f.tags.toList()..sort()))
                InputChip(
                  key: ValueKey('search-tag-$t'),
                  label: Text.verbatim('#$t'),
                  visualDensity: VisualDensity.compact,
                  onDeleted: () => _setFilter(f.copyWith(tags: {...f.tags}..remove(t))),
                ),
              ActionChip(
                key: const ValueKey('search-tags-add'),
                avatar: const Icon(Symbols.add, size: 16),
                label: Text.verbatim(tr(f.tags.isEmpty ? 'Choose tags' : 'More')),
                visualDensity: VisualDensity.compact,
                onPressed: _pickTags,
              ),
            ]),
          ),
        _filterRow(
          tr('Only'),
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilterChip(
              key: const ValueKey('search-favorites'),
              avatar: const Icon(Symbols.star_outline, size: 16),
              label: Text.verbatim(tr('Favourites')),
              selected: f.favoritesOnly,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (v) => _setFilter(f.copyWith(favoritesOnly: v)),
            ),
            if (!f.isDefault)
              TextButton(
                key: const ValueKey('search-filters-reset'),
                onPressed: () => _setFilter(SearchFilter()),
                child: Text.verbatim(tr('Reset filters')),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _toggle(String key, String label, String tip, bool on, ValueChanged<bool> set) => Tooltip(
        message: tr(tip),
        child: FilterChip(
          key: ValueKey(key),
          label: Text.verbatim(label),
          selected: on,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          onSelected: (v) {
            set(v);
            _changed();
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final problem = _query.problem;
    final r = _results;
    final byNote = <String, List<SearchHit>>{};
    for (final h in r?.hits ?? const <SearchHit>[]) {
      byNote.putIfAbsent(h.noteId, () => []).add(h);
    }
    final order = [
      for (final n in _notes.values)
        if (byNote.containsKey(n.id)) n.id,
      for (final id in byNote.keys)
        if (!_notes.containsKey(id)) id,
    ];
    switch (_order) {
      case SearchOrder.relevance:
        // (the notes come most recently changed first, and a note that is as good as another stays after it)
        final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
        final score = {for (final id in order) id: relevanceOf(byNote[id]!, r!.countByNote[id] ?? 0)};
        order.sort((a, b) {
          final c = score[b]!.compareTo(score[a]!);
          return c != 0 ? c : rank[a]!.compareTo(rank[b]!);
        });
      case SearchOrder.changed:
        break; // (the notes come most recently changed first)
      case SearchOrder.mostMatches:
        order.sort((a, b) => (r!.countByNote[b] ?? 0).compareTo(r.countByNote[a] ?? 0));
      case SearchOrder.title:
        order.sort((a, b) => (_notes[a]?.title ?? '').toLowerCase().compareTo((_notes[b]?.title ?? '').toLowerCase()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        actions: [
          if (!_query.isEmpty && problem == null)
            IconButton(key: const ValueKey('search-save'), icon: const Icon(Symbols.bookmark_add), tooltip: tr('Save this search'), onPressed: _saveCurrent),
          IconButton(key: const ValueKey('search-saved'), icon: const Icon(Symbols.bookmarks), tooltip: tr('Saved searches'), onPressed: _showSaved),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            key: const ValueKey('search-field'),
            controller: _text,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: tr(_regex ? 'A regular expression' : 'Search all notes'),
              prefixIcon: const Icon(Symbols.search),
              errorText: problem == null ? null : tr('Not a valid expression: {why}', {'why': problem}),
              suffixIcon: _text.text.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('search-clear'),
                      icon: const Icon(Symbols.clear),
                      tooltip: tr('Clear'),
                      onPressed: () {
                        _text.clear();
                        _changed();
                      },
                    ),
            ),
            onChanged: (_) => _changed(),
            onSubmitted: (_) {
              _search();
              _remember();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SizedBox(width: double.infinity, child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (!_meaning) ...[
              _toggle('search-case', 'Aa', 'Match the case', _case, (v) => _case = v),
              _toggle('search-word', 'ab', 'Whole words only', _word, (v) => _word = v),
              _toggle('search-regex', '.*', 'Regular expression', _regex, (v) => _regex = v),
            ],
            if (widget.knowledge != null)
              FilterChip(
                key: const ValueKey('search-meaning'),
                avatar: const Icon(Symbols.auto_awesome, size: 16),
                label: Text.verbatim(tr('By meaning')),
                tooltip: tr('Find notes by what they say about it, not by the words you typed'),
                selected: _meaning,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (v) {
                  setState(() {
                    _meaning = v;
                    _results = null;
                    _found = null;
                  });
                  _search();
                },
              ),
            FilterChip(
              key: const ValueKey('search-filters-toggle'),
              avatar: const Icon(Symbols.tune, size: 16),
              label: Text.verbatim(_filter.activeCount == 0 ? tr('Filters') : tr('Filters ({n})', {'n': _filter.activeCount})),
              selected: _showFilters,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (v) => setState(() => _showFilters = v),
            ),
            if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2)),
            if (_reading != null) Text.verbatim(_reading!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ])),
        ),
        if (_showFilters) _filterPanel(),
        if (r != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              Expanded(
                child: Text.verbatim(
                  r.total == 0
                      ? tr('No matches.')
                      : (_similar ? tr('Nothing as typed. Similar words: ') : '') +
                          tr('{n} matches in {notes} notes', {'n': r.total, 'notes': r.countByNote.length}) +
                          (r.cutOff ? tr(' (the first ones are shown)') : ''),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              if (order.length > 1)
                PopupMenuButton<SearchOrder>(
                  key: const ValueKey('search-order'),
                  tooltip: tr('Order'),
                  initialValue: _order,
                  onSelected: (o) => setState(() => _order = o),
                  itemBuilder: (_) => [for (final o in SearchOrder.values) PopupMenuItem(value: o, child: Text.verbatim(_orderLabel(o)))],
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Symbols.sort, size: 16, color: Theme.of(context,).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text.verbatim(_orderLabel(_order), style: TextStyle(fontSize: 12, color: Theme.of(context,).colorScheme.onSurfaceVariant)),
                  ]),
                ),
            ]),
          ),
        if (_failure != null) Padding(padding: const EdgeInsets.all(16), child: Text.verbatim(_failure!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            if (_query.isEmpty && _recent.isNotEmpty) _recentList(),
            if (_meaning) ..._meaningCards() else for (final id in order) _noteCard(id, byNote[id]!, r!.countByNote[id] ?? 0),
          ]),
        ),
      ]),
    );
  }

  /// The first words of a passage: enough to find it again in its note.
  static String _lead(String text) => text.trim().split(RegExp(r'\s+')).take(6).join(' ');

  /// The notes found by meaning, each with the passages that fit best.
  List<Widget> _meaningCards() {
    final found = _found;
    final scheme = Theme.of(context).colorScheme;
    final knowledge = widget.knowledge!;
    if (found == null) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text.verbatim(
          found.notes.isEmpty
              ? tr('Nothing about that.')
              : (knowledge.ready() ? '' : tr('Only the words count: download the sentence model in the settings to find notes by what they mean. ')) +
                  tr('{n} notes', {'n': found.notes.length}),
          key: const ValueKey('search-meaning-count'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ),
      for (final n in found.notes)
        () {
          final note = _notes[n.id];
          final passages = ([for (final p in found.passages) if (p.noteId == n.id) p]..sort((a, b) => b.score.compareTo(a.score))).take(2).toList();
          return Card(
            key: ValueKey('search-meaning-${n.id}'),
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                leading: Icon(note?.isPdf ?? false ? Symbols.picture_as_pdf : Symbols.note_alt),
                title: Text.verbatim(n.title.isEmpty ? tr('Untitled') : n.title),
                subtitle: _where(note).isEmpty ? null : Text.verbatim(_where(note)),
                onTap: () {
                  _remember();
                  widget.onOpen(n.id, const SearchQuery(''), passages.isEmpty ? -1 : (passages.first.page ?? -1));
                },
              ),
              for (final p in passages)
                InkWell(
                  onTap: () {
                    _remember();
                    widget.onOpen(n.id, quoteQuery(_lead(p.text)), p.page ?? -1);
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text.verbatim(p.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
                      Text.verbatim(p.text.replaceAll(RegExp(r'\s+'), ' ').trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
                ),
              const SizedBox(height: 4),
            ]),
          );
        }(),
    ];
  }

  Widget _recentList() => Padding(
        key: const ValueKey('search-recent'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text.verbatim(tr('Recent searches'), style: PaperSection.style(context))),
            TextButton(
              key: const ValueKey('search-recent-clear'),
              onPressed: () async {
                await _memory.clearRecent();
                if (!_gone) setState(() => _recent = const []);
              },
              child: Text.verbatim(tr('Clear')),
            ),
          ]),
          for (var i = 0; i < _recent.length; i++)
            ListTile(
              key: ValueKey('search-recent-$i'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Symbols.history, size: 20),
              title: Text.verbatim(_recent[i].query.text, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: _recent[i].filter.isDefault ? null : Text.verbatim(tr('With {n} filters', {'n': _recent[i].filter.activeCount})),
              onTap: () => _apply(_recent[i]),
            ),
        ]),
      );

  Widget _noteCard(String id, List<SearchHit> hits, int count) {
    final note = _notes[id];
    final where = _where(note);
    final scheme = Theme.of(context).colorScheme;
    final query = _similar ? _query.withTypos : _query; // (a note opened from similar words finds them there too)
    return Card(
      key: ValueKey('search-note-$id'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ListTile(
          leading: Icon(note?.isPdf ?? false ? Symbols.picture_as_pdf : Symbols.note_alt),
          title: Text.verbatim(note?.title.isEmpty ?? true ? tr('Untitled Note') : note!.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: where.isEmpty ? null : Text.verbatim(where, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text.verbatim('$count'),
          onTap: () {
            _remember();
            widget.onOpen(id, query, hits.first.page);
          },
        ),
        for (final h in hits.take(5))
          InkWell(
            key: ValueKey('search-hit-$id-${hits.indexOf(h)}'),
            onTap: () {
              _remember();
              widget.onOpen(id, query, h.page);
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.verbatim(_placeLabel(h), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
                RichText(
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(style: DefaultTextStyle.of(context,).style.copyWith(fontSize: 13), children: [
                    TextSpan(text: h.before),
                    TextSpan(text: h.match, style: TextStyle(fontWeight: FontWeight.w500, backgroundColor: scheme.primaryContainer, color: scheme.onPrimaryContainer)),
                    TextSpan(text: h.after),
                  ]),
                ),
              ]),
            ),
          ),
        if (count > 5)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text.verbatim(tr('{n} more in this note', {'n': count - 5}), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
      ]),
    );
  }
}

/// Asks what to call a search.
class _NameDialog extends StatefulWidget {
  final String initial;
  const _NameDialog({required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformAlertDialog(
        title: Text.verbatim(tr('Save this search')),
        content: TextField(
          key: const ValueKey('search-save-name'),
          controller: _name,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Name')),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text.verbatim(tr('Cancel'))),
          FilledButton(key: const ValueKey('search-save-ok'), onPressed: () => Navigator.pop(context, _name.text), child: Text.verbatim(tr('Save'))),
        ],
      );
}

/// The searches that were saved: tap one to use it, or take it away.
class _SavedSearchesDialog extends StatefulWidget {
  final SearchMemory memory;
  const _SavedSearchesDialog({required this.memory});

  @override
  State<_SavedSearchesDialog> createState() => _SavedSearchesDialogState();
}

class _SavedSearchesDialogState extends State<_SavedSearchesDialog> {
  List<SavedSearch>? _saved;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final saved = await widget.memory.saved();
    if (mounted) setState(() => _saved = saved);
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    return PlatformAlertDialog(
      title: Text.verbatim(tr('Saved searches')),
      content: SizedBox(
        width: 360,
        child: saved == null
            ? const SizedBox(height: 48, child: Center(child: CircularProgressIndicator.adaptive()))
            : saved.isEmpty
                ? Text.verbatim(tr('Nothing saved yet. Search for something and tap the bookmark to keep it.'))
                : ListView(shrinkWrap: true, children: [
                    for (final s in saved)
                      ListTile(
                        key: ValueKey('search-saved-${s.name}'),
                        title: Text.verbatim(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text.verbatim(s.query.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, s),
                        trailing: IconButton(
                          key: ValueKey('search-forget-${s.name}'),
                          icon: const Icon(Symbols.delete_outline),
                          tooltip: tr('Delete'),
                          onPressed: () async {
                            await widget.memory.forget(s.name);
                            await _reload();
                          },
                        ),
                      ),
                  ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text.verbatim(tr('Close')))],
    );
  }
}

/// Picks the tags to look under.
class _TagPickDialog extends StatefulWidget {
  final Map<String, int> counts;
  final Set<String> chosen;
  const _TagPickDialog({required this.counts, required this.chosen});

  @override
  State<_TagPickDialog> createState() => _TagPickDialogState();
}

class _TagPickDialogState extends State<_TagPickDialog> {
  late final Set<String> _chosen = {...widget.chosen};

  @override
  Widget build(BuildContext context) {
    final tags = {...widget.counts.keys, ..._chosen}.toList()..sort();
    return PlatformAlertDialog(
      title: Text.verbatim(tr('Tags')),
      content: SizedBox(
        width: 360,
        child: ListView(shrinkWrap: true, children: [
          for (final t in tags)
            CheckboxListTile.adaptive(
              key: ValueKey('search-tag-pick-$t'),
              dense: true,
              value: _chosen.contains(t),
              title: Text.verbatim('#$t'),
              secondary: Text.verbatim('${widget.counts[t] ?? 0}'),
              onChanged: (v) => setState(() => v == true ? _chosen.add(t) : _chosen.remove(t)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text.verbatim(tr('Cancel'))),
        FilledButton(key: const ValueKey('search-tags-ok'), onPressed: () => Navigator.pop(context, _chosen), child: Text.verbatim(tr('Done'))),
      ],
    );
  }
}
