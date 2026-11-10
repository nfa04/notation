import '../extensions/extension_service.dart';
import '../extensions/extension_host.dart';
import '../extensions/shared_api.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color, Offset, Size;
import 'package:path/path.dart' as p;

import '../ai/ai_prompt.dart' show AiPrompt;
import '../ai/ai_service.dart';
import '../ai/translation.dart';
import '../data/note_activity.dart';
import '../data/tag_repository.dart';
import '../export/image_export.dart' show ImagePreset;
import '../reminders/reminder.dart';
import '../reminders/reminder_service.dart';
import '../templates/templates.dart';
import '../ai/flashcards.dart';
import '../ai/text_provider.dart' show ProviderState;
import '../citations/citation_service.dart';
import '../citations/source.dart';
import '../data/card_repository.dart';
import '../data/note_file_service.dart';
import '../data/note_repository.dart';
import '../models/canvas_models.dart';
import '../search/ink_indexer.dart';
import '../models/authorship.dart';
import '../data/task_repository.dart';
import '../events/event_bus.dart';
import '../events/event_sources.dart';
import 'automation.dart';
import 'date_finder.dart';
import 'meeting.dart';
import 'rule_writer.dart';
import 'note_sorter.dart';
import 'todo_finder.dart';
import '../l10n/language.dart';

/// The open note, as far as an automation can use it.
abstract class NoteEditorHandle {
  /// Completes once the note is loaded and shown.
  Future<void> get ready;

  /// Writes what is changed in the note to the database now.
  Future<void> saveNow();

  String get noteTitle;

  /// Writes the note as a PDF to [path]; null if it worked, else why not.
  Future<String?> exportPdfTo(String path);

  /// The lines of text of the imported PDF (empty for a note without one).
  Future<List<String>> pdfTextLines();
}

/// An editor that can be given a title from outside (the note it shows has no title yet). A note that is open must be named through its
/// editor, which writes its own title back when it saves.
abstract class TitleSetter {
  void setNoteTitle(String title);
}

/// An editor that can make pictures of its pages and save them where it is told.
abstract class ImageExporter {
  /// Saves a PNG of each page into [dir] in the size of [preset]; says what it did.
  Future<String> exportImagesInto(String dir, ImagePreset preset);
}

/// An editor that can read the writing on its pages ahead of time (see `InkPrefetcher`).
abstract class InkPreparer {
  /// Starts reading the strokes that lie close together as text ([text]) and as formulas ([math]) in the
  /// background while the note is worked on. Says what it will do, or why it cannot.
  Future<String> prepareInk({required bool text, required bool math});
}

/// What reading the dates of a PDF came to.
class ScanReport {
  /// Dates found in the text (including those acted on before).
  final int found;

  /// What the automations did for the new ones.
  final List<String> results;
  final String? error;

  const ScanReport({required this.found, required this.results, this.error});
  const ScanReport.nothing()
      : found = 0,
        results = const [],
        error = null;

  int get acted => results.length;
}

/// A note that a rule asks the person about ("Ask me what to do about the note"), waiting on the dashboard.
class AskItem {
  final String noteId;

  /// What made the rule ask (the event's label).
  final String reason;
  final DateTime since;

  const AskItem(this.noteId, this.reason, this.since);
}

/// One thing a rule did that can be taken back: what kind it is and what is needed to do that.
class UndoStep {
  final String kind;
  final Map<String, Object?> data;

  const UndoStep(this.kind, this.data);

  Map<String, Object?> toJson() => {'k': kind, 'd': data};

  static UndoStep? fromJson(Object? j) => j is Map && j['k'] is String ? UndoStep(j['k'] as String, {...((j['d'] as Map?) ?? const {}).cast<String, Object?>()}) : null;
}

/// One run of a rule, as the log keeps it: when, for which note, what it said, and how to take it back.
class RunRecord {
  final String ruleId;
  final DateTime at;
  final String? noteId;
  final String title;
  final String result;
  final List<UndoStep> steps;
  final bool undone;

  const RunRecord(this.ruleId, this.at, this.noteId, this.title, this.result, this.steps, {this.undone = false});

  bool get canUndo => steps.isNotEmpty && !undone;

  RunRecord asUndone() => RunRecord(ruleId, at, noteId, title, result, steps, undone: true);

  Map<String, Object?> toJson() => {
        'r': ruleId,
        't': at.millisecondsSinceEpoch,
        'n': noteId,
        'h': title,
        'x': result,
        if (steps.isNotEmpty) 'u': [for (final s in steps) s.toJson()],
        if (undone) 'z': true,
      };

  static RunRecord? fromJson(Object? j) {
    if (j is! Map || j['r'] is! String || j['t'] is! int) return null;
    return RunRecord(j['r'] as String, DateTime.fromMillisecondsSinceEpoch(j['t'] as int), j['n'] as String?, (j['h'] as String?) ?? '', (j['x'] as String?) ?? '',
        [for (final u in (j['u'] as List?) ?? const []) ?UndoStep.fromJson(u)],
        undone: j['z'] == true);
  }
}

const _undoKey = #automationUndo;
const _deferredKey = #automationDeferred;

/// Set while a chain runs: work that would be queued in the background is done on the spot, as the next step needs what it says.
const _inlineKey = #automationInline;

/// What a rule would have touched, as far as can be told without running it.
class RulePreview {
  /// One sentence: how many notes (tasks, events) it would apply to now.
  final String headline;

  /// A few of them, by name.
  final List<String> examples;

  const RulePreview(this.headline, this.examples);
}

/// What the person can answer.
enum AskAnswer {
  /// Still wanted: counts as opened, so that it is not asked about again for as long as it went stale before.
  keep,

  /// Into the folder "Archive" (made if it is not there).
  archive,

  /// A reminder in a week.
  remind,

  /// The assistant makes flashcards of it.
  cards,

  /// Not now: the question goes, nothing else changes.
  later,
}

/// The automations, and running them when their event happens.
class AutomationService extends ChangeNotifier {
  final NoteRepository _notes;
  final TaskRepository _tasks;
  final DateTime Function() _now;
  static const _key = 'automations';
  static const _firedKey = 'automations_fired';
  static const _seenKey = 'automations_seen';

  /// When each note was last edited as of the last time an opening or closing automation ran for it:
  /// `automation|note|event` -> time of the edit. A note that has not been edited since is skipped.
  Map<String, int> _seen = {};

  /// Dates already acted on, so that opening a note again does not add the
  /// same task again: `automation|note|date key`.
  Set<String> _fired = {};

  List<Automation> _all = [];

  static const _logKey = 'automations_log';
  static const _logPerRule = 20;
  static const _logTotal = 300;
  List<RunRecord> _log = [];

  /// The last runs of rule [ruleId], the latest first.
  List<RunRecord> runsOf(String ruleId, {int limit = _logPerRule}) => [for (final r in _log.reversed) if (r.ruleId == ruleId) r].take(limit).toList();

  /// Notes that something done for the rule can be taken back, for the step to be told ([_willUndo]) from inside the work.
  void _willUndo(String kind, Map<String, Object?> data) => (Zone.current[_undoKey] as List<UndoStep>?)?.add(UndoStep(kind, data));

  /// Says that the work goes on in the background and notes what it came to itself, so that the run is not logged for what is said at
  /// once ("...in the background").
  void _deferred() => (Zone.current[_deferredKey] as List<bool>?)?.add(true);

  /// Runs [body], and gives what it said, the steps it noted for taking it back and whether it left its work for the background. A
  /// failure is what it says; the steps noted before it stay.
  Future<(String, List<UndoStep>, bool)> _recorded(Future<String> Function() body) async {
    final steps = <UndoStep>[];
    final later = <bool>[];
    String result;
    try {
      result = await runZoned(body, zoneValues: {_undoKey: steps, _deferredKey: later});
    } catch (e) {
      result = tr('Failed: {error}', {'error': '$e'.replaceFirst('Bad state: ', '')});
    }
    return (result, steps, later.isNotEmpty);
  }

  /// Puts a run in the log (the oldest go when there are too many).
  void _record(Automation a, String result, {String? noteId, String title = '', List<UndoStep> steps = const []}) {
    _log.add(RunRecord(a.id, _now(), noteId, title, result, steps));
    final mine = _log.where((r) => r.ruleId == a.id).length;
    if (mine > _logPerRule * 2) _log.remove(_log.firstWhere((r) => r.ruleId == a.id));
    while (_log.length > _logTotal) {
      _log.removeAt(0);
    }
    unawaited(_notes.settings.set(_logKey, jsonEncode([for (final r in _log) r.toJson()])));
  }

