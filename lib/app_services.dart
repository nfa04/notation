import 'ai/ai_service.dart';
import 'ai/ai_switch.dart';
import 'automations/automation_service.dart';
import 'review/study_planner.dart';
import 'citations/citation_service.dart';
import 'collab/collab_service.dart';
import 'data/bookmark_repository.dart';
import 'capture/capture_service.dart';
import 'review/weekly_review_service.dart';
import 'data/audio_repository.dart';
import 'data/card_repository.dart';
import 'data/link_repository.dart';
import 'data/tag_repository.dart';
import 'data/note_file_service.dart';
import 'data/note_repository.dart';
import 'data/task_repository.dart';
import 'devicesync/device_sync_service.dart';
import 'extensions/extension_service.dart';
import 'features/feature.dart';
import 'reminders/reminder_service.dart';
import 'history/note_history.dart';
import 'ink/handwriting_service.dart';
import 'ink/math_service.dart';
import 'llm/embedding_service.dart';
import 'llm/llm_service.dart';
import 'mcp/mcp_service.dart';
import 'lock/note_lock_service.dart';
import 'profile/user_profile.dart';
import 'images/subject_service.dart';
import 'scan/ocr_service.dart';
import 'speech/speech_to_text.dart';
import 'spelling/spell_service.dart';
import 'shortcuts/shortcut_service.dart';
import 'style/accessibility.dart';
import 'style/app_theme.dart';
import 'style/style_service.dart';
import 'style/stylus_settings.dart';
import 'sync/caldav_service.dart';
import 'sync/device_calendar_service.dart';
import 'sync/ics_service.dart';
import 'sync/task_calendar_mirror.dart';

/// Every service of the app, made once in `main` and handed down to the screens in one piece. A service that is null is not offered
/// (tests leave out what they do not need).
class AppServices {
  final NoteRepository repository;
  final TaskRepository tasks;
  final CalDavService caldav;
  final DeviceCalendarService device;
  final StyleService style;
  final AppTheme appTheme;
  final IcsCalendarService? ics;

  /// Puts tasks on a calendar as events; null: not offered.
  final TaskCalendarMirror? mirror;

  /// Writes down what is said (Whisper); null: not offered.
  final SpeechToText? speech;

  /// Syncs the profile with the person's other devices; null: not offered.
  final DeviceSyncService? sync;
  final HandwritingService? handwriting;
  final MathService? math;
  final AutomationService? automations;
  final LlmService? llm;
  final EmbeddingService? embeddings;
  final NoteFileService? noteFiles;
  final CollabService? collab;
  final NoteHistory? history;
  final AiService? ai;

  /// The kill switch for every AI feature; null means always on.
  final AiSwitch? aiSwitch;

  /// Which tools are on; null: all of them.
  final FeatureSettings? features;

  /// The library of sources notes cite and the style they are cited in; null: no citations.
  final CitationService? citations;

  /// The spelling dictionaries and the words the person added; null: no spell checking.
  final SpellService? spell;

  /// Reads the text in pictures; null: no text reading.
  final OcrService? ocr;

  /// Finds the subject of a picture, to take the background out; null: only the background colour can be removed.
  final SubjectService? subject;

  /// Larger text, more contrast, less motion; null hides the settings for it.
  final AccessibilitySettings? accessibility;

  /// How the pen is used; null: the usual.
  final StylusSettings? stylus;

  /// Which keys do what; null: the default shortcuts, which cannot be changed.
  final ShortcutService? shortcuts;

  /// Locked notes; null: notes cannot be locked.
  final NoteLockService? locks;

  /// The extensions (scripts the person installed); null: none.
  final ExtensionService? extensions;

  /// Who the person is; null: nobody asked.
  final UserProfile? profile;

  /// Flashcards kept for spaced repetition; null: not offered.
  final CardRepository? cards;

  /// Plans for exams: sessions on the calendar worked out from the cards; null: not offered.
  final StudyPlanner? planner;

  /// The tags of notes; null: no tags.
  final TagRepository? tags;

  /// Bookmarked pages; null: not offered.
  final BookmarkRepository? bookmarks;

  /// Finds which notes refer to a note; null: not offered.
  final LinkRepository? links;

  /// Tells the person when a reminder is due; null: no reminders.
  final ReminderService? reminders;

  /// Sound kept with notes (recordings, notes read aloud); null: not offered.
  final AudioRepository? audio;

  /// Quick notes, clipped pages and what other apps share; null: not offered.
  final CaptureService? capture;

  /// The weekly review; null: not offered.
  final WeeklyReviewService? review;

  /// Lets an AI agent on this computer use the notes; null on a phone (see `mcpSupported`).
  final McpService? mcp;

  const AppServices({
    required this.repository,
    required this.tasks,
    required this.caldav,
    required this.device,
    required this.style,
    required this.appTheme,
    this.ics,
    this.mirror,
    this.speech,
    this.sync,
    this.handwriting,
    this.math,
    this.automations,
    this.llm,
    this.embeddings,
    this.noteFiles,
    this.collab,
    this.history,
    this.ai,
    this.aiSwitch,
    this.features,
    this.citations,
    this.spell,
    this.ocr,
    this.subject,
    this.accessibility,
    this.stylus,
    this.shortcuts,
    this.locks,
    this.extensions,
    this.profile,
    this.cards,
    this.planner,
    this.tags,
    this.bookmarks,
    this.links,
    this.reminders,
    this.audio,
    this.capture,
    this.review,
    this.mcp,
  });
}
