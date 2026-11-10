import '../data/note_data.dart';
import '../tags/tag_names.dart';
import 'search_query.dart';

/// What kind of note to look in.
enum SearchKind { any, notes, pdfs }

/// How recently a note was changed.
enum SearchAge {
  any(null),
  day(Duration(days: 1)),
  week(Duration(days: 7)),
  month(Duration(days: 30)),
  year(Duration(days: 365));

  final Duration? span;
  const SearchAge(this.span);
}

/// How the notes that were found are put in order.
enum SearchOrder { changed, mostMatches, title }

/// The groups of places the search can be limited to; the names (of the note and of its PDF) count as one.
const searchPlaceGroups = <List<SearchPlace>>[
  [SearchPlace.title, SearchPlace.pdfName],
  [SearchPlace.document],
  [SearchPlace.textBox],
  [SearchPlace.pdfText],
  [SearchPlace.handwriting],
];

/// Which notes and which parts of them a search looks in: the query says what to find, this says where.
class SearchFilter {
  /// The places of a note to look in.
  final Set<SearchPlace> places;
  final SearchKind kind;
  final SearchAge age;

  /// Only notes in this folder (or one inside it), or null for any.
  final String? folderId;
  final bool favoritesOnly;

  /// Only notes with one of these tags (or a tag nested under one of them); empty for any.
  final Set<String> tags;

  static final _allPlaces = Set<SearchPlace>.unmodifiable(SearchPlace.values);

  SearchFilter({Set<SearchPlace>? places, this.kind = SearchKind.any, this.age = SearchAge.any, this.folderId, this.favoritesOnly = false, Set<String> tags = const {}})
      : places = places == null || places.isEmpty ? _allPlaces : Set.unmodifiable(places),
        tags = Set.unmodifiable(tags);

  /// Whether it limits nothing.
  bool get isDefault => places.length == SearchPlace.values.length && kind == SearchKind.any && age == SearchAge.any && folderId == null && !favoritesOnly && tags.isEmpty;

  /// How many of its parts limit something.
  int get activeCount =>
      (places.length == SearchPlace.values.length ? 0 : 1) +
      (kind == SearchKind.any ? 0 : 1) +
      (age == SearchAge.any ? 0 : 1) +
      (folderId == null ? 0 : 1) +
      (favoritesOnly ? 1 : 0) +
      (tags.isEmpty ? 0 : 1);

  /// Whether it limits which notes are looked in (and not only which parts of them).
  bool get limitsNotes => kind != SearchKind.any || age != SearchAge.any || folderId != null || favoritesOnly || tags.isNotEmpty;

  SearchFilter copyWith({Set<SearchPlace>? places, SearchKind? kind, SearchAge? age, String? folderId, bool clearFolder = false, bool? favoritesOnly, Set<String>? tags}) => SearchFilter(
        places: places ?? this.places,
        kind: kind ?? this.kind,
        age: age ?? this.age,
        folderId: clearFolder ? null : folderId ?? this.folderId,
        favoritesOnly: favoritesOnly ?? this.favoritesOnly,
        tags: tags ?? this.tags,
      );

  /// Whether [note] passes the limits on notes. [folders] tells the folder tree, [now] is what "recently" counts back from and
  /// [noteTags] are the tags of the note.
  bool allowsNote(NoteSummary note, Map<String, FolderEntry> folders, {DateTime? now, Set<String> noteTags = const {}}) {
    if (kind == SearchKind.notes && note.isPdf) return false;
    if (kind == SearchKind.pdfs && !note.isPdf) return false;
    if (favoritesOnly && !note.favorite) return false;
    final span = age.span;
    if (span != null && note.updatedAt.isBefore((now ?? DateTime.now()).subtract(span))) return false;
    if (folderId != null && !_inFolder(note.folderId, folders)) return false;
    if (tags.isNotEmpty && !noteTags.any((t) => tags.any((wanted) => tagIsUnder(t, wanted)))) return false;
    return true;
  }

  bool _inFolder(String? from, Map<String, FolderEntry> folders) {
    var id = from;
    for (var depth = 0; id != null && depth < 64; depth++) {
      if (id == folderId) return true;
      id = folders[id]?.parentId;
    }
    return false;
  }

  /// The pieces of text in [sources] that this lets through.
  List<SearchSource> apply(List<SearchSource> sources, Map<String, NoteSummary> notes, Map<String, FolderEntry> folders,
      {DateTime? now, Map<String, Set<String>> tagsOfNotes = const {}}) {
    if (isDefault) return sources;
    final byNote = <String, bool>{};
    return [
      for (final s in sources)
        if (places.contains(s.place) &&
            (!limitsNotes ||
                byNote.putIfAbsent(s.noteId, () {
                  final n = notes[s.noteId];
                  return n != null && allowsNote(n, folders, now: now, noteTags: tagsOfNotes[s.noteId] ?? const {});
                })))
          s,
    ];
  }

  Map<String, Object?> toJson() => {
        'places': [for (final p in places) p.name],
        'kind': kind.name,
        'age': age.name,
        if (folderId != null) 'folder': folderId,
        'fav': favoritesOnly,
        'tags': tags.toList()..sort(),
      };

  /// The filter [toJson] made; what is missing or unknown counts as no limit.
  static SearchFilter fromJson(Map<Object?, Object?> j) => SearchFilter(
        places: {
          for (final n in (j['places'] as List?) ?? const [])
            for (final p in SearchPlace.values)
              if (p.name == n) p,
        },
        kind: SearchKind.values.where((k) => k.name == j['kind']).firstOrNull ?? SearchKind.any,
        age: SearchAge.values.where((a) => a.name == j['age']).firstOrNull ?? SearchAge.any,
        folderId: j['folder'] as String?,
        favoritesOnly: j['fav'] == true,
        tags: {for (final t in (j['tags'] as List?) ?? const []) '$t'},
      );
}
