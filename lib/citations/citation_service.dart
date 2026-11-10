import 'package:flutter/widgets.dart';

import 'citation_document.dart';
import 'citation_repository.dart';
import 'citation_style.dart';
import 'source.dart';

/// The library of sources and the style notes cite in. The text of a note names a source by its key, `[@smith2020]`; what that
/// reads as, and the list of sources under the text, come from here.
///
/// The style is chosen for every note, and may be chosen again for a folder (and the folders in it) and for a single note; the
/// nearest choice wins.
class CitationService extends ChangeNotifier {
  final CitationRepository _repository;

  /// The notes that cite each key, by key (those of the notes that are not locked or deleted); asked with what tells a key of the
  /// library from a name in a sentence. Null: not known here, and the library does not say where a source is cited.
  final Future<Map<String, List<NoteRef>>> Function(bool Function(String key) isSource)? _citedIn;

  /// Whether citations are shown formatted; off, `[@key]` stays as it was written.
  final bool Function() enabled;

  /// The folders a note is in, the nearest first (empty: in none); to find the style of the folder it is in.
  final Future<List<String>> Function(String noteId)? _folderChain;

  CitationService(
    this._repository, {
    this.enabled = _always,
    Future<List<String>> Function(String noteId)? folderChain,
    Future<Map<String, List<NoteRef>>> Function(bool Function(String key) isSource)? citedIn,
  })  : _folderChain = folderChain,
        _citedIn = citedIn;

  static bool _always() => true;

  List<CitationSource> _sources = [];
  Map<String, CitationSource> _byId = {};
  CitationStyle _style = citationStyles.first;
  Map<String, String> _noteStyles = {};
  Map<String, String> _folderStyles = {};
  int _version = 0;

  /// The sources, in the order they were added.
  List<CitationSource> get sources => List.unmodifiable(_sources);
  Map<String, CitationSource> get byId => Map.unmodifiable(_byId);

  /// Whether the library has a source with this key.
  bool has(String key) => _byId.containsKey(key);

  /// The style for every note.
  CitationStyle get style => _style;

  /// Reads everything again (at the start, and after a sync brought changes from another device).
  Future<void> load() async {
    await _repository.adoptLegacy();
    _style = citationStyleById(await _repository.style());
    _noteStyles = await _repository.stylesOf(CitationRepository.noteStylePrefix);
    _folderStyles = await _repository.stylesOf(CitationRepository.folderStylePrefix);
    _set(await _repository.all());
  }

  void _set(List<CitationSource> sources) {
    _sources = sources;
    _byId = {for (final s in sources) s.id: s};
    _version++;
    notifyListeners();
  }

  /// The style [noteId] has chosen for itself, null if it has none.
  CitationStyle? ownStyleOfNote(String noteId) => _own(_noteStyles[noteId]);

  /// The style [folderId] has chosen for itself, null if it has none.
  CitationStyle? ownStyleOfFolder(String folderId) => _own(_folderStyles[folderId]);

  static CitationStyle? _own(String? id) => id == null || id.isEmpty ? null : citationStyleById(id);

  /// The style a note is cited in when it has none of its own: the nearest folder that has one, else null (the style for every note).
  Future<CitationStyle?> inheritedStyleOfNote(String noteId) async {
    for (final folder in await (_folderChain?.call(noteId) ?? Future.value(const <String>[]))) {
      final s = ownStyleOfFolder(folder);
      if (s != null) return s;
    }
    return null;
  }

  /// The style [noteId] is cited in, or null for the style for every note.
  Future<CitationStyle?> styleOfNote(String noteId) async => ownStyleOfNote(noteId) ?? await inheritedStyleOfNote(noteId);

  /// Cites [noteId] in [style], or by what its folder or every note chooses when [style] is null.
  Future<void> setNoteStyle(String noteId, CitationStyle? style) async {
    await _repository.setStyleOf(CitationRepository.noteStylePrefix, noteId, style?.id);
    _noteStyles = {..._noteStyles}..remove(noteId);
    if (style != null) _noteStyles[noteId] = style.id;
    _version++;
    notifyListeners();
  }

  /// Cites the notes of [folderId] (and of the folders in it that have no choice of their own) in [style]; null: as the folder
  /// around it, or every note.
  Future<void> setFolderStyle(String folderId, CitationStyle? style) async {
    await _repository.setStyleOf(CitationRepository.folderStylePrefix, folderId, style?.id);
    _folderStyles = {..._folderStyles}..remove(folderId);
    if (style != null) _folderStyles[folderId] = style.id;
    _version++;
    notifyListeners();
  }

  Future<void> setStyle(CitationStyle style) async {
    if (style.id == _style.id) return;
    _style = style;
    _version++;
    await _repository.setStyle(style.id);
    notifyListeners();
  }

  /// Adds [s], giving it a key if it has none or the key is another source's. Returns the source as stored.
  Future<CitationSource> add(CitationSource s) async {
    final key = s.id.trim().isEmpty || _byId.containsKey(s.id) ? CitationSource.makeKey(s, _byId.keys.toSet()) : s.id.trim();
    final stored = key == s.id ? s : s.copyWith(id: key);
    await _repository.save(stored);
    _set([..._sources, stored]);
    return stored;
  }

