import '../ai/ai_prompt.dart';
import '../data/note_data.dart';
import 'automation.dart';

/// What the actions take besides the settings that [AutomationActionFields.fields] describes (the older ones have inputs of their own).
const _legacyParams = <AutomationAction, List<(String, String)>>{
  AutomationAction.exportPdf: [('dir', 'the folder on this device the PDF goes into')],
  AutomationAction.saveNoteFile: [('dir', 'the folder on this device the note file goes into')],
  AutomationAction.addTask: [('title', 'the task, with {title} for the note'), ('due', 'none, today, tomorrow or inAWeek')],
  AutomationAction.moveToFolder: [('folder', 'the name of the folder')],
  AutomationAction.makeFlashcards: [('count', 'about how many cards, a number')],
  AutomationAction.reviewCardsTask: [('title', 'the task, with {n} for how many cards are due')],
};

/// The parameters of [action] a rule may have: the key and what it is.
List<(String, String)> ruleParams(AutomationAction action) => [
      for (final f in action.fields) (f.key, f.kind == FieldKind.choice ? '${f.label}: one of ${f.choices.keys.join(', ')}' : f.label),
      ...?_legacyParams[action],
    ];

/// The actions that can be written in words: all but the ones of extensions, which the app cannot know the names of.
List<AutomationAction> get writableActions => [for (final a in AutomationAction.values) if (a != AutomationAction.extensionAction && a != AutomationAction.indexInk) a];

/// What the assistant is told to turn a request into a rule.
AiPrompt rulePrompt(String request) {
  final events = StringBuffer();
  for (final e in AutomationEvent.values) {
    events.writeln('- ${e.id}: ${e.label}${e.id == 'noteStale' ? ' [weeks=N]' : e.id == 'calendarEventStarting' ? ' [minutes=N]' : ''}'
        '${e.placeholders.isEmpty ? '' : ' (words: ${e.placeholders.map((p) => p.$1).join(' ')})'}');
  }
  final actions = StringBuffer();
  for (final a in writableActions) {
    final params = ruleParams(a);
    final after = [for (final e in AutomationEvent.values) if (a.worksAfter(e)) e.id];
    actions.writeln('- ${a.name}: ${a.label}${params.isEmpty ? '' : ' [${params.map((p) => '${p.$1}=<${p.$2}>').join(' ')}]'}'
        '${after.length == AutomationEvent.values.length ? '' : ' (only after: ${after.join(', ')})'}');
  }
  return AiPrompt(
    system: 'You turn a request into automation rules for a note-taking app. A rule is one line:\n'
        'event=<event> action=<action> [name=value ...]\n'
        'Put a value with spaces in quotes: tag="school/maths". Add in="<folder name>" to limit a rule to the notes of a folder and '
        'contains="<word>,<word>" to limit it to notes whose title has one of the words. Words in {braces} in a text stand for what the event '
        'says. Use only the events and actions below, only after the events an action allows, and only the names in [brackets].\n\n'
        'EVENTS:\n$events\nACTIONS:\n$actions\n'
        'Write the rule lines only, one for each rule, at most three, with no explanation. If the request cannot be done with these events '
        'and actions, write the single line: none',
    user: request.trim(),
    exact: true,
  );
}

/// A rule the assistant wrote, and what was wrong with it or left open.
class RuleDraft {
  final Automation rule;

  /// What is to be looked at before the rule is switched on (a folder that is not there, a setting that is left to choose).
  final List<String> notes;

  const RuleDraft(this.rule, this.notes);
}

/// What came of reading the assistant's answer: the rules that make sense, and the lines that did not.
class RuleDrafts {
  final List<RuleDraft> rules;
  final List<String> rejected;

  const RuleDrafts(this.rules, this.rejected);
}

final _pair = RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s"\x27]+))');

