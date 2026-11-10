import '../data/note_repository.dart';
import '../data/task_repository.dart';
import '../extensions/extension_host.dart';
import '../extensions/library_api.dart';
import '../extensions/notes_read_api.dart';
import '../extensions/pdf_text.dart';
import '../reminders/reminder_service.dart';
import '../sync/calendar_access.dart';

/// What the assistant that writes the weekly review reads through (see `readingTools`): the person's notes, the text of their PDFs and
/// their tasks, as the database holds them. No note is open, so a PDF is always named by its note.
class ReviewAgentApi extends ExtensionApi with LibraryApi, NotesReadApi {
  final NoteRepository repository;
  final TaskRepository tasks;

  ReviewAgentApi(this.repository, this.tasks);

  @override
  NoteRepository get notesRepository => repository;

  @override
  TaskRepository? get libraryTasks => tasks;

  @override
  ReminderService? get libraryReminders => null;

  @override
  CalendarAccess? get libraryCalendar => null;

  @override
  String? get libraryNoteId => null;

  Future<List<String>> _pdfPages(String? id) async {
    if (id == null || id.isEmpty) throw ExtensionError('No note is open: give the "id" of the note whose PDF to read.');
    final pages = await repository.text.pdfPages(id);
    return pages ?? (throw ExtensionError('There is no PDF to read in that note (it is not a PDF note, it is locked, or the app has not read its text yet).'));
  }

  @override
  Future<String> readPdf({String? id, int? from, int? to}) async => readPdfPages(await _pdfPages(id), from: from, to: to);

  @override
  Future<List<Map<String, Object?>>> searchPdf(String query, {String? id}) async => searchPdfPages(await _pdfPages(id), query);
}
