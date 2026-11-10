import 'dart:convert';

import '../ai/translation.dart' show translationTargets;
import '../events/event_bus.dart';
import '../export/image_export.dart' show ImagePreset;
import 'date_finder.dart';
import 'todo_finder.dart';

/// Something that happens in the app that an automation can react to. Not an enum, so that an event
/// that only exists while an extension is installed can be kept in a rule; the built-in ones are the
/// constants below, and two events are equal when their [id]s are.
class AutomationEvent {
  static const appStarted = AutomationEvent('appStarted', 'The app starts', hasNote: false, hasEditor: false);
  static const noteCreated = AutomationEvent('noteCreated', 'A note is created', hasNote: true, hasEditor: false);
  static const noteOpened = AutomationEvent('noteOpened', 'A note is opened', hasNote: true, hasEditor: true);
  static const noteClosed = AutomationEvent('noteClosed', 'A note is closed (leaving the canvas)', hasNote: true, hasEditor: true);

  /// A date (and maybe a time) is found in the text of an imported PDF, once
  /// per date; the automation gets it as {found}, {time} and {line}.
  static const dateFound = AutomationEvent('dateFound', 'A date is found in a PDF', hasNote: true, hasEditor: false);

  /// A note has not been opened for a number of weeks (`weeks` in the params).
  /// Checked when the app starts and every few hours while it runs.
  static const noteStale = AutomationEvent('noteStale', 'A note has not been opened for a while', hasNote: true, hasEditor: false);

  /// A note or folder that someone shared with the person through the cloud service was taken in; the automation gets `name`, `kind`
  /// (`note` or `folder`) and `owner` as `ctx.data`.
  static const shareReceived = AutomationEvent('shareReceived', 'Something is shared with you and taken in', hasNote: false, hasEditor: false);

  /// A line that asks for something to be done ("to do: call the landlord by Friday", "☐ buy paper") is found in the words or the
  /// handwriting of a note when it is closed, once per line; the automation gets it as {summary}, {line} and {found} (the day it is due).
  static const todoFound = AutomationEvent('todoFound', 'A to-do line is found in a note', hasNote: true, hasEditor: false);

  /// A note was changed and then left alone for a while (half a minute): a good moment to name it or file it, even if it stays open.
  static const notePaused = AutomationEvent('notePaused', 'A note is left alone for a moment after changes', hasNote: true, hasEditor: false);

  /// A page of a note got something on it for the first time (or a PDF got pages). `{pages}` is how many pages the note has now.
  static const pageAdded = AutomationEvent('pageAdded', 'A page is added to a note', hasNote: true, hasEditor: false);

  /// A highlight was made in a PDF note.
  static const highlightAdded = AutomationEvent('highlightAdded', 'Something is highlighted in a note', hasNote: true, hasEditor: false);

  /// A link to another note was written into a note; `{target}` is the title of the note it links to.
  static const noteLinked = AutomationEvent('noteLinked', 'A note is linked to another note', hasNote: true, hasEditor: false);

  /// A PDF was imported as a note (also a PDF that was shared to the app or clipped); `{pdf}` is its file name.
  static const pdfImported = AutomationEvent('pdfImported', 'A PDF is imported', hasNote: true, hasEditor: false);

  /// A sound was recorded or dictated and kept with a note; `{audio}` is its title, `{minutes}` how long it is.
  static const audioRecorded = AutomationEvent('audioRecorded', 'A recording is kept with a note', hasNote: true, hasEditor: false);

  /// A task was ticked off in the app; `{title}` is the task, `{due}` the day it was due (nothing when it had none).
  static const taskCompleted = AutomationEvent('taskCompleted', 'A task is done', hasNote: false, hasEditor: false);

  /// A calendar event starts in a few minutes (`minutes` in the params, 10 by default); `{title}` is the event, `{start}` its time and
  /// `{day}` its day. All-day events are left out.
  static const calendarEventStarting = AutomationEvent('calendarEventStarting', 'A calendar event is about to start', hasNote: false, hasEditor: false);

  /// The calendar event a `meetingNote` rule made a note for is over (up to half an hour ago): the note is the one of the meeting, so that it
  /// can be summarized, filed or asked about; `{title}`, `{start}`, `{day}` as for `calendarEventStarting`.
  static const calendarEventEnded = AutomationEvent('calendarEventEnded', 'A meeting with a note of its own is over', hasNote: true, hasEditor: false);

