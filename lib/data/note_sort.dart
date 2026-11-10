import 'note_data.dart';

/// How a list of notes is put in order.
enum NoteSort { changed, oldest, titleAscending, titleDescending, type }

/// [notes] in the order of [sort]; with [starredFirst] the favorites come before the rest (each part in the same order).
/// A locked note is ordered by what its list shows ("Locked note"), never by its real title.
List<NoteSummary> sortNotes(Iterable<NoteSummary> notes, NoteSort sort, {bool starredFirst = true}) {
  int byTitle(NoteSummary a, NoteSummary b) => a.shownTitle.toLowerCase().compareTo(b.shownTitle.toLowerCase());
  int byNewest(NoteSummary a, NoteSummary b) => b.updatedAt.compareTo(a.updatedAt);
  int order(NoteSummary a, NoteSummary b) {
    final c = switch (sort) {
      NoteSort.changed => byNewest(a, b),
      NoteSort.oldest => -byNewest(a, b),
      NoteSort.titleAscending => byTitle(a, b),
      NoteSort.titleDescending => -byTitle(a, b),
      NoteSort.type => (a.isPdf ? 1 : 0).compareTo(b.isPdf ? 1 : 0) != 0 ? (a.isPdf ? 1 : 0).compareTo(b.isPdf ? 1 : 0) : byNewest(a, b),
    };
    // (ties stay in a fixed order, so the list does not jump around)
    return c != 0 ? c : byTitle(a, b) != 0 ? byTitle(a, b) : a.id.compareTo(b.id);
  }

  final list = notes.toList()..sort(order);
  if (!starredFirst) return list;
  return [...list.where((n) => n.favorite), ...list.where((n) => !n.favorite)];
}
