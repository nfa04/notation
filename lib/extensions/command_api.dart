import '../ai/ai_service.dart';
import '../ai/notes_agent_api.dart';
import '../citations/citation_repository.dart';
import '../data/card_repository.dart';
import '../data/link_repository.dart';
import '../data/note_repository.dart';
import '../data/tag_repository.dart';
import 'extension_host.dart';
import 'more_api.dart';

/// What a command of an extension can do when no editor is in the way (from the dashboard, the list of commands or a key): all the
/// notes by their ids, the library (tasks, reminders, calendar), links, tags, flashcards, the AI, and the questions to the person.
/// The note it is about is [noteId], when there is one; the text of a note that is open in an editor is not changed from here (that is
/// done by a command run inside the note).
class CommandApi extends NotesAgentApi with MoreApi {
  final String? noteId;
  final LinkRepository? links;
  final CardRepository? cards;
  final CitationRepository? citations;
  final AiService? ai;
  final void Function(String text)? onMessage;
  final Future<Object?> Function(String kind, Map<String, Object?> args)? onAsk;
  final void Function(String text, double? fraction)? onProgress;

  CommandApi(
    super.repository, {
    super.tasks,
    super.tags,
    super.reminders,
    super.calendar,
    super.planner,
    required super.isOpen,
    this.noteId,
    this.links,
    this.cards,
    this.citations,
    this.ai,
    this.onMessage,
    this.onAsk,
    this.onProgress,
  });

  @override
  NoteRepository? get moreNotes => repository;
  @override
  LinkRepository? get moreLinks => links;
  @override
  TagRepository? get moreTags => tags;
  @override
  CardRepository? get moreCards => cards;
  @override
  CitationRepository? get moreCitations => citations;
  @override
  AiService? get moreAi => ai;
  @override
  String? get moreNoteId => noteId;
  @override
  String? get libraryNoteId => noteId;

  @override
  Future<Map<String, Object?>> note() async {
    final id = noteId;
    if (id == null) throw ExtensionError('There is no note here.');
    final found = (await repository.listNotes()).where((n) => n.id == id).firstOrNull;
    if (found == null) throw ExtensionError('There is no such note.');
    return {'id': id, 'title': found.title, 'text': await repository.text.noteText(id, limit: 20000)};
  }

  @override
  void message(String text) => onMessage?.call(text);

  @override
  Future<Object?> askPerson(String kind, Map<String, Object?> args) {
    final ask = onAsk;
    if (ask == null) throw ExtensionError('The person cannot be asked here.');
    return ask(kind, args);
  }

  @override
  void showProgress(String text, double? fraction) => onProgress?.call(text, fraction);
}