  /// A note was made from something kept from outside: a web page or a selection of one, text or a file shared to the app, a quick note.
  /// It is complete when this is announced (it has its words, so it can be summarized, tagged or filed). `{kind}` is `note`, `clip`,
  /// `page`, `pdf` or `picture`; `{url}` the address it came from and `{site}` the name of the site, when there are any.
  static const captureReceived = AutomationEvent('captureReceived', 'Something is kept from the web or shared to the app', hasNote: true, hasEditor: false);

  /// The person pressed a trigger: a key they bound to "Run the automations of trigger 1/2/3" (Settings, shortcuts) or the side button of
  /// the pen when that is set to one. The rule says which trigger it is for (`trigger`, 1 by default). The note that is open is the note of
  /// the event (none when no note is open) and its editor is there. `{trigger}` is the number.
  static const triggerPressed = AutomationEvent('triggerPressed', 'You press a trigger (a shortcut or the pen button)', hasNote: true, hasEditor: true);

  /// The events the app itself announces.
  static const values = [
    appStarted,
    noteCreated,
    noteOpened,
    noteClosed,
    notePaused,
    pageAdded,
    highlightAdded,
    noteLinked,
    pdfImported,
    audioRecorded,
    taskCompleted,
    calendarEventStarting,
    calendarEventEnded,
    captureReceived,
    triggerPressed,
    dateFound,
    todoFound,
    noteStale,
    shareReceived,
  ];

  /// What the [EventType] announced on the bus is, as far as a rule is concerned.
  factory AutomationEvent.of(EventType t) =>
      values.where((e) => e.id == t.id).firstOrNull ?? AutomationEvent(t.id, t.label, hasNote: t.hasNote, hasEditor: t.hasEditor);

  /// An event this version knows nothing about (one of an extension that is not installed): its id
  /// is all there is, so the rule survives being saved and does nothing meanwhile.
  factory AutomationEvent.unknown(String id) => AutomationEvent(id, id, hasNote: false, hasEditor: false);

  final String id;
  final String label;

  /// There is a note to act on.
  final bool hasNote;

  /// That note is open in the editor while the automation runs, which is what
  /// exporting it needs.
  final bool hasEditor;

  const AutomationEvent(this.id, this.label, {required this.hasNote, required this.hasEditor});

  String get name => id;

  /// What a task or text of a rule for this event can use besides `{title}` and `{date}`: `{name}` and what it stands for.
  List<(String, String)> get placeholders => switch (id) {
        'pageAdded' => [('{pages}', 'how many pages the note has now')],
        'highlightAdded' => [('{n}', 'how many highlights were added')],
        'noteLinked' => [('{target}', 'the title of the note it links to')],
        'pdfImported' => [('{pdf}', 'the file name of the PDF')],
        'audioRecorded' => [('{audio}', 'the title of the recording'), ('{minutes}', 'how long it is, in minutes')],
        'taskCompleted' => [('{due}', 'the day the task was due')],
        'triggerPressed' => [('{trigger}', 'the number of the trigger')],
        'captureReceived' => [('{kind}', 'note, clip, page, pdf or picture'), ('{url}', 'the address it came from'), ('{site}', 'the name of the site')],
        'calendarEventEnded' => [('{start}', 'the time the meeting started'), ('{day}', 'the day of the meeting')],
        'calendarEventStarting' => [('{start}', 'the time it starts'), ('{day}', 'the day it starts')],
        'todoFound' => [('{summary}', 'what is to be done'), ('{line}', 'the whole line'), ('{found}', 'the day it is due')],
        'dateFound' => [('{summary}', 'the line without the date'), ('{line}', 'the whole line'), ('{time}', 'its time'), ('{found}', 'the date')],
        _ => const [],
      };

  @override
  bool operator ==(Object other) => other is AutomationEvent && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => id;
}