  /// Takes back what a run did, as far as it can be: the steps in reverse. Says what came of it.
  Future<String> undo(RunRecord run) async {
    final i = _log.indexWhere((r) => identical(r, run));
    if (!run.canUndo || i < 0) return tr('There is nothing to take back');
    final said = <String>[];
    var failed = false;
    for (final step in run.steps.reversed) {
      try {
        said.add(await _undoStep(step));
      } catch (e) {
        failed = true;
        said.add(tr('Could not take it back: {error}', {'error': '$e'.replaceFirst('Bad state: ', '')}));
      }
    }
    // (a run that could not be taken back stays as it was, to try again)
    if (!failed) _log[i] = run.asUndone();
    notifyListeners();
    await _notes.settings.set(_logKey, jsonEncode([for (final r in _log) r.toJson()]));
    return said.join(' ');
  }

  Future<String> _undoStep(UndoStep s) async {
    final d = s.data;
    switch (s.kind) {
      case 'task':
        await _tasks.deleteTask(d['id'] as String);
        return tr('The task is gone.');
      case 'tag':
        await _tags?.remove([d['noteId'] as String], d['tag'] as String);
        return tr('The tag is taken off.');
      case 'star':
        await _notes.setFavorite(d['noteId'] as String, false);
        return tr('The star is taken off.');
      case 'move':
        await _notes.moveNote(d['noteId'] as String, d['from'] as String?);
        return tr('The note is back in its folder.');
      case 'note':
        await _notes.trashNote(d['noteId'] as String);
        return tr('The note is in the trash.');
      case 'reminder':
        await _reminders?.reminders.remove(d['id'] as String);
        return tr('The reminder is gone.');
      case 'cards':
        for (final id in (d['ids'] as List).cast<String>()) {
          await _cards?.remove(id);
        }
        return tr('The flashcards are gone.');
      case 'title':
        final id = d['noteId'] as String;
        final open = openEditor?.call(id);
        if (open is TitleSetter) {
          (open as TitleSetter).setNoteTitle(d['was'] as String);
        } else if (open == null) {
          await _notes.renameNote(id, d['was'] as String);
        } else {
          throw StateError(tr('the note is open'));
        }
        return tr('The title is back.');
      case 'box':
        final id = d['noteId'] as String;
        if (openEditor?.call(id) != null) throw StateError(tr('the note is open: close it first'));
        await _notes.removeTextBox(id, d['page'] as int, d['id'] as String);
        return tr('The text box is gone.');
    }
    return tr('That cannot be taken back.');
  }

  static const _askKey = 'automations_ask';
  List<AskItem> _ask = [];

  /// The notes a rule asked about, the one asked first first.
  List<AskItem> get asking => List.unmodifiable(_ask);

  /// What happened to the last answer that took a while (flashcards), for the dashboard to say.
  String? askNotice;

  /// Whether "make flashcards" can be offered as an answer.
  bool get canAskForCards => _cards != null && _assistantReady;

  /// The editor that has note [id] open now, if there is one (the app's shell says); automations that change a note need it, as
  /// the editor would overwrite a change made behind its back.
  NoteEditorHandle? Function(String id)? openEditor;

  /// How long an action that writes into a note waits for an editor that has it open to let go.
  Duration editorWait = const Duration(seconds: 10);

  /// Writes a better title for a line (the language model); null when it has none.
  final Future<String?> Function(String text)? _smartTitle;

  /// Reads handwriting as text (the handwriting model), and whether it can.
  final Future<String> Function(List<DrawingStroke> strokes)? _readInk;
  final bool Function()? _inkReady;

  /// Files notes under the folder they resemble (the sentence model); null when there is none.
  final NoteSorter? _sorter;
  final ExtensionService? _extensions;

  /// Makes the files of notes; null when there is no way to.
  final NoteFileService? _noteFiles;

  /// The assistant and the cards kept for review, for the automations that write or count flashcards; null where there are none.
  final AiService? _ai;
  final CardRepository? _cards;
  final bool Function()? _aiReady;
  final TagRepository? _tags;
  final CitationService? _citations;
  final TemplateService? _templates;
  final ReminderService? _reminders;

  /// The calendar events between two times, from every calendar there is (for "a calendar event is about to start"); null where
  /// there is no calendar.
  final Future<List<UpcomingEvent>> Function(DateTime from, DateTime to)? _upcoming;

  /// Where the events come from; the automations react to what is emitted on it.
  final EventBus bus;
  void Function()? _unlisten;

  AutomationService(
    this._notes,
    this._tasks, {
    DateTime Function()? now,
    Future<String?> Function(String text)? smartTitle,
    Future<String> Function(List<DrawingStroke> strokes)? readInk,
    bool Function()? inkReady,
    NoteSorter? sorter,
    NoteFileService? noteFiles,
    ExtensionService? extensions,
    AiService? ai,
    CardRepository? cards,
    bool Function()? aiReady,
    TagRepository? tags,
    CitationService? citations,
    TemplateService? templates,
    ReminderService? reminders,
    Future<List<UpcomingEvent>> Function(DateTime from, DateTime to)? upcomingEvents,
    EventBus? bus,
  })  : bus = bus ?? EventBus(),
        _upcoming = upcomingEvents,
        _ai = ai,
        _cards = cards,
        _aiReady = aiReady,
        _tags = tags,
        _citations = citations,
        _templates = templates,
        _reminders = reminders,
        _extensions = extensions,
        _now = now ?? DateTime.now,
        _sorter = sorter,
        _noteFiles = noteFiles,
        _smartTitle = smartTitle,
        _readInk = readInk,
        _inkReady = inkReady;

  List<Automation> get all => List.unmodifiable(_all);

  /// The events a rule can be made for: every one announced on the [bus] that is not plumbing.
  List<AutomationEvent> get events => [for (final t in bus.types) if (!t.internal) AutomationEvent.of(t)];

  Future<void> load() async {
    _all = Automation.decodeAll(await _notes.settings.get(_key));
    try {
      _fired = {...((jsonDecode(await _notes.settings.get(_firedKey) ?? '[]') as List).cast<String>())};
    } catch (_) {
      _fired = {};
    }
    try {
      _seen = {for (final e in (jsonDecode(await _notes.settings.get(_seenKey) ?? '{}') as Map).entries) '${e.key}': e.value as int};
    } catch (_) {
      _seen = {};
    }
    try {
      _log = [for (final j in jsonDecode(await _notes.settings.get(_logKey) ?? '[]') as List) ?RunRecord.fromJson(j)];
    } catch (_) {
      _log = [];
    }
    try {
      _ask = [
        for (final j in jsonDecode(await _notes.settings.get(_askKey) ?? '[]') as List)
          AskItem((j as Map)['n'] as String, j['r'] as String, DateTime.fromMillisecondsSinceEpoch(j['t'] as int)),
      ];
    } catch (_) {
      _ask = [];
    }
    for (final e in AutomationEvent.values) {
      bus.register(EventType(e.name, e.label, hasNote: e.hasNote, hasEditor: e.hasEditor));
    }
    bus.register(tickEvent);
    bus.register(minuteEvent);
    _unlisten ??= bus.listen(_onEvent);
    notifyListeners();
  }

  /// Runs the automations of an event announced on the [bus].
  Future<void> _onEvent(AppEvent e) async {
    if (e.type == tickEvent.id) {
      await checkStale();
      return;
    }
    if (e.type == minuteEvent.id) {
      await checkEventsStarting();
      return;
    }
    final type = bus.type(e.type);
    if (type == null) return; // nobody said what this is
    final event = AutomationEvent.of(type);
    await run(event,
        noteId: e.noteId,
        title: e.title,
        folderId: e.folderId,
        editor: e.editor as NoteEditorHandle?,
        found: e.data['found'] as FoundDate?,
        todo: e.data['todo'] as TodoItem?,
        data: e.data);
    if (event == AutomationEvent.noteClosed && e.noteId != null) await scanTodos(e.noteId!, title: e.title, folderId: e.folderId);
  }

  /// Reads the words and the handwriting (as far as it was read for the search) of note [noteId] for lines that ask for something to
  /// be done, and runs the "to-do line found" automations for each one that is new. Returns what they did, a line for each.
  Future<List<String>> scanTodos(String noteId, {String title = '', String? folderId}) async {
    if (!_all.any((a) => a.enabled && a.event == AutomationEvent.todoFound)) return const [];
    final lines = <String>[
      ...(await _notes.text.noteText(noteId, limit: 200000)).split('\n'),
      for (final ink in await _notes.text.inkTexts(noteId)) ...ink.text.split('\n'),
    ];
    final results = <String>[];
    for (final todo in findTodos(lines, _now())) {
      results.addAll(await run(AutomationEvent.todoFound, noteId: noteId, title: title, folderId: folderId, todo: todo));
    }
    return results;
  }

  Future<void> _save() => _notes.settings.set(_key, Automation.encodeAll(_all));

  /// Opening and closing run an automation only for a note that was edited since the last time.
  static bool _onlyWhenChanged(AutomationEvent e) => e == AutomationEvent.noteOpened || e == AutomationEvent.noteClosed;