  /// Whether the library can say where its sources are cited.
  bool get knowsUsage => _citedIn != null;

  /// The notes that cite each key, the keys of sources that are not in the library included; empty when that is not known.
  Future<Map<String, List<NoteRef>>> usage() async => await _citedIn?.call(has) ?? const {};

  /// The source of the library that [s] is a second copy of (the same DOI, or the same title, year and first author), if there is
  /// one. [except] is a key that does not count: the source being changed.
  CitationSource? duplicateOf(CitationSource s, {String? except}) {
    for (final o in _sources) {
      if (o.id != except && _same(o, s)) return o;
    }
    return null;
  }

  /// Adds what was imported. A source that is in the library already (the same DOI, or the same title and year) is left out.
  /// Returns how many were added.
  Future<int> addAll(Iterable<CitationSource> imported) async {
    var added = 0;
    for (final s in imported) {
      if (s.title.trim().isEmpty && s.authors.isEmpty) continue;
      if (_sources.any((o) => _same(o, s))) continue;
      await add(s);
      added++;
    }
    return added;
  }

  static String _doi(String s) => s.toLowerCase().replaceFirst(RegExp(r'^(https?://(dx\.)?doi\.org/|doi:)'), '').trim();

  /// A title as letters and digits only, so that case, accents and punctuation do not make two titles different.
  static String _words(String s) => CitationStyle.fold(CitationStyle.plain(s)).replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static String _first(CitationSource s) => CitationStyle.fold((s.authors.isNotEmpty ? s.authors : s.editors).firstOrNull?.family ?? '');

  static bool _same(CitationSource a, CitationSource b) =>
      (a.doi.isNotEmpty && _doi(a.doi) == _doi(b.doi)) ||
      (_words(a.title).isNotEmpty && _words(a.title) == _words(b.title) && a.year == b.year && _first(a) == _first(b));

  /// Saves changes to the source that was [oldId]; if its key changed, [s] has the new one (which must be free).
  Future<void> update(String oldId, CitationSource s) async {
    final added = await _repository.addedAt(oldId);
    if (s.id != oldId) {
      if (_byId.containsKey(s.id)) throw ArgumentError('There is a source with the key ${s.id} already.');
      await _repository.rename(oldId, s, added: added);
    } else {
      await _repository.save(s, added: added);
    }
    _set([for (final o in _sources) o.id == oldId ? s : o]);
  }

  Future<void> remove(String id) async {
    await _repository.delete(id);
    _set([for (final o in _sources) if (o.id != id) o]);
  }

  /// A key that is free, for a source about to be added.
  String freeKey(CitationSource s) => CitationSource.makeKey(s, _byId.keys.toSet());

  String? _memoText;
  String? _memoStyle;
  int _memoVersion = -1;
  CitationDocument? _memo;

  /// [text] with its citations worked out in [style] (else the one for every note), or null when there are none in it or citations
  /// are off. Asked for on every draw of a text, so the last answer is kept.
  CitationDocument? documentFor(String text, {CitationStyle? style}) {
    if (!enabled() || !text.contains('@')) return null;
    final use = style ?? _style;
    if (_memoText == text && _memoVersion == _version && _memoStyle == use.id) return _memo;
    final doc = CitationDocument(use, _byId, text);
    _memoText = text;
    _memoStyle = use.id;
    _memoVersion = _version;
    return _memo = doc.isEmpty ? null : doc;
  }
}

/// A note, as the library names it where a source is cited.
typedef NoteRef = ({String id, String title});

/// What the texts of a note below it need to know to cite: the style the note is cited in when it is not the one for every note,
/// and all the text of the note, so that the citations of its text boxes and its document are numbered and listed as one.
class CitationStyleScope extends InheritedWidget {
  final CitationStyle? style;

  /// All the text of the note, asked for when a text is drawn (null: each text stands alone).
  final String Function()? wholeText;

  const CitationStyleScope({super.key, required this.style, this.wholeText, required super.child});

  static CitationStyle? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<CitationStyleScope>()?.style;

  /// The citations of [own], a text of the note shown here, worked out with the rest of the note (null: none, or citations are off).
  static CitationDocument? documentFor(BuildContext context, String own) {
    final service = CitationScope.maybeOf(context);
    if (service == null) return null;
    final scope = context.dependOnInheritedWidgetOfExactType<CitationStyleScope>();
    final whole = scope?.wholeText?.call();
    return service.documentFor(whole != null && whole.contains(own) ? whole : own, style: scope?.style);
  }

  @override
  bool updateShouldNotify(CitationStyleScope old) => old.style?.id != style?.id;
}

/// Hands the [CitationService] down to the texts that show citations.
class CitationScope extends InheritedNotifier<CitationService> {
  const CitationScope({super.key, required CitationService service, required super.child}) : super(notifier: service);

  static CitationService? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<CitationScope>()?.notifier;
}