/// What an automation does.
enum AutomationAction {
  exportPdf('Export the note as a PDF'),
  addTask('Add a task to the calendar'),
  moveToFolder('Move the note to a folder'),
  sortIntoFolder('Move the note to the folder it fits best (by what it says)'),
  saveNoteFile('Save the note as a file (.uninote) into a folder'),
  convertHandwriting('Convert its handwriting to text'),
  prepareInk('Read the writing and formulas ahead of time, so converting them is instant'),
  indexInk('Read the handwriting of all notes, so that the search finds it'),
  appendToNote('Add text to a note (or to a daily note)'),
  addTag('Give the note a tag'),
  starNote('Star the note (it is listed as a favourite on the dashboard)'),
  translateToBox('Add a translation of the note as a text box (the assistant writes it)'),
  summarizeToBox('Add a summary of the note as a text box (the assistant writes it)'),
  outlineToBox('Add an outline of the note as a text box (the assistant writes it)'),
  createNoteFromTemplate('Make a new note from a template'),
  meetingNote('Prepare a note for the meeting (with what was left open last time)'),
  setReminder('Set a reminder'),
  exportImages('Save the pages of the note as pictures (PNG) into a folder'),
  addCitation('Add the web page it came from to the sources (citations)'),
  askAboutNote('Ask me what to do about the note (a card on the dashboard)'),
  titleNote('Give a note without a title one, from what it says'),
  makeFlashcards('Make flashcards from the note (the assistant writes them)'),
  reviewCardsTask('Add a task when flashcards are due for review'),
  extensionAction('Run an action of an extension');

  final String label;
  const AutomationAction(this.label);

  /// Whether this can be done after [event].
  bool worksAfter(AutomationEvent event) => switch (this) {
        AutomationAction.exportPdf => event.hasEditor,
        AutomationAction.addTask => true,
        AutomationAction.moveToFolder => event.hasNote,
        AutomationAction.saveNoteFile => event.hasNote,
        // it reads the note's words: not at its making, when there are none
        AutomationAction.sortIntoFolder => event == AutomationEvent.noteOpened ||
            event == AutomationEvent.noteClosed ||
            event == AutomationEvent.notePaused ||
            event == AutomationEvent.captureReceived ||
            event == AutomationEvent.noteStale ||
            event == AutomationEvent.dateFound,
        // what is added goes into a note that is not open at the time: the work waits for the editor to let go
        AutomationAction.appendToNote => true,
        AutomationAction.addTag || AutomationAction.starNote || AutomationAction.translateToBox || AutomationAction.summarizeToBox || AutomationAction.outlineToBox => event.hasNote,
        AutomationAction.createNoteFromTemplate || AutomationAction.setReminder => true,
        // it needs the event that is coming up
        AutomationAction.meetingNote => event == AutomationEvent.calendarEventStarting,
        // the pictures are made by the editor, which has to be there
        AutomationAction.exportImages => event.hasEditor,
        AutomationAction.askAboutNote => event.hasNote,
        // it needs the address the note came from
        AutomationAction.addCitation => event == AutomationEvent.captureReceived,
        // it needs words, and a note that is not named yet
        AutomationAction.titleNote => event == AutomationEvent.noteClosed || event == AutomationEvent.notePaused,
        // it needs the note's own pages, which are there when it is opened or closed
        AutomationAction.convertHandwriting => event == AutomationEvent.noteOpened || event == AutomationEvent.noteClosed,
        // it works with the note that is open, while it is open
        AutomationAction.prepareInk => event == AutomationEvent.noteOpened,
        // it goes through all the notes, not one
        AutomationAction.indexInk => event == AutomationEvent.appStarted,
        // it reads the note's words, which are there once it was written: when it is closed or has gone stale
        AutomationAction.makeFlashcards => event == AutomationEvent.noteClosed || event == AutomationEvent.noteStale,
        // it is about all the cards, not one note: once a day at most, when the app starts or a tick comes
        AutomationAction.reviewCardsTask => !event.hasNote,
        AutomationAction.extensionAction => true,
      };
}

/// What an input of an action's settings is, as the dialog shows it.
enum FieldKind { text, multiline, folder, template, choice, directory }

/// One setting of an action (the dialog makes the input from it; the value is kept in the rule's params under [key]).
class ActionField {
  final String key;
  final String label;
  final FieldKind kind;
  final String initial;

  /// A line under the input.
  final String? help;

  /// For [FieldKind.choice]: value -> what is shown.
  final Map<String, String> choices;

  /// Shown only while another field has a value: (that field's key, the value).
  final (String, String)? when;

  /// The rule cannot be saved while it is empty.
  final bool required;

  const ActionField(this.key, this.label, this.kind, {this.initial = '', this.help, this.choices = const {}, this.when, this.required = false});
}