  String _seenKeyOf(String automationId, String noteId, AutomationEvent event) => '$automationId|$noteId|${event.name}';

  /// Notes that the note was left as it is now for [automationId] and [event].
  Future<void> _remember(String automationId, String noteId, AutomationEvent event) async {
    final edited = await _notes.noteEditedAt(noteId);
    if (edited == null) return;
    _seen[_seenKeyOf(automationId, noteId, event)] = edited.millisecondsSinceEpoch;
    if (_seen.length > 4000) _seen.remove(_seen.keys.first); // the oldest entries go
    await _notes.settings.set(_seenKey, jsonEncode(_seen));
  }

  Future<void> add(Automation a) async {
    _all = [..._all, a];
    notifyListeners();
    await _save();
  }

  Future<void> update(Automation a) async {
    _all = [for (final x in _all) x.id == a.id ? a : x];
    notifyListeners();
    await _save();
  }

  Future<void> remove(String id) async {
    _all = _all.where((a) => a.id != id).toList();
    notifyListeners();
    await _save();
  }

  /// Forgets which dates of which notes [automationId] acted on, so that the
  /// next scan acts on them again.
  Future<void> forgetHandled(String automationId) async {
    _fired.removeWhere((k) => k.startsWith('$automationId|'));
    await _notes.settings.set(_firedKey, jsonEncode(_fired.toList()));
    notifyListeners();
  }

