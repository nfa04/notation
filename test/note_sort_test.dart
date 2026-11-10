import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/data/note_sort.dart';

void main() {
  final now = DateTime(2026, 10, 27);
  NoteSummary note(String id, String title, {int daysAgo = 0, bool pdf = false, bool fav = false, int lock = 0}) =>
      NoteSummary(id: id, title: title, updatedAt: now.subtract(Duration(days: daysAgo)), isPdf: pdf, favorite: fav, lockMode: lock);

  final notes = [
    note('1', 'banana', daysAgo: 3),
    note('2', 'Apple', daysAgo: 1, pdf: true),
    note('3', 'cherry', daysAgo: 2, fav: true),
    note('4', 'Date', daysAgo: 9),
  ];
  List<String> ids(NoteSort s, {bool starred = true}) => [for (final n in sortNotes(notes, s, starredFirst: starred)) n.id];

  test('by when they were changed', () {
    expect(ids(NoteSort.changed, starred: false), ['2', '3', '1', '4']);
    expect(ids(NoteSort.oldest, starred: false), ['4', '1', '3', '2']);
  });

  test('by title, ignoring case', () {
    expect(ids(NoteSort.titleAscending, starred: false), ['2', '1', '3', '4']);
    expect(ids(NoteSort.titleDescending, starred: false), ['4', '3', '1', '2']);
  });

  test('notes before PDFs, the newest first within each', () {
    expect(ids(NoteSort.type, starred: false), ['3', '1', '4', '2']);
  });

  test('favourites come first when asked to, each part in order', () {
    expect(ids(NoteSort.changed), ['3', '2', '1', '4']);
  });

  test('a locked note is ordered by what the list calls it, not by its title', () {
    final locked = [note('a', 'Zebra', lock: 1), note('b', 'Apple'), note('c', 'Mango')];
    final order = [for (final n in sortNotes(locked, NoteSort.titleAscending, starredFirst: false)) n.id];
    expect(order, ['b', 'a', 'c']); // "Locked note" lies between Apple and Mango
  });

  test('equal notes keep a fixed order', () {
    final same = [note('b', 'x'), note('a', 'x')];
    expect([for (final n in sortNotes(same, NoteSort.changed)) n.id], ['a', 'b']);
  });
}
