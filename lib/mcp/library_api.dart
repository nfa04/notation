import '../data/task_repository.dart';
import '../extensions/extension_host.dart';
import '../extensions/library_api.dart';
import '../reminders/reminder_service.dart';
import '../sync/calendar_access.dart';

/// What the assistant (`agentTools`) can do beyond one note, for an agent outside the app: the person's tasks, calendar and reminders.
/// The calls are the editor's ([LibraryApi]), so the answers are the same.
class McpLibraryApi extends ExtensionApi with LibraryApi {
  final TaskRepository tasks;
  final CalendarAccess? calendar;
  final ReminderService? reminders;

  /// A note a reminder is about, when it is to open that note.
  final String? aboutNoteId;

  McpLibraryApi({required this.tasks, this.calendar, this.reminders, this.aboutNoteId});

  @override
  TaskRepository get libraryTasks => tasks;

  @override
  CalendarAccess? get libraryCalendar => calendar;

  @override
  ReminderService? get libraryReminders => reminders;

  @override
  String? get libraryNoteId => aboutNoteId;
}