/// The rules in [answer]: lines of `event=... action=... name=value`. A line is left out (and told) when its event or its action is not
/// one there is, when the action cannot follow the event, or when a setting that must be given is not there and cannot be guessed. A
/// folder is named, not numbered: it is looked up in [folders]; one that is not there is told and left open. Every rule comes switched
/// off: it is for the person to look at.
RuleDrafts parseRules(String answer, {required List<FolderEntry> folders, required String Function() newId}) {
  final rules = <RuleDraft>[];
  final rejected = <String>[];
  String? folderId(String name) {
    final n = name.trim().toLowerCase();
    return folders.where((f) => f.name.toLowerCase() == n).firstOrNull?.id;
  }

  for (final raw in answer.split('\n')) {
    final line = raw.trim().replaceFirst(RegExp(r'^([-*•]|\d+[.)])\s*'), '').replaceAll('`', '');
    if (!line.contains('event=') || !line.contains('action=')) continue;
    final given = <String, String>{};
    for (final m in _pair.allMatches(line)) {
      given[m[1]!] = (m[2] ?? m[3] ?? m[4] ?? '').trim();
    }
    final event = AutomationEvent.values.where((e) => e.id == given['event']).firstOrNull;
    final action = writableActions.where((a) => a.name == given['action']).firstOrNull;
    if (event == null) {
      rejected.add('$line: there is no event "${given['event']}"');
      continue;
    }
    if (action == null) {
      rejected.add('$line: there is no action "${given['action']}"');
      continue;
    }
    if (!action.worksAfter(event)) {
      rejected.add('$line: "${action.label}" cannot follow "${event.label}"');
      continue;
    }
    final notes = <String>[];
    final params = <String, String>{};

    void keep(String key, String? value) {
      if (value != null && value.isNotEmpty) params[key] = value;
    }

    // the settings of the action: what was given if it fits, else what the dialog would start with
    for (final f in action.fields) {
      if (f.when != null && params[f.when!.$1] != f.when!.$2) continue; // (a setting of the other choice)
      final v = given[f.key];
      switch (f.kind) {
        case FieldKind.choice:
          if (v != null && f.choices.containsKey(v)) {
            params[f.key] = v;
          } else {
            if (v != null) notes.add('"$v" is not a choice of "${f.label}": ${f.initial.isEmpty ? f.choices.keys.first : f.initial} was used');
            params[f.key] = f.initial.isEmpty ? f.choices.keys.first : f.initial;
          }
        case FieldKind.folder:
          if (v != null && v.isNotEmpty) {
            final id = folderId(v);
            if (id == null) {
              notes.add('There is no folder "$v": choose one');
            } else {
              params[f.key] = id;
            }
          }
        case FieldKind.template:
          keep(f.key, v);
          if (f.required && (v == null || v.isEmpty)) notes.add('Choose the template');
        case FieldKind.directory:
          keep(f.key, v);
          if (f.required && (v == null || v.isEmpty)) notes.add('Choose the folder for the files');
        case FieldKind.text || FieldKind.multiline:
          if (v != null && v.isNotEmpty) {
            params[f.key] = v;
          } else if (f.initial.isNotEmpty) {
            params[f.key] = f.initial;
          } else if (f.required) {
            notes.add('"${f.label}" is empty: fill it in');
          }
      }
    }
    // the older actions
    switch (action) {
      case AutomationAction.exportPdf || AutomationAction.saveNoteFile:
        keep('dir', given['dir']);
        if (params['dir'] == null) notes.add('Choose the folder on this device');
      case AutomationAction.addTask:
        params['title'] = (given['title'] ?? '').isEmpty ? '{title}' : given['title']!;
        const dues = {'none', 'today', 'tomorrow', 'inAWeek'};
        params['due'] = dues.contains(given['due']) ? given['due']! : 'none';
      case AutomationAction.moveToFolder:
        final id = folderId(given['folder'] ?? '');
        if (id == null) {
          notes.add(given['folder'] == null ? 'Choose the folder to move to' : 'There is no folder "${given['folder']}": choose one');
        } else {
          params['folder'] = id;
        }
      case AutomationAction.makeFlashcards:
        final n = int.tryParse(given['count'] ?? '');
        if (n != null && n >= 1) params['count'] = '${n.clamp(1, 30)}';
      case AutomationAction.reviewCardsTask:
        params['title'] = (given['title'] ?? '').isEmpty ? 'Review {n} flashcards' : given['title']!;
      default:
        break;
    }
    if (event == AutomationEvent.noteStale) params['weeks'] = '${(int.tryParse(given['weeks'] ?? '') ?? 4).clamp(1, 520)}';
    if (event == AutomationEvent.calendarEventStarting) params['minutes'] = '${(int.tryParse(given['minutes'] ?? '') ?? 10).clamp(1, 720)}';

    String? scope;
    if (event.hasNote && (given['in'] ?? '').isNotEmpty) {
      scope = folderId(given['in']!);
      if (scope == null) notes.add('There is no folder "${given['in']}" to limit it to: it applies to every note');
    }
    final contains = event.hasNote && (given['contains'] ?? '').isNotEmpty ? given['contains'] : null;
    rules.add(RuleDraft(
      Automation(id: newId(), event: event, action: action, folderId: scope, contains: contains, params: params, enabled: false),
      notes,
    ));
    if (rules.length >= 3) break;
  }
  return RuleDrafts(rules, rejected);
}

/// A rule in a sentence: "When a note is closed, give the note a tag (school/maths), for notes in Physics".
String describeRule(Automation a, {String Function(String? folderId)? folderName}) {
  final b = StringBuffer('When ${_lower(a.event.label)}: ${_lower(a.action.label)}');
  final details = <String>[
    for (final f in a.action.fields)
      if ((a.params[f.key] ?? '').isNotEmpty && f.kind != FieldKind.template)
        f.kind == FieldKind.choice
            ? (f.choices[a.params[f.key]] ?? a.params[f.key]!)
            : f.kind == FieldKind.folder
                ? (folderName?.call(a.params[f.key]) ?? a.params[f.key]!)
                : a.params[f.key]!,
    if (a.action == AutomationAction.addTask) ?a.params['title'],
    if (a.action == AutomationAction.makeFlashcards) ?a.params['count'],
  ];
  if (details.isNotEmpty) b.write(' (${details.join('; ')})');
  if (a.event == AutomationEvent.noteStale) b.write(', after ${a.params['weeks'] ?? '4'} weeks');
  if (a.event == AutomationEvent.calendarEventStarting) b.write(', ${a.params['minutes'] ?? '10'} minutes before');
  if (a.folderId != null) b.write(', for notes in ${folderName?.call(a.folderId) ?? 'a folder'}');
  if ((a.contains ?? '').isNotEmpty) b.write(', when the name has: ${a.contains}');
  return b.toString();
}

String _lower(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
