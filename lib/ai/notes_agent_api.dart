import 'package:flutter/services.dart';

import '../data/note_repository.dart';
import '../data/tag_repository.dart';
import '../data/task_repository.dart';
import '../extensions/extension_host.dart';
import '../extensions/library_api.dart';
import '../extensions/manage_notes_api.dart';
import '../extensions/notes_read_api.dart';
import '../extensions/pdf_text.dart';
import '../reminders/reminder_service.dart';
import '../review/study_planner.dart';
import '../sync/calendar_access.dart';

/// What the assistant of all notes ("Ask your notes") works through: the person's notes as the database holds them (search, read, the
/// text of their PDFs, make, file, tag, star, put in the trash), their tasks, reminders and calendar. No note is open, so a note and
/// its PDF are always named by their id, and nothing inside a note is changed from here (that is the assistant beside the note).
class NotesAgentApi extends ExtensionApi with LibraryApi, NotesReadApi, ManageNotesApi {
  final NoteRepository repository;
  final TaskRepository? tasks;
  final TagRepository? tags;
  final ReminderService? reminders;
  final CalendarAccess? calendar;
  final StudyPlanner? planner;

  /// Whether note [id] is open in an editor (see [ManageNotesApi.isOpenNote]).
  final bool Function(String id) isOpen;

  NotesAgentApi(this.repository, {this.tasks, this.tags, this.reminders, this.calendar, this.planner, required this.isOpen});

  @override
  NoteRepository get notesRepository => repository;
  @override
  TaskRepository? get libraryTasks => tasks;
  @override
  ReminderService? get libraryReminders => reminders;
  @override
  CalendarAccess? get libraryCalendar => calendar;
  @override
  String? get libraryNoteId => null;
  @override
  NoteRepository get managedNotes => repository;
  @override
  TagRepository? get managedTags => tags;
  @override
  bool isOpenNote(String id) => isOpen(id);

  @override
  Future<Map<String, Object?>> note() async => throw ExtensionError('No note is open: find notes with notes.search and read them with notes.read.');

  @override
  Future<void> addTask(String title, {String? due}) async {
    final repo = tasks ?? (throw ExtensionError('Tasks cannot be added here.'));
    await repo.createTask(title, dueDate: due == null ? null : DateTime.parse(due));
  }

  static String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Future<List<Map<String, Object?>>> listStudyPlans() async {
    final p = planner ?? (throw ExtensionError('Study plans cannot be looked at here.'));
    final now = DateTime.now();
    return [
      for (final e in p.plans)
        {
          'id': e.id,
          'name': e.name,
          'exam': _day(e.exam),
          'learned': (e.learned * 100).round(),
          'next': [
            for (final s in e.sessions.where((s) => !s.gone && s.report == null && !s.credited && s.session.start.isAfter(now)).take(3))
              '${_day(s.session.start)} ${s.title}',
          ],
          'needsALook': p.attentionOf(e.id).any,
        },
    ];
  }

  @override
  Future<String> replanStudyPlan(String id) async {
    final p = planner ?? (throw ExtensionError('Study plans cannot be changed here.'));
    final e = p.plans.where((e) => e.id == id).firstOrNull ?? (throw ExtensionError('There is no study plan with the id "$id". study.list has the ids.'));
    final proposal = await p.propose(e);
    if (!proposal.hasChanges) return 'The sessions of "${e.name}" are as they should be: nothing changed.';
    var added = 0, moved = 0;
    for (final s in proposal.sessions) {
      if (s.change == SessionChange.added) added++;
      if (s.change == SessionChange.changed) moved++;
    }
    await p.approve(proposal);
    return 'Done: the sessions of "${e.name}" were planned again ($added new, $moved changed, ${proposal.removed.length} taken away).';
  }

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));

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