extension AutomationActionFields on AutomationAction {
  /// The settings the dialog asks for, for the actions that are described by them (the older ones have inputs of their own).
  List<ActionField> get fields => switch (this) {
        AutomationAction.appendToNote => const [
            ActionField('where', 'Add it to', FieldKind.choice,
                initial: 'this', choices: {'this': 'The note the rule is about', 'daily': 'A daily note (made if it is not there)'}),
            ActionField('title', 'Title of the daily note', FieldKind.text, initial: 'Daily {date}', when: ('where', 'daily')),
            ActionField('folder', 'Folder for a new daily note', FieldKind.folder, when: ('where', 'daily')),
            ActionField('text', 'Text to add', FieldKind.multiline, required: true, initial: '- {title}', help: 'It goes in a box under the rest of the last page'),
          ],
        AutomationAction.addTag => const [ActionField('tag', 'Tag', FieldKind.text, required: true, initial: 'todo', help: 'A tag of the tag tree, e.g. school/maths; the words in braces of the event can be used: reading/{kind}')],
        AutomationAction.translateToBox => [
            ActionField('language', 'Translate into', FieldKind.choice, initial: 'en', choices: {for (final e in translationTargets.entries) e.key: e.value}),
          ],
        AutomationAction.createNoteFromTemplate => const [
            ActionField('template', 'Template', FieldKind.template, required: true),
            ActionField('title', 'Title of the note', FieldKind.text, initial: '{title}', help: '{title} is the title of the event; {date} today'),
            ActionField('folder', 'Folder', FieldKind.folder),
          ],
        AutomationAction.meetingNote => const [
            ActionField('template', 'Template (optional)', FieldKind.template),
            ActionField('title', 'Title of the note', FieldKind.text, initial: '{title} {day}', help: '{title} is the name of the event, {day} its day, {start} its time', required: true),
            ActionField('folder', 'Folder', FieldKind.folder),
            ActionField('carry', 'Bring along what is still open from the last meeting', FieldKind.choice,
                initial: 'yes', choices: {'yes': 'Yes: the to-do lines of the last note of that name', 'no': 'No'}),
          ],
        AutomationAction.setReminder => const [
            ActionField('when', 'Remind me', FieldKind.choice,
                initial: 'tomorrow', choices: {'inAnHour': 'In an hour', 'thisEvening': 'This evening (18:00)', 'tomorrow': 'Tomorrow morning (9:00)', 'inAWeek': 'In a week (9:00)'}),
            ActionField('text', 'Text', FieldKind.text, initial: '{title}'),
          ],
        AutomationAction.exportImages => [
            const ActionField('dir', 'Save the pictures in this folder', FieldKind.directory, required: true),
            ActionField('preset', 'Size', FieldKind.choice, initial: 'screen', choices: {for (final p in ImagePreset.values) p.name: p.label}),
          ],
        _ => const [],
      };
}

/// When a task from an automation is due.
enum TaskDue {
  none('No date'),
  today('Today'),
  tomorrow('Tomorrow'),
  inAWeek('In a week');

  final String label;
  const TaskDue(this.label);

  DateTime? from(DateTime now) => switch (this) {
        TaskDue.none => null,
        TaskDue.today => DateTime(now.year, now.month, now.day),
        TaskDue.tomorrow => DateTime(now.year, now.month, now.day + 1),
        TaskDue.inAWeek => DateTime(now.year, now.month, now.day + 7),
      };
}

/// A later step of a rule: what is done after the action before it, in the background, with that action's words available as `{result}`.
class ChainStep {
  final AutomationAction action;
  final Map<String, String> params;

  const ChainStep(this.action, [this.params = const {}]);

  Map<String, Object?> toJson() => {'action': action.name, 'params': params};

