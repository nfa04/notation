import '../data/note_repository.dart';

/// A note the person refers to in a question (`@Title`).
class NoteRef {
  final String id, title;
  const NoteRef(this.id, this.title);
}

/// Finds notes by what the person types after an `@`, and reads the ones they chose.
class NoteLookup {
  final Future<List<NoteRef>> Function(String query) find;

  /// The text of note [id], at most [limit] characters.
  final Future<String> Function(String id, int limit) read;

  const NoteLookup({required this.find, required this.read});

  /// The notes of [repository] (not in the trash, not locked), the newest first; [except] is left out (the note the assistant is in).
  factory NoteLookup.of(NoteRepository repository, {String? except}) => NoteLookup(
        find: (query) async {
          final q = query.trim().toLowerCase();
          return [
            for (final n in await repository.listNotes())
              if (!n.locked && n.id != except && (q.isEmpty || n.title.toLowerCase().contains(q))) NoteRef(n.id, n.title.trim().isEmpty ? 'Untitled' : n.title.trim()),
          ].take(6).toList();
        },
        read: (id, limit) => repository.text.noteText(id, limit: limit),
      );
}