  /// Reads the text of the PDF in [editor] and runs the "date found" automations
  /// for each date in it that has not been acted on before. Says what happened.
  Future<ScanReport> scanForDates(NoteEditorHandle editor, {required String noteId, String? folderId}) async {
    final wanted = _all.where((a) => a.enabled && a.event == AutomationEvent.dateFound && (a.folderId == null || a.folderId == folderId));
    if (wanted.isEmpty) return const ScanReport.nothing();
    try {
      await editor.ready;
      final lines = await editor.pdfTextLines();
      final dates = lines.isEmpty ? <FoundDate>[] : findDates(lines, _now());
      final results = <String>[];
      for (final found in dates) {
        results.addAll(await run(AutomationEvent.dateFound,
            noteId: noteId, title: editor.noteTitle, folderId: folderId, found: found));
      }
      if (results.isEmpty) {
        // say so where the automation is listed: nothing was left to do, and why
        final note = dates.isEmpty
            ? tr('No dates found in "{title}"', {'title': editor.noteTitle})
            : tr(dates.length == 1 ? '1 date found in "{title}", all handled before' : '{n} dates found in "{title}", all handled before',
                {'n': dates.length, 'title': editor.noteTitle});
        for (final a in wanted) {
          final i = _all.indexWhere((x) => x.id == a.id);
          if (i >= 0) _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: note);
        }
        notifyListeners();
        await _save();
      }
      return ScanReport(found: dates.length, results: results);
    } catch (e) {
      return ScanReport(found: 0, results: const [], error: '$e');
    }
  }

  Future<void> _inkQueue = Future.value();

  /// Settles when the handwriting conversions started so far are done.
  Future<void> get conversionsDone => _inkQueue;

  Future<void> _convertInBackground(String automationId, String noteId, AutomationEvent? event) async {
    String result;
    try {
      result = await _convertHandwriting(noteId);
    } catch (e) {
      result = tr('Could not read the handwriting: {error}', {'error': e});
    }
    // the boxes it wrote are part of the note now, not a change to run for again
    if (event != null && _onlyWhenChanged(event)) await _remember(automationId, noteId, event);
    final i = _all.indexWhere((x) => x.id == automationId);
    if (i >= 0) _record(_all[i], result, noteId: noteId);
    if (i >= 0) {
      _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: result);
      notifyListeners();
      await _save();
    }
  }

  /// Reads the pen strokes of each page of the note and puts the text in a box
  /// under them. The box's id carries a fingerprint of the ink, so a page is
  /// read again only when its ink has changed, and then the old box is replaced.
  /// It writes the box alone, not the whole note, which may be open somewhere.
  /// Reads the handwriting of all the notes for the search (see `InkIndexer`), one note at a time, behind the conversions.
  Future<void> _indexInBackground(String automationId) async {
    String result;
    try {
      final blocks = await InkIndexer(_notes, _readInk!).run();
      result = blocks == 0 ? tr('No new handwriting to read') : trCount(blocks, 'Read 1 piece of handwriting', 'Read {n} pieces of handwriting');
    } catch (e) {
      result = tr('Could not read the handwriting: {error}', {'error': e});
    }
    final i = _all.indexWhere((x) => x.id == automationId);
    if (i >= 0) {
      _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: result);
      notifyListeners();
      await _save();
    }
  }

  Future<String> _convertHandwriting(String noteId) async {
    final read = _readInk!;
    final note = await _notes.loadNote(noteId);
    if (note == null) return 'The note is gone';
    var pages = 0;
    for (final entry in note.strokes.entries) {
      final ink = [for (final s in entry.value) if (s.color.a > 0.9 && Brushes.writes(s.brush) && s.points.length >= 2) s]; // not the highlighter
      if (ink.isEmpty) continue;
      final id = 'hw-${entry.key}-${inkFingerprint(ink)}';
      if ((note.textBoxes[entry.key] ?? const []).any((b) => b.id == id)) continue; // read already
      final text = (await read(ink)).trim();
      if (text.isEmpty) continue;
      var bottom = 0.0;
      for (final s in ink) {
        for (final p in s.points) {
          if (p.dy > bottom) bottom = p.dy;
        }
      }
      final box = TextBoxWidgetModel(
        id: id,
        position: Offset(40, bottom + 16 > 1050 ? 1050 : bottom + 16),
        size: const Size(720, 0),
        initialText: text,
        fontSize: 14,
        style: const TextBoxStyle(background: Color(0xFFFFF8E1), opacity: 0.9, borderWidth: 0, radius: 6),
        author: Authorship.current,
      );
      await _notes.putTextBox(noteId, entry.key, box, replacePrefix: 'hw-${entry.key}-');
      pages++;
    }
    return pages == 0 ? tr('No new handwriting to read') : trCount(pages, 'Read the handwriting of 1 page', 'Read the handwriting of {n} pages');
  }

  Future<void> _assistantQueue = Future.value();

  /// Settles when the work of the assistant started so far is done.
  Future<void> get assistantDone => _assistantQueue;

  bool get _assistantReady => (_aiReady?.call() ?? _ai?.provider?.state == ProviderState.ready) && _ai != null;

  /// Runs [work] after the earlier work of the assistant (a model answers one thing at a time) and notes what it came to as the result
  /// of [a]; the note counts as dealt with for [event] even when the work failed, so it is not tried at every closing.
  void _withAssistant(Automation a, String noteId, AutomationEvent? event, Future<String> Function() work, {String? title}) {
    _deferred();
    _assistantQueue = _assistantQueue.then((_) async {
      final (result, steps, _) = await _recorded(work);
      _record(a, result, noteId: noteId.isEmpty ? null : noteId, title: title ?? '', steps: steps);
      if (event != null && _onlyWhenChanged(event)) await _remember(a.id, noteId, event);
      final i = _all.indexWhere((x) => x.id == a.id);
      if (i >= 0) {
        _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: title == null ? result : '"$title": $result');
        notifyListeners();
        await _save();
      }
    }).catchError((Object _) {});
  }

  /// Does [work] in the background, or on the spot (and says what it came to) when a chain is running and the next step needs it.
  Future<String> _background(Automation a, String noteId, AutomationEvent? event, Future<String> Function() work, String started, {String? title}) async {
    if (Zone.current[_inlineKey] == true) return work();
    _withAssistant(a, noteId, event, work, title: title);
    return started;
  }

  /// What a step says when it could not do its work: it ends the chain.
  static bool _stops(String said) {
    final s = said.toLowerCase();
    return const ['failed', 'not ready', 'stayed open', 'too little', 'is gone', 'not available', 'not there', 'could not', 'did not make', 'wrote no', 'no note', 'not installed', 'is not known']
        .any(s.contains);
  }

  /// Runs [a], and its later steps ([Automation.then]) one after the other in the background, when it has any; each step gets what the one
  /// before said as `{result}`. Says at once what is going on.
  Future<String> _performRule(Automation a,
      {String? noteId, required String title, NoteEditorHandle? editor, FoundDate? found, TodoItem? todo, AutomationEvent? event, Map<String, Object?> data = const {}}) async {
    if (a.then.isEmpty) return _perform(a, noteId: noteId, title: title, editor: editor, found: found, todo: todo, event: event, data: data);
    _deferred();
    _assistantQueue = _assistantQueue.then((_) async {
      final (said, steps, _) = await _recorded(() => runZoned(() async {
            final all = [ChainStep(a.action, a.params), ...a.then];
            final lines = <String>[];
            var last = '';
            for (var i = 0; i < all.length; i++) {
              final step = a.copyWith(action: all[i].action, params: all[i].params, then: const []);
              String r;
              try {
                r = await _perform(step,
                    noteId: noteId,
                    title: title,
                    found: found,
                    todo: todo,
                    event: event,
                    data: {...data, 'vars': {..._varsOf(data), 'result': last}});
              } catch (e) {
                r = tr('Failed: {error}', {'error': '$e'.replaceFirst('Bad state: ', '')});
              }
              lines.add('${i + 1}. $r');
              last = r;
              if (_stops(r)) {
                lines.add(tr('The chain stops here.'));
                break;
              }
            }
            return lines.join(' ');
          }, zoneValues: {_inlineKey: true}));
      _record(a, said, noteId: noteId, title: title, steps: steps);
      final i = _all.indexWhere((x) => x.id == a.id);
      if (i >= 0) {
        _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: title.isEmpty ? said : '"$title": $said');
        notifyListeners();
        await _save();
      }
    }).catchError((Object _) {});
    return trCount(1 + a.then.length, 'Doing 1 step in the background...', 'Doing {n} steps in the background...');
  }

  static bool _untitled(String title) {
    final t = title.trim().toLowerCase();
    return t.isEmpty || t == 'untitled' || t == 'untitled note';
  }

  /// A title for a note from its first line when that is short enough to be one: at most 60 characters, cut at a word.
  static String? firstLineTitle(String text) {
    final line = text.split('\n').map((l) => l.replaceFirst(RegExp(r'^[\s#>*\-•☐\[\]]+'), '').trim()).where((l) => l.length >= 3).firstOrNull;
    if (line == null) return null;
    if (line.length <= 60) return line.replaceFirst(RegExp(r'[.:,;]+$'), '');
    final cut = line.lastIndexOf(' ', 60);
    return cut < 25 ? null : '${line.substring(0, cut).replaceFirst(RegExp(r'[.:,;]+$'), '')}…';
  }

  Future<String> _titleOf(String noteId, NoteEditorHandle? editor) async {
    final info = await _notes.noteInfo(noteId);
    if (info == null) return tr('The note is gone');
    final open = editor ?? openEditor?.call(noteId);
    final current = open?.noteTitle ?? info.title;
    if (!_untitled(current)) return tr('Has a title already');
    var text = await _notes.text.noteText(noteId, limit: 1500);
    if (text.startsWith(info.title)) text = text.substring(info.title.length);
    text = text.trim();
    if (text.length < 20) return tr('Too little text to name the note');
    final title = (await _smartTitle?.call(text) ?? firstLineTitle(text))?.trim();
    if (title == null || title.isEmpty) return tr('Found no title for the note');
    if (open is TitleSetter) {
      (open as TitleSetter).setNoteTitle(title);
    } else if (open == null) {
      await _notes.renameNote(noteId, title);
    } else {
      return tr('The note is open and cannot be named from here');
    }
    _willUndo('title', {'noteId': noteId, 'was': current});
    return tr('Named it "{title}"', {'title': title});
  }

  /// Whether rules can be written from a description (the assistant is ready).
  bool get canWriteRules => _assistantReady;

  /// Turns [request] (what the person wants, in their words) into rules that are switched off, for them to look at. Throws when the
  /// assistant cannot answer.
  Future<RuleDrafts> writeRules(String request) async {
    if (!_assistantReady) throw StateError(tr('The assistant is not ready (see Settings)'));
    final answer = await _ai!.generate(rulePrompt(request), maxTokens: 400);
    var n = 0;
    return parseRules(answer, folders: await _notes.listFolders(), newId: () => '${_now().microsecondsSinceEpoch}-${n++}');
  }

  /// What [a] would have touched, looking at what is there now: the notes it is for (those that are stale, for a rule about stale notes;
  /// the to-do lines of the notes, for one about to-do lines), the tasks done, the calendar events of the next day. Nothing is run.
  Future<RulePreview> preview(Automation a) async {
    final now = _now();
    final e = a.event;
    if (e == AutomationEvent.appStarted) return RulePreview(tr('It runs every time the app starts.'), const []);
    if (e == AutomationEvent.taskCompleted) {
      final done = [for (final t in await _tasks.listTasks()) if (t.done) t.title];
      return RulePreview(trCount(done.length, '{n} task is done now', '{n} tasks are done now'), done.take(3).toList());
    }
    if (e == AutomationEvent.calendarEventStarting || e == AutomationEvent.calendarEventEnded) {
      final source = _upcoming;
      if (source == null) return RulePreview(tr('There is no calendar to look at.'), const []);
      final lead = Duration(minutes: (int.tryParse(a.params['minutes'] ?? '') ?? 10).clamp(1, 720));
      final events = [for (final x in await source(now, now.add(const Duration(days: 1)))) if (!x.allDay && nameMatches(a.contains, [x.title])) x];
      return RulePreview(
        trCount(events.length, '{n} event in the next day would be acted on, {lead} minutes before it starts', '{n} events in the next day would be acted on, {lead} minutes before each starts')
            .replaceAll('{lead}', '${lead.inMinutes}'),
        [for (final x in events.take(3)) x.title],
      );
    }
    if (!e.hasNote) return RulePreview(tr('It is not about a note: there is nothing to look at.'), const []);
    final notes = [
      for (final n in await _notes.listNotes())
        if (n.lockMode == 0 && (a.folderId == null || n.folderId == a.folderId) && nameMatches(a.contains, [n.title])) n,
    ];
    if (e == AutomationEvent.noteStale) {
      final weeks = (int.tryParse(a.params['weeks'] ?? '') ?? 4).clamp(1, 520);
      final stale = {for (final s in await _notes.staleNotes(now.subtract(Duration(days: 7 * weeks)))) s.id};
      final hit = [for (final n in notes) if (stale.contains(n.id)) n.title.isEmpty ? tr('Untitled') : n.title];
      return RulePreview(trCount(hit.length, '{n} note has not been opened for {weeks} weeks', '{n} notes have not been opened for {weeks} weeks').replaceAll('{weeks}', '$weeks'), hit.take(5).toList());
    }
    if (e == AutomationEvent.todoFound) {
      var lines = 0;
      final names = <String>[];
      for (final n in notes) {
        final found = findTodos((await _notes.text.noteText(n.id, limit: 50000)).split('\n'), now).length;
        if (found > 0) {
          lines += found;
          names.add('${n.title.isEmpty ? tr('Untitled') : n.title} ($found)');
        }
      }
      return RulePreview(trCount(lines, '{n} to-do line is in your notes now', '{n} to-do lines are in your notes now'), names.take(5).toList());
    }
    final names = [for (final n in notes) n.title.isEmpty ? tr('Untitled') : n.title];
    return RulePreview(
      trCount(notes.length, 'It is for {n} note you have now', 'It is for {n} notes you have now'),
      names.take(5).toList(),
    );
  }

  Future<void> _saveAsk() => _notes.settings
      .set(_askKey, jsonEncode([for (final a in _ask) {'n': a.noteId, 'r': a.reason, 't': a.since.millisecondsSinceEpoch}]));

  /// Puts [noteId] on the list of notes the person is asked about (once).
  Future<String> _askAbout(String noteId, AutomationEvent? event) async {
    if (_ask.any((a) => a.noteId == noteId)) return tr('It is on the dashboard already');
    _ask = [..._ask, AskItem(noteId, event?.label ?? '', _now())];
    notifyListeners();
    await _saveAsk();
    return tr('Waiting for your answer on the dashboard');
  }

  /// Does what the person answered about [noteId] and takes the question away. Says what it did.
  Future<String> answer(String noteId, AskAnswer what) async {
    _ask = [for (final a in _ask) if (a.noteId != noteId) a];
    notifyListeners();
    await _saveAsk();
    switch (what) {
      case AskAnswer.later:
        return tr('Left as it is');
      case AskAnswer.keep:
        await _notes.markOpened(noteId, at: _now());
        return tr('Kept');
      case AskAnswer.archive:
        final folders = await _notes.listFolders();
        final archive = folders.where((f) => f.parentId == null && f.name.toLowerCase() == 'archive').firstOrNull;
        await _notes.moveNote(noteId, archive?.id ?? await _notes.createFolder('Archive'));
        return tr('Moved to the folder Archive');
      case AskAnswer.remind:
        final svc = _reminders;
        if (svc == null) return tr('Reminders are not available here');
        final info = await _notes.noteInfo(noteId);
        final now = _now();
        await svc.ensurePermission();
        await svc.reminders.add(
            kind: ReminderKind.note, refId: noteId, title: info?.title.isEmpty ?? true ? tr('Untitled Note') : info!.title, at: DateTime(now.year, now.month, now.day + 7, 9));
        await _notes.markOpened(noteId, at: now);
        return tr('You will be reminded in a week');
      case AskAnswer.cards:
        if (!canAskForCards) return tr('The assistant is not ready (see Settings)');
        await _notes.markOpened(noteId, at: _now());
        _assistantQueue = _assistantQueue.then((_) async {
          try {
            askNotice = await _flashcardsOf(noteId, 6);
          } catch (e) {
            askNotice = tr('Failed: {error}', {'error': '$e'.replaceFirst('Bad state: ', '')});
          }
          notifyListeners();
        }).catchError((Object _) {});
        return tr('Writing flashcards in the background...');
    }
  }

  /// The page the note was made from, as a source of the library.
  Future<String> _citeCaptured(String title, Map<String, Object?> data) async {
    final svc = _citations;
    if (svc == null) return tr('Citations are not available here');
    final vars = _varsOf(data);
    final url = vars['url'] ?? '';
    if (url.isEmpty) return tr('There is no address to cite');
    if (svc.sources.any((s) => s.url == url)) return tr('That page is a source already');
    final now = _now();
    String two(int n) => n.toString().padLeft(2, '0');
    final site = vars['site'] ?? '';
    final stored = await svc.add(CitationSource(
      id: '',
      type: SourceType.webpage,
      title: title,
      container: site,
      url: url,
      accessed: '${now.year}-${two(now.month)}-${two(now.day)}',
    ));
    return tr('Added to the sources, cited as [@{key}]', {'key': stored.id});
  }

  Future<String> _flashcardsOf(String noteId, int count) async {
    final text = await _notes.text.noteText(noteId, limit: _ai!.contextChars);
    if (text.trim().length < 80) return tr('Too little text to make flashcards from');
    final answer = await _ai.flashcards(text, count);
    final cards = parseFlashcards(answer);
    if (cards.isEmpty) return tr('The model did not make any flashcards');
    final before = {for (final c in await _cards!.due(now: DateTime(9999), source: noteId)) c.id};
    final added = await _cards.addAll(noteId, cards.length > count ? cards.sublist(0, count) : cards, now: _now());
    final fresh = [for (final c in await _cards.due(now: DateTime(9999), source: noteId)) if (!before.contains(c.id)) c.id];
    if (fresh.isNotEmpty) _willUndo('cards', {'ids': fresh});
    return added == 0 ? tr('The cards of this note are kept already') : trCount(added, 'Kept 1 new flashcard', 'Kept {n} new flashcards');
  }

  /// One task a day, while flashcards are due: "Review 12 flashcards".
  Future<String> _cardsDueTask(Automation a) async {
    final cards = _cards;
    if (cards == null) return tr('Flashcards are not available here');
    final now = _now();
    final n = await cards.dueCount(now: now);
    if (n == 0) return tr('No flashcards are due');
    final day = '${now.year}-${now.month}-${now.day}';
    if (!_fired.add('${a.id}|cards|$day')) return tr('Today\'s task for the flashcards is there already');
    await _notes.settings.set(_firedKey, jsonEncode(_fired.toList()));
    final text = (a.params['title'] ?? 'Review {n} flashcards').replaceAll('{n}', '$n').trim();
    await _tasks.createTask(text, dueDate: DateTime(now.year, now.month, now.day), auto: true);
    return tr('Added the task "{text}"', {'text': text});
  }

  /// The words of note [noteId] without its title, at most [limit] characters; null when there are too few to do anything with.
  Future<String?> _bodyOf(String noteId, int limit) async {
    final info = await _notes.noteInfo(noteId);
    var text = await _notes.text.noteText(noteId, limit: limit + (info?.title.length ?? 0));
    if (info != null && text.startsWith(info.title)) text = text.substring(info.title.length);
    text = text.trim();
    return text.length < 40 ? null : text;
  }

  /// Puts a text box with [text] under the rest of the last page of note [noteId]. A box with the same [id] is replaced (a summary
  /// that is made again), and so is any box of the page whose id starts with [replacePrefix]. The note is written to the database
  /// directly, which an editor that has it open would write over: so this waits (a few seconds) for the editor to let go.
  Future<String> _writeBox(String noteId, String id, String text, {String? replacePrefix}) async {
    const step = Duration(milliseconds: 50);
    for (var waited = Duration.zero; waited < editorWait && openEditor?.call(noteId) != null; waited += step) {
      await Future<void>.delayed(step);
    }
    if (openEditor?.call(noteId) != null) return tr('The note stayed open, so nothing was written into it');
    final note = await _notes.loadNote(noteId);
    if (note == null) return tr('The note is gone');
    final page = NoteHeld.of(note).pages - 1;
    var bottom = note.pdfPath == null ? 0.0 : 24.0;
    for (final b in note.textBoxes[page] ?? const <TextBoxWidgetModel>[]) {
      if (b.id == id || (replacePrefix != null && b.id.startsWith(replacePrefix))) continue;
      final h = b.size.height > 0 ? b.size.height : 24.0;
      if (b.position.dy + h > bottom) bottom = b.position.dy + h;
    }
    for (final s in note.strokes[page] ?? const <DrawingStroke>[]) {
      for (final p in s.points) {
        if (p.dy > bottom) bottom = p.dy;
      }
    }
    final box = TextBoxWidgetModel(
      id: id,
      position: Offset(40, bottom + 16 > 1050 ? 1050 : bottom + 16),
      size: const Size(720, 0),
      initialText: text,
      fontSize: 14,
      style: const TextBoxStyle(background: Color(0xFFE3F2FD), opacity: 0.9, borderWidth: 0, radius: 6),
      author: Authorship.current,
    );
    await _notes.putTextBox(noteId, page, box, replacePrefix: replacePrefix ?? id);
    _willUndo('box', {'noteId': noteId, 'page': page, 'id': id});
    return tr('Added a text box to page {n}', {'n': page + 1});
  }

  /// The note called [title] (made, in [folderId], if there is none yet).
  Future<String> _dailyNote(String title, String? folderId) async {
    final existing = (await _notes.listNotes()).where((n) => n.title == title && n.lockMode == 0).firstOrNull;
    if (existing != null) return existing.id;
    final made = await _notes.createNote(title: title, folderId: folderId == null || folderId.isEmpty ? null : folderId);
    _willUndo('note', {'noteId': made});
    return made;
  }

  int _boxes = 0;

  Future<String> _appendText(Automation a, String? noteId, String text, String title, Map<String, Object?> data) async {
    final daily = a.params['where'] == 'daily';
    final target = daily
        ? await _dailyNote(
            fillTemplate(a.params['title'] ?? 'Daily {date}', title: title, now: _now(), vars: _varsOf(data)).trim(), a.params['folder'])
        : noteId;
    if (target == null) return tr('No note to add to');
    return _writeBox(target, 'auto-add-${_now().microsecondsSinceEpoch}-${_boxes++}', text);
  }

  Future<String> _summarize(String noteId) async {
    final text = await _bodyOf(noteId, _ai!.contextChars);
    if (text == null) return tr('Too little text to summarize');
    final summary = (await _ai.summarize(text)).trim();
    if (summary.isEmpty) return tr('The model wrote no summary');
    return _writeBox(noteId, 'auto-summary', '**${tr('Summary')}**\n$summary');
  }

  Future<String> _outline(String noteId) async {
    final text = await _bodyOf(noteId, _ai!.contextChars);
    if (text == null) return tr('Too little text to outline');
    final outline = (await _ai.generate(
      AiPrompt(
        system: 'You make the outline of notes for a student. Write the main topics as short headings and the points under each as short '
            'bullets, in the order of the notes. Use only what is in the notes. Answer with the outline only: lines that start with "- " for '
            'topics and "  - " for points. No introduction, no closing remarks. Write in the language of the notes.',
        user: text,
      ),
      maxTokens: 500,
    ))
        .trim();
    if (outline.isEmpty) return tr('The model wrote no outline');
    return _writeBox(noteId, 'auto-outline', '**${tr('Outline')}**\n$outline');
  }

  Future<String> _translate(String noteId, String code) async {
    final language = translationTargets[code];
    if (language == null) return tr('That language is not known');
    final text = await _bodyOf(noteId, 6000);
    if (text == null) return tr('Too little text to translate');
    final translator = NoteTranslator((prompt, {cancel}) => _ai!.generate(prompt, cancel: cancel, maxTokens: (prompt.user.length ~/ 2).clamp(200, 2400)));
    final translated = (await translator.translate(text, language)).trim();
    if (translated.isEmpty) return tr('The model wrote no translation');
    return _writeBox(noteId, 'auto-translation-$code', '**$language**\n$translated');
  }

  Future<String> _fromTemplate(Automation a, String title, Map<String, Object?> data) async {
    final svc = _templates;
    if (svc == null) return tr('Templates are not available here');
    final choice = a.params['template'] ?? '';
    final folder = (a.params['folder'] ?? '').isEmpty ? null : a.params['folder'];
    String? id;
    if (choice.startsWith('saved:')) {
      id = await svc.createFromSaved(choice.substring(6), folderId: folder);
    } else {
      final built = svc.builtIn.where((t) => t.id == choice).firstOrNull;
      if (built != null) id = await svc.createFrom(built, folderId: folder);
    }
    if (id == null) return tr('The template is not there any more');
    _willUndo('note', {'noteId': id});
    final name = fillTemplate(a.params['title'] ?? '{title}', title: title, now: _now(), vars: _varsOf(data)).trim();
    if (name.isNotEmpty) await _notes.renameNote(id, name);
    return tr('Made the note "{title}"', {'title': name.isEmpty ? tr('Untitled') : name});
  }

  Future<String> _remind(Automation a, String? noteId, String title, Map<String, Object?> data) async {
    final svc = _reminders;
    if (svc == null) return tr('Reminders are not available here');
    final now = _now();
    final at = switch (a.params['when']) {
      'inAnHour' => now.add(const Duration(hours: 1)),
      'thisEvening' => () {
          final evening = DateTime(now.year, now.month, now.day, 18);
          return evening.isAfter(now) ? evening : DateTime(now.year, now.month, now.day + 1, 18);
        }(),
      'inAWeek' => DateTime(now.year, now.month, now.day + 7, 9),
      _ => DateTime(now.year, now.month, now.day + 1, 9),
    };
    final text = fillTemplate(a.params['text'] ?? '{title}', title: title, now: now, vars: _varsOf(data)).trim();
    await svc.ensurePermission();
    final made = await svc.reminders.add(kind: noteId == null ? ReminderKind.custom : ReminderKind.note, refId: noteId, title: text.isEmpty ? tr('Reminder') : text, at: at);
    _willUndo('reminder', {'id': made});
    return tr('Reminder set for {when}', {'when': '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'});
  }

  Future<void> _fileQueue = Future.value();

  /// Settles when the files started so far are written.
  Future<void> get filesDone => _fileQueue;

  Future<void> _saveFileInBackground(Automation a, String noteId, String title, String dir, AutomationEvent? event) async {
    String result;
    try {
      final path = await _noteFiles!.exportInto(noteId, dir);
      result = path == null ? tr('The note is gone') : tr('Saved as {path}', {'path': path});
    } catch (e) {
      result = tr('Could not save the file: {error}', {'error': e});
    }
    if (event != null && _onlyWhenChanged(event)) await _remember(a.id, noteId, event);
    _record(a, result, noteId: noteId, title: title);
    final i = _all.indexWhere((x) => x.id == a.id);
    if (i >= 0) {
      _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: result);
      notifyListeners();
      await _save();
    }
  }

  Future<void> _sortQueue = Future.value();

  /// Settles when the sorting started so far is done.
  Future<void> get sortingDone => _sortQueue;

  Future<void> _sortInBackground(Automation a, String noteId, String title, String pdfText, AutomationEvent? event) async {
    final from = (await _notes.noteInfo(noteId))?.folderId;
    String result;
    try {
      result = await _sorter!.sort(
        noteId,
        within: a.params['within'],
        unfiledOnly: a.params['unfiledOnly'] != '0',
        strictness: SortStrictness.values.where((s) => s.name == a.params['strictness']).firstOrNull ?? SortStrictness.normal,
        pdfText: pdfText,
      );
    } catch (e) {
      result = tr('Could not sort the note: {error}', {'error': e});
    }
    if (event != null && _onlyWhenChanged(event)) await _remember(a.id, noteId, event);
    final to = (await _notes.noteInfo(noteId))?.folderId;
    _record(a, result, noteId: noteId, title: title, steps: to == from ? const [] : [UndoStep('move', {'noteId': noteId, 'from': from})]);
    final i = _all.indexWhere((x) => x.id == a.id);
    if (i >= 0) {
      _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: '"$title": $result');
      notifyListeners();
      await _save();
    }
  }

  static const _meetingsKey = 'automations_meetings';

  /// The note made for each meeting (`uid|start`), so that what is done when the meeting is over reaches it.
  Map<String, String>? _meetings;

  Future<Map<String, String>> _meetingNotes() async {
    if (_meetings != null) return _meetings!;
    try {
      return _meetings = {for (final e in (jsonDecode(await _notes.settings.get(_meetingsKey) ?? '{}') as Map).entries) '${e.key}': '${e.value}'};
    } catch (_) {
      return _meetings = {};
    }
  }

  Future<String> _meetingNote(Automation a, String title, Map<String, Object?> data) async {
    final vars = _varsOf(data);
    final name = fillTemplate(a.params['title'] ?? '{title} {day}', title: title, now: _now(), vars: vars).trim();
    final folder = (a.params['folder'] ?? '').isEmpty ? null : a.params['folder'];
    final choice = a.params['template'] ?? '';
    String? id;
    if (choice.isNotEmpty) {
      final svc = _templates;
      if (svc == null) return tr('Templates are not available here');
      final built = svc.builtIn.where((t) => t.id == choice).firstOrNull;
      id = choice.startsWith('saved:') ? await svc.createFromSaved(choice.substring(6), folderId: folder) : built == null ? null : await svc.createFrom(built, folderId: folder);
      if (id == null) return tr('The template is not there any more');
      await _notes.renameNote(id, name.isEmpty ? title : name);
    } else {
      id = await _notes.createNote(title: name.isEmpty ? title : name, folderId: folder);
    }
    _willUndo('note', {'noteId': id});
    var open = <String>[];
    String? previousTitle;
    if (a.params['carry'] != 'no') {
      final previous = previousMeetingNote(await _notes.listNotes(), title, exceptId: id);
      if (previous != null) {
        previousTitle = previous.title;
        final lines = (await _notes.text.noteText(previous.id, limit: 30000)).split('\n');
        open = [for (final item in findTodos(lines, _now())) todoText(item.line) ?? item.summary];
      }
    }
    final text = meetingNoteText(title: title, day: vars['day'] ?? '', start: vars['start'] ?? '', previous: previousTitle, open: open);
    await _writeBox(id, 'auto-meeting', text);
    final key = data['meeting'];
    if (key is String) {
      final all = await _meetingNotes();
      all.remove(key);
      all[key] = id; // (the newest last)
      while (all.length > 200) {
        all.remove(all.keys.first);
      }
      await _notes.settings.set(_meetingsKey, jsonEncode(all));
    }
    return open.isEmpty ? tr('Made the note "{title}"', {'title': name}) : trCount(open.length, 'Made the note "{title}" with 1 open line from last time', 'Made the note "{title}" with {n} open lines from last time').replaceAll('{title}', name);
  }

  List<UpcomingEvent> _soon = const [];
  DateTime? _soonFetched;

  /// Runs the "calendar event about to start" automations for the events that start within their lead time (`minutes`, 10 by default),
  /// once for each event. The calendars are asked for the next day at most every ten minutes. Returns how many events were acted on.
  Future<int> checkEventsStarting() async {
    final rules = _all.where((a) => a.enabled && a.event == AutomationEvent.calendarEventStarting).toList();
    final ended = _all.where((a) => a.enabled && a.event == AutomationEvent.calendarEventEnded).toList();
    final source = _upcoming;
    if ((rules.isEmpty && ended.isEmpty) || source == null) return 0;
    final now = _now();
    if (_soonFetched == null || now.difference(_soonFetched!) >= const Duration(minutes: 10) || now.isBefore(_soonFetched!)) {
      try {
        _soon = await source(now.subtract(const Duration(hours: 3)), now.add(const Duration(days: 1)));
        _soonFetched = now;
      } catch (_) {
        return 0; // the calendars cannot be read now: the next minute tries again
      }
    }
    var acted = 0, changed = false;
    for (final a in rules) {
      final lead = Duration(minutes: (int.tryParse(a.params['minutes'] ?? '') ?? 10).clamp(1, 720));
      for (final e in _soon) {
        if (e.allDay || !e.start.isAfter(now.subtract(const Duration(minutes: 1))) || e.start.isAfter(now.add(lead))) continue;
        if (!_fired.add('${a.id}|event|${e.uid}|${e.start.millisecondsSinceEpoch}')) continue;
        changed = true;
        String two(int n) => n.toString().padLeft(2, '0');
        final (result, steps, later) = await _recorded(() => _performRule(a,
            title: e.title,
            event: AutomationEvent.calendarEventStarting,
            data: {
              ...eventVars({
                'start': '${two(e.start.hour)}:${two(e.start.minute)}',
                'day': '${e.start.year}-${two(e.start.month)}-${two(e.start.day)}',
              }),
              'meeting': '${e.uid}|${e.start.millisecondsSinceEpoch}',
            }));
        if (!later) _record(a, result, title: e.title, steps: steps);
        acted++;
        final i = _all.indexWhere((x) => x.id == a.id);
        if (i >= 0) _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: '"${e.title}": $result');
      }
    }
    for (final a in ended) {
      for (final e in _soon) {
        final end = e.end;
        if (e.allDay || end == null || end.isAfter(now) || now.difference(end) > const Duration(minutes: 30)) continue;
        if (!nameMatches(a.contains, [e.title])) continue;
        final key = '${e.uid}|${e.start.millisecondsSinceEpoch}';
        final noteId = (await _meetingNotes())[key];
        if (noteId == null) continue; // no note was made for this meeting
        final info = await _notes.noteInfo(noteId);
        if (info == null || (a.folderId != null && a.folderId != info.folderId)) continue;
        if (!_fired.add('${a.id}|ended|$key')) continue;
        changed = true;
        String two(int n) => n.toString().padLeft(2, '0');
        final (result, steps, later) = await _recorded(() => _performRule(a,
            noteId: noteId,
            title: e.title,
            event: AutomationEvent.calendarEventEnded,
            data: eventVars({
              'start': '${two(e.start.hour)}:${two(e.start.minute)}',
              'day': '${e.start.year}-${two(e.start.month)}-${two(e.start.day)}',
            })));
        if (!later) _record(a, result, noteId: noteId, title: e.title, steps: steps);
        acted++;
        final i = _all.indexWhere((x) => x.id == a.id);
        if (i >= 0) _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: '"${e.title}": $result');
      }
    }
    if (acted > 0) {
      notifyListeners();
      await _save();
    }
    if (changed) await _notes.settings.set(_firedKey, jsonEncode(_fired.toList()));
    return acted;
  }

  /// Runs the "not opened for a while" automations on the notes that are due,
  /// once for each time a note went stale. Returns how many notes were acted on.
  Future<int> checkStale() async {
    var total = 0;
    var changed = false;
    for (final a in _all.where((a) => a.enabled && a.event == AutomationEvent.noteStale).toList()) {
      final weeks = (int.tryParse(a.params['weeks'] ?? '') ?? 4).clamp(1, 520);
      final notes = await _notes.staleNotes(_now().subtract(Duration(days: 7 * weeks)));
      var acted = 0;
      String? last;
      for (final n in notes) {
        if (a.folderId != null && a.folderId != n.folderId) continue;
        if (!nameMatches(a.contains, [n.title, n.pdfName])) continue;
        // a note that was opened since is new again; one that stays untouched is acted on once
        if (!_fired.add('${a.id}|${n.id}|stale|${n.lastOpened.millisecondsSinceEpoch}')) continue;
        changed = true;
        final (said, steps, later) = await _recorded(() => _performRule(a, noteId: n.id, title: n.title, event: AutomationEvent.noteStale));
        last = said;
        if (!later) _record(a, said, noteId: n.id, title: n.title, steps: steps);
        acted++;
      }
      total += acted;
      final i = _all.indexWhere((x) => x.id == a.id);
      if (i >= 0) {
        _all[i] = _all[i].copyWith(
          lastRun: _now(),
          lastResult: acted == 0
              ? tr('Checked: no new note has been unopened for {weeks}', {'weeks': trCount(weeks, '{n} week', '{n} weeks')})
              : tr('{notes} unopened for {weeks}; last: {last}', {
                  'notes': trCount(acted, '{n} note', '{n} notes'),
                  'weeks': trCount(weeks, '{n} week', '{n} weeks'),
                  'last': last,
                }),
        );
      }
    }
    notifyListeners();
    await _save();
    if (changed) await _notes.settings.set(_firedKey, jsonEncode(_fired.toList()));
    return total;
  }

  /// Runs the enabled automations for [event] one after the other and notes
  /// how each went. Returns what happened, one line per automation.
  Future<List<String>> run(
    AutomationEvent event, {
    String? noteId,
    String title = '',
    String? folderId,
    NoteEditorHandle? editor,
    FoundDate? found,
    TodoItem? todo,
    Map<String, Object?> data = const {},
  }) async {
    final results = <String>[];
    var firedNew = false;
    ({String title, String? folderId, String? pdfName})? info;
    for (final a in _all.where((a) => a.enabled && a.event == event)) {
      if (a.folderId != null && a.folderId != folderId) continue; // not for this note
      if (event == AutomationEvent.triggerPressed && (a.params['trigger'] ?? '1') != '${data['trigger'] ?? 1}') continue; // another trigger
      if (a.contains != null && a.contains!.trim().isNotEmpty) {
        if (noteId != null) info ??= await _notes.noteInfo(noteId);
        if (!nameMatches(a.contains, [title, info?.title, info?.pdfName])) continue;
      }
      if (noteId != null && _onlyWhenChanged(event) && a.action != AutomationAction.prepareInk) {
        final edited = await _notes.noteEditedAt(noteId);
        if (edited != null && _seen[_seenKeyOf(a.id, noteId, event)] == edited.millisecondsSinceEpoch) continue; // unchanged since it ran
      }
      if (found != null) {
        final key = '${a.id}|$noteId|${found.key}';
        if (!_fired.add(key)) continue; // done for this date already
        firedNew = true;
      }
      if (todo != null) {
        final key = '${a.id}|$noteId|${todo.key}';
        if (!_fired.add(key)) continue; // done for this line already
        firedNew = true;
      }
      final (result, steps, later) = await _recorded(() => _performRule(a, noteId: noteId, title: title, editor: editor, found: found, todo: todo, event: event, data: data));
      if (!later) _record(a, result, noteId: noteId, title: title, steps: steps);
      if (noteId != null && _onlyWhenChanged(event) && a.action != AutomationAction.prepareInk) await _remember(a.id, noteId, event);
      results.add(result);
      final i = _all.indexWhere((x) => x.id == a.id);
      if (i >= 0) {
        _all[i] = _all[i].copyWith(lastRun: _now(), lastResult: result);
        notifyListeners();
      }
    }
    if (results.isNotEmpty) await _save();
    if (firedNew) await _notes.settings.set(_firedKey, jsonEncode(_fired.toList()));
    return results;
  }

  /// What the event says that texts can use as `{name}` (see [eventVars]).
  static Map<String, String> _varsOf(Map<String, Object?> data) {
    final v = data['vars'];
    return v is Map ? {for (final e in v.entries) '${e.key}': '${e.value}'} : const {};
  }

  Future<String> _perform(Automation a,
      {String? noteId, required String title, NoteEditorHandle? editor, FoundDate? found, TodoItem? todo, AutomationEvent? event, Map<String, Object?> data = const {}}) async {
    switch (a.action) {
      case AutomationAction.exportPdf:
        final dir = a.params['dir'];
        if (dir == null || dir.trim().isEmpty) return tr('No folder chosen for the PDF');
        if (editor == null) return tr('The note was not open');
        await editor.ready;
        await Directory(dir).create(recursive: true);
        final path = p.join(dir, '${safeFileName(title)}.pdf');
        final error = await editor.exportPdfTo(path);
        return error == null ? tr('Exported to {path}', {'path': path}) : tr('Could not export: {error}', {'error': error});
      case AutomationAction.addTask:
        // "improve the title": the language model rewrites the line, if it can
        String? smart;
        if (found != null && a.params['smart'] == '1' && _smartTitle != null) {
          // (a model that hangs or fails must not hold up the task)
          smart = await Future.sync(() => _smartTitle(found.summary.isEmpty ? found.line : found.summary))
              .then<String?>((v) => v) // (a plain Future<String> from a caller would not take a null)
              .timeout(const Duration(seconds: 90), onTimeout: () => null)
              .catchError((Object _) => null);
        }
        final text = fillTemplate(a.params['title'] ?? '{title}', title: title, now: _now(), found: found, summary: smart, todo: todo, vars: _varsOf(data)).trim();
        if (text.isEmpty) return tr('The task has no text');
        // a found date is the day of the task; its time stands in the text, as tasks have no time
        final due = found != null
            ? found.date
            : todo?.due ?? (TaskDue.values.where((d) => d.name == a.params['due']).firstOrNull ?? TaskDue.none).from(_now());
        _willUndo('task', {'id': await _tasks.createTask(text, dueDate: due, auto: true)});
        if (due == null) return tr('Added the task "{text}"', {'text': text});
        final day = '${due.year}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')}';
        return tr('Added the task "{text}" on {date}', {'text': text, 'date': day});
      case AutomationAction.convertHandwriting:
        if (noteId == null) return tr('No note to read');
        if (_readInk == null || !(_inkReady?.call() ?? false)) {
          return tr('The handwriting model is not installed (see Settings)');
        }
        // reading takes a while (a line takes seconds on a tablet): go on in the
        // background, one note at a time, and say how it went when it is done
        _deferred();
        _inkQueue = _inkQueue.then((_) => _convertInBackground(a.id, noteId, event)).catchError((Object _) {});
        return tr('Reading the handwriting in the background...');
      case AutomationAction.indexInk:
        if (_readInk == null || !(_inkReady?.call() ?? false)) {
          return tr('The handwriting model is not installed (see Settings)');
        }
        _inkQueue = _inkQueue.then((_) => _indexInBackground(a.id)).catchError((Object _) {});
        return tr('Reading the handwriting in the background...');
      case AutomationAction.prepareInk:
        if (editor is! InkPreparer) return tr('The note was not open');
        final what = a.params['what'];
        return (editor as InkPreparer).prepareInk(text: what != 'formulas', math: what != 'text');
      case AutomationAction.appendToNote:
        final text = fillTemplate(a.params['text'] ?? '{title}', title: title, now: _now(), found: found, todo: todo, vars: _varsOf(data)).trim();
        if (text.isEmpty) return tr('Nothing to add');
        if (a.params['where'] != 'daily' && noteId == null) return tr('No note to add to');
        return _background(a, noteId ?? '', event, () => _appendText(a, noteId, text, title, data), tr('Adding it in the background...'), title: title);
      case AutomationAction.addTag:
        final tag = fillTemplate(a.params['tag'] ?? '', title: title, now: _now(), found: found, todo: todo, vars: _varsOf(data)).trim().replaceAll(RegExp(r'\s+'), '-');
        if (noteId == null || tag.isEmpty) return tr('No note or tag');
        if (_tags == null) return tr('Tags are not available here');
        final had = (await _tags.tagsOf(noteId)).contains(tag);
        await _tags.add([noteId], tag);
        if (!had) _willUndo('tag', {'noteId': noteId, 'tag': tag});
        return tr('Tagged the note "{tag}"', {'tag': tag});
      case AutomationAction.starNote:
        if (noteId == null) return tr('No note to star');
        final starred = await _notes.isFavorite(noteId);
        await _notes.setFavorite(noteId, true);
        if (!starred) _willUndo('star', {'noteId': noteId});
        return tr('Starred the note');
      case AutomationAction.summarizeToBox:
        if (noteId == null) return tr('No note to summarize');
        if (!_assistantReady) return tr('The assistant is not ready (see Settings)');
        return _background(a, noteId, event, () => _summarize(noteId), tr('Writing the summary in the background...'), title: title);
      case AutomationAction.outlineToBox:
        if (noteId == null) return tr('No note to outline');
        if (!_assistantReady) return tr('The assistant is not ready (see Settings)');
        return _background(a, noteId, event, () => _outline(noteId), tr('Writing the outline in the background...'), title: title);
      case AutomationAction.translateToBox:
        if (noteId == null) return tr('No note to translate');
        if (!_assistantReady) return tr('The assistant is not ready (see Settings)');
        return _background(a, noteId, event, () => _translate(noteId, a.params['language'] ?? 'en'), tr('Translating in the background...'), title: title);
      case AutomationAction.createNoteFromTemplate:
        return _fromTemplate(a, title, data);
      case AutomationAction.meetingNote:
        return _meetingNote(a, title, data);
      case AutomationAction.setReminder:
        return _remind(a, noteId, title, data);
      case AutomationAction.exportImages:
        final dir = (a.params['dir'] ?? '').trim();
        if (dir.isEmpty) return tr('No folder chosen for the pictures');
        if (editor is! ImageExporter) return tr('The note was not open');
        final preset = ImagePreset.values.where((p) => p.name == a.params['preset']).firstOrNull ?? ImagePreset.screen;
        await Directory(dir).create(recursive: true);
        return (editor as ImageExporter).exportImagesInto(dir, preset);
      case AutomationAction.addCitation:
        return _citeCaptured(title, data);
      case AutomationAction.askAboutNote:
        if (noteId == null) return tr('No note to ask about');
        return _askAbout(noteId, event);
      case AutomationAction.titleNote:
        if (noteId == null) return tr('No note to name');
        // (the language model takes a while: in the background, and the editor, which may be gone by then, is looked up again)
        return _background(a, noteId, event, () => _titleOf(noteId, null), tr('Naming the note in the background...'), title: title);
      case AutomationAction.makeFlashcards:
        if (noteId == null) return tr('No note to make flashcards from');
        if (_cards == null) return tr('Flashcards are not available here');
        if (!_assistantReady) return tr('The assistant is not ready (see Settings)');
        final count = (int.tryParse(a.params['count'] ?? '') ?? 6).clamp(1, 30);
        return _background(a, noteId, event, () => _flashcardsOf(noteId, count), tr('Writing flashcards in the background...'), title: title);
      case AutomationAction.reviewCardsTask:
        return _cardsDueTask(a);
      case AutomationAction.extensionAction:
        final svc = _extensions;
        if (svc == null) return tr('Extensions are not available here');
        final parts = (a.params['extension'] ?? '').split('/');
        final ext = parts.length == 2 ? svc.byId(parts[0]) : null;
        final def = ext?.manifest.actions.where((x) => x.id == parts[1]).firstOrNull;
        if (ext == null || def == null) return tr('The extension action is not installed any more');
        if (!ext.enabled) return tr('The extension is switched off (see Settings)');
        return svc.runAction(ext, def, event: {'event': event?.name, 'note': {'id': noteId, 'title': title}, if (data.isNotEmpty) 'data': {...data}..remove('found')..remove('todo')}, api: _AutomationApi(svc, _notes, noteId, title));
      case AutomationAction.saveNoteFile:
        final dir = a.params['dir'];
        if (dir == null || dir.trim().isEmpty) return tr('No folder chosen for the file');
        if (noteId == null) return tr('No note to save');
        if (_noteFiles == null) return tr('Note files are not available here');
        // the editor has written the note by now (closing saves it first); packing a big note
        // takes a moment: in the background, like reading handwriting
        if (Zone.current[_inlineKey] == true) {
          final path = await _noteFiles.exportInto(noteId, dir.trim());
          return path == null ? tr('The note is gone') : tr('Saved as {path}', {'path': path});
        }
        _deferred();
        _fileQueue = _fileQueue.then((_) => _saveFileInBackground(a, noteId, title, dir.trim(), event)).then((_) {}, onError: (Object _) {});
        return tr('Saving the note as a file in the background...');
      case AutomationAction.sortIntoFolder:
        final sorter = _sorter;
        if (noteId == null) return tr('No note to file');
        if (sorter == null || !sorter.ready()) return tr('The sentence model is not installed (see Settings)');
        // reading the notes of the folders takes a while the first time: go on in the background
        final pdfText = editor == null ? '' : (await editor.pdfTextLines()).join('\n');
        if (Zone.current[_inlineKey] == true) {
          final from = (await _notes.noteInfo(noteId))?.folderId;
          final said = await sorter.sort(
            noteId,
            within: a.params['within'],
            unfiledOnly: a.params['unfiledOnly'] != '0',
            strictness: SortStrictness.values.where((s) => s.name == a.params['strictness']).firstOrNull ?? SortStrictness.normal,
            pdfText: pdfText,
          );
          if ((await _notes.noteInfo(noteId))?.folderId != from) _willUndo('move', {'noteId': noteId, 'from': from});
          return said;
        }
        _deferred();
        _sortQueue = _sortQueue.then((_) => _sortInBackground(a, noteId, title, pdfText, event)).catchError((Object _) {});
        return tr('Reading the note to find its folder in the background...');
      case AutomationAction.moveToFolder:
        final folder = a.params['folder'];
        if (noteId == null || folder == null) return tr('No note or folder to move to');
        _willUndo('move', {'noteId': noteId, 'from': (await _notes.noteInfo(noteId))?.folderId});
        await _notes.moveNote(noteId, folder);
        return tr('Moved the note to its folder');
    }
  }

  @override
  void dispose() {
    _unlisten?.call();
    super.dispose();
  }
}

/// A short fingerprint of some strokes (their colours and points), the same on
/// every run.
String inkFingerprint(List<DrawingStroke> strokes) {
  var h = 5381;
  void add(int v) => h = ((h * 33) ^ v) & 0x7fffffff;
  for (final s in strokes) {
    add(s.color.toARGB32());
    for (final p in s.points) {
      add((p.dx * 10).round());
      add((p.dy * 10).round());
    }
    add(-1);
  }
  return h.toRadixString(16);
}

/// What an extension can do in an automation: read the note the event is about, and add tasks.
class _AutomationApi extends SharedExtensionApi {
  final NoteRepository _notes;
  final String? _noteId;
  final String? _title;

  _AutomationApi(super.service, this._notes, this._noteId, this._title);

  @override
  Future<Map<String, Object?>> note() async {
    final id = _noteId;
    if (id == null) throw ExtensionError('There is no note here.');
    return {'id': id, 'title': _title ?? '', 'text': await _notes.text.noteText(id, limit: 20000)};
  }
}