  static ChainStep? fromJson(Object? j) {
    if (j is! Map) return null;
    final action = AutomationAction.values.where((a) => a.name == j['action']).firstOrNull;
    if (action == null) return null;
    return ChainStep(action, {for (final e in ((j['params'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'});
  }
}

/// The actions that can follow another in a chain: the ones that work on the database and the assistant. What needs the open editor
/// (a PDF, pictures, reading the ink) cannot, nor can an action of an extension: a chain runs in the background, after the note was left.
bool chainable(AutomationAction a) => switch (a) {
      AutomationAction.exportPdf ||
      AutomationAction.exportImages ||
      AutomationAction.prepareInk ||
      AutomationAction.indexInk ||
      AutomationAction.convertHandwriting ||
      AutomationAction.extensionAction ||
      AutomationAction.reviewCardsTask =>
        false,
      _ => true,
    };

/// One rule: [action] whenever [event] happens (for notes in [folderId], or any
/// note when that is null). The [params] depend on the action:
///  - exportPdf: `dir`, the folder the PDF goes to;
///  - addTask: `title` (with `{title}` for the note's title and `{date}`) and `due` (a [TaskDue] name);
///  - moveToFolder: `folder`, the target folder's id;
///  - saveNoteFile: `dir`, the folder the file goes into (named by the note's title; an earlier file of
///    the note under another title is replaced);
///  - sortIntoFolder: `within` (only file into the subfolders of this folder; none = any folder),
///    `unfiledOnly` (`1`: leave notes that are in a folder alone) and `strictness` (a [SortStrictness] name);
///  - convertHandwriting: nothing;
///  - extensionAction: `extension`, `<extension id>/<action id>`: what to run;
///  - indexInk: nothing; reads the handwriting of every note in the background and keeps the text for the search;
///  - prepareInk: `what`, `both`, `text` or `formulas`: what to read ahead of time while the note is open;
///  - appendToNote: `where` (`this` or `daily`), `title` (the daily note's title, `Daily {date}`; made if there is none), `folder` (for
///    a new daily note) and `text` (what is added, a text box under the rest);
///  - addTag: `tag`;
///  - starNote: nothing;
///  - translateToBox: `language`, a code of `translationTargets`; the translation is a text box that a later run replaces;
///  - summarizeToBox: nothing; the summary is a text box that a later run replaces;
///  - outlineToBox: nothing; the outline (headings and points) is a text box that a later run replaces;
///  - createNoteFromTemplate: `template` (the id of one of the app's, or `saved:<id>`), `title` and `folder`;
///  - meetingNote: `template` (optional, as for createNoteFromTemplate), `title` (default `{title} {day}`), `folder`, `carry` (`yes`: the lines still
///    to do from the note of the last meeting with that name are put in the new one); the note is remembered for the meeting, so that
///    `calendarEventEnded` rules can work on it;
///  - setReminder: `when` (`inAnHour`, `thisEvening`, `tomorrow`, `inAWeek`) and `text`;
///  - exportImages: `dir`, the folder the pictures go into, and `preset`, an [ImagePreset] name;
///  - addCitation: nothing; the page the note was made from (its address, title and site, the day it was kept) becomes a source of the
///    library, cited as `[@key]` (one that is in the library already is not added again);
///  - askAboutNote: nothing; the note is put on the dashboard with the question what to do about it (keep it, archive it, be reminded, make
///    flashcards of it, not now);
///  - titleNote: nothing; a note whose title is empty or "Untitled Note" is named after what it says (the language model writes the
///    title when it is installed, else the first line is used if it is short enough);
///  - makeFlashcards: `count`, about how many cards to make from the note (default 6); they are kept for review with the note as their
///    source, a question that exists is not added twice;
///  - reviewCardsTask: `title` (`{n}` is how many cards are due; default "Review {n} flashcards"): one task a day while cards are due.
/// [contains] limits it to notes whose title or PDF name contains one of its
/// words (separated by commas); the event noteStale takes `weeks`.
/// After noteOpened and noteClosed an automation runs only for a note that was
/// edited since it last ran for that note.
class Automation {
  final String id;
  final AutomationEvent event;
  final AutomationAction action;
  final String? folderId;
  final String? contains;
  final Map<String, String> params;

  /// What is done after [action], one step after the other, in the background; each can use `{result}`, what the step before said. A
  /// step that says it could not do its work ends the chain.
  final List<ChainStep> then;
  final bool enabled;
  final DateTime? lastRun;
  final String? lastResult;

  const Automation({
    required this.id,
    required this.event,
    required this.action,
    this.folderId,
    this.contains,
    this.params = const {},
    this.then = const [],
    this.enabled = true,
    this.lastRun,
    this.lastResult,
  });

  Automation copyWith({
    AutomationEvent? event,
    AutomationAction? action,
    String? folderId,
    bool clearFolder = false,
    String? contains,
    bool clearContains = false,
    Map<String, String>? params,
    List<ChainStep>? then,
    bool? enabled,
    DateTime? lastRun,
    String? lastResult,
  }) =>
      Automation(
        id: id,
        event: event ?? this.event,
        action: action ?? this.action,
        folderId: clearFolder ? null : folderId ?? this.folderId,
        contains: clearContains ? null : contains ?? this.contains,
        params: params ?? this.params,
        then: then ?? this.then,
        enabled: enabled ?? this.enabled,
        lastRun: lastRun ?? this.lastRun,
        lastResult: lastResult ?? this.lastResult,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'event': event.name,
        'action': action.name,
        'folderId': folderId,
        'contains': contains,
        'params': params,
        if (then.isNotEmpty) 'then': [for (final t in then) t.toJson()],
        'enabled': enabled,
        'lastRun': lastRun?.millisecondsSinceEpoch,
        'lastResult': lastResult,
      };

  /// Null for an entry this version cannot read (an action it does not know).
  static Automation? fromJson(Map<String, Object?> json) {
    final eventId = json['event'];
    final action = AutomationAction.values.where((a) => a.name == json['action']).firstOrNull;
    final id = json['id'];
    if (eventId is! String || action == null || id is! String) return null;
    final event = AutomationEvent.values.where((e) => e.id == eventId).firstOrNull ?? AutomationEvent.unknown(eventId);
    final lastRun = json['lastRun'];
    return Automation(
      id: id,
      event: event,
      action: action,
      folderId: json['folderId'] as String?,
      contains: json['contains'] as String?,
      params: {for (final e in ((json['params'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
      then: [for (final t in (json['then'] as List?) ?? const []) ?ChainStep.fromJson(t)],
      enabled: json['enabled'] != false,
      lastRun: lastRun is int ? DateTime.fromMillisecondsSinceEpoch(lastRun) : null,
      lastResult: json['lastResult'] as String?,
    );
  }

  static String encodeAll(List<Automation> all) => jsonEncode([for (final a in all) a.toJson()]);

  static List<Automation> decodeAll(String? source) {
    if (source == null || source.isEmpty) return [];
    try {
      return [
        for (final j in jsonDecode(source) as List)
          ?Automation.fromJson((j as Map).cast<String, Object?>()),
      ];
    } catch (_) {
      return [];
    }
  }
}

/// Replaces `{title}` and `{date}` (today) in [template]; for a date found in
/// a PDF also `{found}` (that date), `{time}`, `{line}` (the whole line it
/// stands in) and `{summary}` (that line without the date and time; the note's
/// title when nothing else is left). For a to-do line `{summary}` is what is to be done, `{line}` the line and `{found}` the day it is
/// due (nothing when it says none).
String fillTemplate(String template,
    {required String title, required DateTime now, FoundDate? found, String? summary, TodoItem? todo, Map<String, String> vars = const {}}) {
  for (final e in vars.entries) {
    template = template.replaceAll('{${e.key}}', e.value);
  }
  final date = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  if (todo != null) {
    // a to-do line has a day only when it says one, and always has a summary and a line
    final due = todo.due == null ? null : FoundDate(todo.due!, null, todo.line, todo.summary);
    return template
        .replaceAll('{title}', title)
        .replaceAll('{date}', date)
        .replaceAll('{found}', due?.day ?? '')
        .replaceAll('{time}', '')
        .replaceAll('{line}', todo.line)
        .replaceAll('{summary}', todo.summary)
        .replaceAll(RegExp(r'\s{2,}'), ' ');
  }
  return template
      .replaceAll('{title}', title)
      .replaceAll('{date}', date)
      .replaceAll('{found}', found?.day ?? '')
      .replaceAll('{time}', found?.time ?? '')
      .replaceAll('{line}', found?.line ?? '')
      .replaceAll('{summary}', found == null ? '' : (summary ?? (found.summary.isEmpty ? title : found.summary)))
      .replaceAll(RegExp(r'\s{2,}'), ' ');
}

/// A file name for [title]: no characters a file system refuses.
String safeFileName(String title, {String fallback = 'Note'}) {
  final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim().replaceAll(RegExp(r'^\.+'), '');
  return cleaned.isEmpty ? fallback : (cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned);
}

/// Whether a note called [names] (its title, its PDF's file name) fits [contains]:
/// any of the comma-separated words appears in one of them, in any case. Nothing
/// to match against means every note fits.
bool nameMatches(String? contains, Iterable<String?> names) {
  final words = (contains ?? '').split(RegExp(r'[,;\n]')).map((w) => w.trim().toLowerCase()).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return true;
  final haystack = [for (final n in names) if (n != null) n.toLowerCase()];
  return words.any((w) => haystack.any((h) => h.contains(w)));
}
