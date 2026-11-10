import '../ai/ai_service.dart';
import '../extensions/extension_service.dart';
import 'magic_extension_dialog.dart';
import 'automation_log.dart';
import 'rule_writer_dialog.dart';
import 'package:file_picker/file_picker.dart';
import '../l10n/language.dart';
import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

import '../automations/automation.dart';
import '../automations/automation_service.dart';
import '../automations/note_sorter.dart';
import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../templates/templates.dart';
import '../style/platform_dialog.dart';

/// The automations: what happens in the app, and what to do about it.
class AutomationsView extends StatelessWidget {
  final AutomationService service;
  final NoteRepository repository;

  /// The extensions whose actions can be chosen; null: none.
  final ExtensionService? extensions;

  /// The AI that makes an extension and its rules from a description ("Create with AI"); null hides the button.
  final AiService? ai;

  /// The templates a rule can make notes from; null: none.
  final TemplateService? templates;

  const AutomationsView({super.key, required this.service, required this.repository, this.extensions, this.ai, this.templates});

  Future<void> _edit(BuildContext context, [Automation? existing]) async {
    final folders = await repository.listFolders();
    final choices = <({String id, String name})>[
      for (final t in templates?.builtIn ?? const <BuiltInTemplate>[]) (id: t.id, name: t.name),
      for (final t in await (templates?.saved() ?? Future.value(const <SavedTemplate>[]))) (id: 'saved:${t.id}', name: t.name),
    ];
    if (!context.mounted) return;
    final result = await showDialog<Automation>(
      context: context,
      builder: (context) => AutomationDialog(existing: existing, folders: folders, extensions: extensions, events: service.events, templates: choices),
    );
    if (result == null) return;
    if (existing == null) {
      await service.add(result);
    } else {
      await service.update(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final all = service.all;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Automations'),
            actions: [
              if (ai != null && ai!.provider != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton.icon(
                    key: const ValueKey('describe-rule'),
                    onPressed: () async {
                      final folders = await repository.listFolders();
                      if (context.mounted) await showRuleWriter(context, service: service, folders: folders);
                    },
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Describe a rule'),
                  ),
                ),
              if (ai != null && ai!.provider != null && extensions != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton.icon(
                    key: const ValueKey('magic-automation'),
                    onPressed: () async {
                      final made = await showMagicExtension(context, ai: ai!, extensions: extensions!, automations: service);
                      if (made != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim(made.message), duration: const Duration(seconds: 8)));
                    },
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('Create with AI'),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  key: const ValueKey('new-automation'),
                  onPressed: () => _edit(context),
                  icon: const Icon(Icons.add),
                  label: const Text('New automation'),
                ),
              ),
            ],
          ),
          body: all.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Nothing automated yet.\n\nPick something that happens (like closing a note) '
                      'and what should follow (like saving it as a PDF).',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [for (final a in all) _card(context, a)],
                ),
        );
      },
    );
  }

  Widget _card(BuildContext context, Automation a) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<FolderEntry>>(
      future: repository.listFolders(),
      builder: (context, snapshot) {
        String folderName(String? id) =>
            snapshot.data?.where((f) => f.id == id).firstOrNull?.name ?? tr('a folder that is gone');
        final details = <String>[
          if (a.event == AutomationEvent.noteStale) tr('Not opened for {weeks} weeks', {'weeks': a.params['weeks'] ?? '4'}),
          if (a.event == AutomationEvent.calendarEventStarting) tr('{n} minutes before it starts', {'n': a.params['minutes'] ?? '10'}),
          if (a.event == AutomationEvent.triggerPressed) tr('Trigger {n}', {'n': a.params['trigger'] ?? '1'}),
          if (a.folderId != null) tr('Only for notes in {folder}', {'folder': folderName(a.folderId)}),
          if (a.contains != null && a.contains!.trim().isNotEmpty) tr('Only when the name contains: {text}', {'text': a.contains}),
          switch (a.action) {
            AutomationAction.exportPdf => tr('Into {folder}', {'folder': a.params['dir'] ?? tr('(no folder chosen)')}),
            AutomationAction.addTask =>
              tr('Task: {title}', {'title': a.params['title'] ?? '{title}'}) +
                  (a.params['smart'] == '1' ? tr(' (title improved by the language model)') : ''),
            AutomationAction.moveToFolder => tr('Into {folder}', {'folder': folderName(a.params['folder'])}),
            AutomationAction.saveNoteFile => tr('Into {folder}', {'folder': a.params['dir'] ?? tr('(no folder chosen)')}),
            AutomationAction.sortIntoFolder =>
              '${a.params['within'] == null || a.params['within']!.isEmpty ? tr('Into any folder') : tr('Into a folder of {folder}', {'folder': folderName(a.params['within'])})}'
                  ', ${a.params['unfiledOnly'] == '0' ? tr('also notes that are filed already') : tr('only notes not in a folder yet')}'
                  ', ${tr((SortStrictness.values.where((s) => s.name == a.params['strictness']).firstOrNull ?? SortStrictness.normal).name)}',
            AutomationAction.convertHandwriting => tr('The text goes in a box under the writing on each page'),
            AutomationAction.extensionAction => () {
                final parts = (a.params['extension'] ?? '').split('/');
                final ext = parts.length == 2 ? extensions?.byId(parts[0]) : null;
                final act = ext?.manifest.actions.where((x) => x.id == parts[1]).firstOrNull;
                return act == null ? tr('An extension action that is not installed') : '${ext!.manifest.name}: ${act.title}';
              }(),
            AutomationAction.indexInk => tr('Reads the handwriting of every note in the background'),
            AutomationAction.appendToNote ||
            AutomationAction.addTag ||
            AutomationAction.translateToBox ||
            AutomationAction.createNoteFromTemplate ||
            AutomationAction.meetingNote ||
            AutomationAction.setReminder ||
            AutomationAction.exportImages =>
              [
                for (final f in a.action.fields)
                  if (f.when == null || a.params[f.when!.$1] == f.when!.$2)
                    if ((a.params[f.key] ?? '').isNotEmpty)
                    '${tr(f.label)}: ${f.kind == FieldKind.choice
                        ? tr(f.choices[a.params[f.key]] ?? a.params[f.key]!)
                        : f.kind == FieldKind.folder
                        ? folderName(a.params[f.key])
                        : a.params[f.key]}',
              ].join(', '),
            AutomationAction.starNote => tr('The note gets a star'),
            AutomationAction.addCitation => tr('The page becomes a source, to cite with [@key]'),
            AutomationAction.askAboutNote => tr('The note is listed on the dashboard, with the question what to do about it'),
            AutomationAction.summarizeToBox => tr('The summary is a text box under the rest of the last page'),
            AutomationAction.outlineToBox => tr('The outline is a text box under the rest of the last page'),
            AutomationAction.titleNote => tr('Only notes without a title are named'),
            AutomationAction.makeFlashcards => tr('About {n} flashcards from the note, kept for review', {'n': a.params['count'] ?? '6'}),
            AutomationAction.reviewCardsTask => tr('Task: {title}', {'title': a.params['title'] ?? 'Review {n} flashcards'}),
            AutomationAction.prepareInk => switch (a.params['what']) {
                'text' => tr('Reads the handwriting ahead of time'),
                'formulas' => tr('Reads the formulas ahead of time'),
                _ => tr('Reads the handwriting and the formulas ahead of time'),
              },
          },
          if (a.event == AutomationEvent.notePaused) tr('Half a minute after the last change'),
          if (a.then.isNotEmpty) '${tr('Then')}: ${a.then.map((t) => tr(t.action.label)).join('  →  ')}',
          if ((a.event == AutomationEvent.noteOpened || a.event == AutomationEvent.noteClosed) && a.action != AutomationAction.prepareInk) tr('Runs only when the note was changed since last time'),
        ];
        return Card(
          key: ValueKey('automation-${a.id}'),
          child: ListTile(
            isThreeLine: true,
            leading: Icon(Icons.bolt, color: a.enabled ? scheme.primary : scheme.outline),
            title: Text('${tr(a.event.label)}  →  ${tr(a.action.label)}'),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final d in details) Text(d),
              if (a.lastResult != null)
                Text.verbatim(tr('Last run {when}: {result}', {'when': _ago(a.lastRun), 'result': tr(a.lastResult ?? '')}),
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            ]),
            onTap: () => _edit(context, a),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                key: ValueKey('automation-log-${a.id}'),
                tooltip: tr('What this rule did'),
                icon: const Icon(Icons.history),
                onPressed: () => showAutomationLog(context, service: service, rule: a),
              ),
              if (a.event == AutomationEvent.dateFound)
                IconButton(
                  key: ValueKey('automation-rescan-${a.id}'),
                  tooltip: tr('Forget which dates were handled: the next time a PDF is opened they count as new'),
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    await service.forgetHandled(a.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Dates in PDFs count as new again; open a PDF to scan it')),
                      );
                    }
                  },
                ),
              Switch.adaptive(
                key: ValueKey('automation-switch-${a.id}'),
                value: a.enabled,
                onChanged: (v) => service.update(a.copyWith(enabled: v)),
              ),
              IconButton(
                key: ValueKey('automation-delete-${a.id}'),
                tooltip: tr('Delete'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => service.remove(a.id),
              ),
            ]),
          ),
        );
      },
    );
  }

  static String _ago(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return tr('just now');
    if (d.inHours < 1) return tr('{n} min ago', {'n': d.inMinutes});
    if (d.inDays < 1) return tr('{n} h ago', {'n': d.inHours});
    return tr('{n} d ago', {'n': d.inDays});
  }
}

/// Makes or changes one automation.
class AutomationDialog extends StatefulWidget {
  final Automation? existing;
  final List<FolderEntry> folders;
  final ExtensionService? extensions;

  /// The events a rule can be made for.
  final List<AutomationEvent> events;

  /// The templates to make notes from: the id (`saved:` in front of a template the person kept) and the name.
  final List<({String id, String name})> templates;

  /// The dialog makes a further step of a rule (see [ChainStep]) for [existing]'s event instead of a rule: no event, no scope; the action
  /// is one that can follow another. What comes back is an [Automation] of which only the action and the settings count.
  final bool step;

  const AutomationDialog(
      {super.key, this.existing, required this.folders, this.extensions, this.events = AutomationEvent.values, this.templates = const [], this.step = false});

  @override
  State<AutomationDialog> createState() => _AutomationDialogState();
}

class _AutomationDialogState extends State<AutomationDialog> {
  late AutomationEvent _event = widget.existing?.event ?? AutomationEvent.noteClosed;
  late AutomationAction _action = widget.step ? _firstStep : (widget.existing?.action ?? AutomationAction.exportPdf);

  /// The steps after the action (a rule's own; a step of a step is none).
  late List<ChainStep> _then = widget.step ? const [] : [...?widget.existing?.then];

  AutomationAction get _firstStep => AutomationAction.values.firstWhere((a) => chainable(a) && a.worksAfter(_stepEvent));

  /// The event the steps are for: what needs the open editor is no step, as a chain runs after the note was left.
  AutomationEvent get _stepEvent => AutomationEvent(_event.id, _event.label, hasNote: _event.hasNote, hasEditor: false);
  late String? _scope = widget.existing?.folderId;
  late String? _target = widget.existing?.params['folder'];
  late TaskDue _due = TaskDue.values.where((d) => d.name == widget.existing?.params['due']).firstOrNull ?? TaskDue.none;
  late final TextEditingController _dir = TextEditingController(text: widget.existing?.params['dir'] ?? '');
  late final TextEditingController _taskTitle =
      TextEditingController(text: widget.existing?.params['title'] ?? _defaultTask(_event));
  late bool _taskTouched = widget.existing != null;
  late bool _smart = widget.existing?.params['smart'] == '1';
  late String _inkWhat = const {'text', 'formulas'}.contains(widget.existing?.params['what']) ? widget.existing!.params['what']! : 'both';
  late String? _within = widget.existing?.params['within'];
  late String? _extAction = widget.existing?.params['extension'];
  late bool _unfiledOnly = widget.existing?.params['unfiledOnly'] != '0';
  late SortStrictness _strictness =
      SortStrictness.values.where((s) => s.name == widget.existing?.params['strictness']).firstOrNull ?? SortStrictness.normal;
  /// The settings of the action that are described by [ActionField]s: what each has now (kept for the field that is shown).
  final Map<String, String> _values = {};
  final Map<String, TextEditingController> _inputs = {};

  String _value(ActionField f) => _values[f.key] ??= (widget.existing != null && widget.existing!.action == _action ? widget.existing!.params[f.key] : null) ?? f.initial;

  TextEditingController _input(ActionField f) => _inputs.putIfAbsent(f.key, () => TextEditingController(text: _value(f)));

  bool _shown(ActionField f) => f.when == null || _values[f.when!.$1] == f.when!.$2;

  late final TextEditingController _count = TextEditingController(text: widget.existing?.params['count'] ?? '6');
  late final TextEditingController _contains = TextEditingController(text: widget.existing?.contains ?? '');
  late String _trigger = widget.existing?.params['trigger'] ?? '1';
  late final TextEditingController _minutes = TextEditingController(text: widget.existing?.params['minutes'] ?? '10');
  late final TextEditingController _weeks = TextEditingController(text: widget.existing?.params['weeks'] ?? '4');

  String _defaultTask(AutomationEvent e) =>
      _action == AutomationAction.reviewCardsTask
          ? 'Review {n} flashcards'
          : e == AutomationEvent.dateFound
              ? '{time} {summary}'
              : e == AutomationEvent.todoFound
                  ? '{summary}'
                  : 'Review {title}';

  @override
  void dispose() {
    _dir.dispose();
    _taskTitle.dispose();
    _contains.dispose();
    _weeks.dispose();
    _minutes.dispose();
    for (final c in _inputs.values) {
      c.dispose();
    }
    _count.dispose();
    super.dispose();
  }

  List<AutomationAction> get _actions =>
      AutomationAction.values.where((a) => widget.step ? chainable(a) && a.worksAfter(_stepEvent) : a.worksAfter(_event)).toList();

  void _changeEvent(AutomationEvent e) {
    setState(() {
      _event = e;
      if (!_taskTouched) _taskTitle.text = _defaultTask(e);
      if (!_action.worksAfter(e)) _action = _actions.first;
      if (!e.hasNote) _scope = null;
    });
  }

  bool get _valid =>
      (_event != AutomationEvent.noteStale || (int.tryParse(_weeks.text.trim()) ?? 0) >= 1) &&
      (_event != AutomationEvent.calendarEventStarting || (int.tryParse(_minutes.text.trim()) ?? 0) >= 1) &&
      switch (_action) {
        AutomationAction.exportPdf => _dir.text.trim().isNotEmpty,
        AutomationAction.addTask => _taskTitle.text.trim().isNotEmpty,
        AutomationAction.moveToFolder => _target != null,
        AutomationAction.saveNoteFile => _dir.text.trim().isNotEmpty,
        AutomationAction.sortIntoFolder => true,
        AutomationAction.convertHandwriting => true,
        AutomationAction.prepareInk => true,
        AutomationAction.indexInk => true,
        AutomationAction.appendToNote ||
        AutomationAction.addTag ||
        AutomationAction.translateToBox ||
        AutomationAction.createNoteFromTemplate ||
        AutomationAction.meetingNote ||
        AutomationAction.setReminder ||
        AutomationAction.exportImages =>
          _action.fields.every((f) => !f.required || !_shown(f) || _value(f).trim().isNotEmpty),
        AutomationAction.starNote || AutomationAction.summarizeToBox || AutomationAction.outlineToBox || AutomationAction.askAboutNote || AutomationAction.addCitation => true,
        AutomationAction.titleNote => true,
        AutomationAction.makeFlashcards => (int.tryParse(_count.text.trim()) ?? 0) >= 1,
        AutomationAction.reviewCardsTask => _taskTitle.text.trim().isNotEmpty,
        AutomationAction.extensionAction => _extAction != null && _extAction!.contains('/'),
      };

  Automation _build() => Automation(
        id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        event: _event,
        action: _action,
        then: chainable(_action) ? _then : const [],
        folderId: _event.hasNote ? _scope : null,
        contains: _event.hasNote && _contains.text.trim().isNotEmpty ? _contains.text.trim() : null,
        enabled: widget.existing?.enabled ?? true,
        lastRun: widget.existing?.lastRun,
        lastResult: widget.existing?.lastResult,
        params: switch (_action) {
          AutomationAction.exportPdf => {'dir': _dir.text.trim()},
          AutomationAction.addTask => {
            'title': _taskTitle.text.trim(),
            'due': _due.name,
            if (_event == AutomationEvent.dateFound && _smart) 'smart': '1',
          },
          AutomationAction.moveToFolder => {'folder': _target!},
          AutomationAction.saveNoteFile => {'dir': _dir.text.trim()},
          AutomationAction.sortIntoFolder => {
            'within': ?_within,
            'unfiledOnly': _unfiledOnly ? '1' : '0',
            'strictness': _strictness.name,
          },
          AutomationAction.convertHandwriting => {},
          AutomationAction.indexInk => {},
          AutomationAction.appendToNote ||
          AutomationAction.addTag ||
          AutomationAction.translateToBox ||
          AutomationAction.createNoteFromTemplate ||
          AutomationAction.meetingNote ||
          AutomationAction.setReminder ||
          AutomationAction.exportImages =>
            {
              for (final f in _action.fields)
                if (_shown(f) && _value(f).trim().isNotEmpty) f.key: f.kind == FieldKind.text || f.kind == FieldKind.multiline || f.kind == FieldKind.directory ? _value(f).trim() : _value(f),
            },
          AutomationAction.starNote || AutomationAction.summarizeToBox || AutomationAction.outlineToBox || AutomationAction.askAboutNote || AutomationAction.addCitation => {},
          AutomationAction.titleNote => {},
          AutomationAction.makeFlashcards => {'count': '${int.parse(_count.text.trim()).clamp(1, 30)}'},
          AutomationAction.reviewCardsTask => {'title': _taskTitle.text.trim()},
          AutomationAction.prepareInk => {'what': _inkWhat},
          AutomationAction.extensionAction => {'extension': _extAction!},
        }
          ..addAll(_event == AutomationEvent.noteStale ? {'weeks': '${int.parse(_weeks.text.trim())}'} : {})
          ..addAll(_event == AutomationEvent.triggerPressed ? {'trigger': _trigger} : {})
          ..addAll(_event == AutomationEvent.calendarEventStarting ? {'minutes': '${int.parse(_minutes.text.trim()).clamp(1, 720)}'} : {}),
      );

  Future<void> _browse() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Where should the files go?');
    if (dir != null) setState(() => _dir.text = dir);
  }

  Future<void> _addStep() async {
    final made = await showDialog<Automation>(
      context: context,
      builder: (_) => AutomationDialog(
        existing: Automation(id: 'step', event: _event, action: _action),
        folders: widget.folders,
        extensions: widget.extensions,
        templates: widget.templates,
        step: true,
      ),
    );
    if (made != null && mounted) setState(() => _then = [..._then, ChainStep(made.action, made.params)]);
  }

  /// The input for one setting of the action.
  Widget _fieldInput(ActionField f) {
    final key = ValueKey('automation-field-${f.key}');
    final label = tr(f.label);
    switch (f.kind) {
      case FieldKind.text:
      case FieldKind.multiline:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextField(
            key: key,
            controller: _input(f),
            minLines: 1,
            maxLines: f.kind == FieldKind.multiline ? 4 : 1,
            onChanged: (v) => setState(() => _values[f.key] = v),
            decoration: InputDecoration(labelText: label, helperText: f.help == null ? null : tr(f.help!), helperMaxLines: 2),
          ),
        );
      case FieldKind.directory:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                key: key,
                controller: _input(f),
                onChanged: (v) => setState(() => _values[f.key] = v),
                decoration: InputDecoration(labelText: label, helperText: f.help == null ? null : tr(f.help!)),
              ),
            ),
            IconButton(
              tooltip: tr('Choose...'),
              icon: const Icon(Icons.folder_open),
              onPressed: () async {
                final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Where should the files go?');
                if (dir != null) {
                  setState(() {
                    _values[f.key] = dir;
                    _input(f).text = dir;
                  });
                }
              },
            ),
          ]),
        );
      case FieldKind.choice:
        final value = f.choices.containsKey(_value(f)) ? _value(f) : f.choices.keys.first;
        _values[f.key] = value;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: DropdownButtonFormField<String>(
            key: key,
            isExpanded: true,
            initialValue: value,
            decoration: InputDecoration(labelText: label),
            items: [for (final e in f.choices.entries) DropdownMenuItem(value: e.key, child: Text.verbatim(tr(e.value)))],
            onChanged: (v) => setState(() => _values[f.key] = v ?? value),
          ),
        );
      case FieldKind.folder:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: DropdownButtonFormField<String>(
            key: key,
            isExpanded: true,
            initialValue: widget.folders.any((x) => x.id == _value(f)) ? _value(f) : '',
            decoration: InputDecoration(labelText: label),
            items: [
              DropdownMenuItem(value: '', child: Text.verbatim(tr('No folder'))),
              for (final x in widget.folders) DropdownMenuItem(value: x.id, child: Text.verbatim(x.name)),
            ],
            onChanged: (v) => setState(() => _values[f.key] = v ?? ''),
          ),
        );
      case FieldKind.template:
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: widget.templates.isEmpty && f.required
              ? Text(tr('There are no templates here.'))
              : DropdownButtonFormField<String>(
                  key: key,
                  isExpanded: true,
                  initialValue: widget.templates.any((t) => t.id == _value(f)) ? _value(f) : null,
                  hint: Text(tr('Choose a template')),
                  decoration: InputDecoration(labelText: label),
                  items: [
                    if (!f.required) DropdownMenuItem(value: '', child: Text.verbatim(tr('No template (a blank note)'))),
                    for (final t in widget.templates) DropdownMenuItem(value: t.id, child: Text.verbatim(t.name)),
                  ],
                  onChanged: (v) => setState(() => _values[f.key] = v ?? ''),
                ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final folderItems = [
      for (final f in widget.folders) DropdownMenuItem(value: f.id, child: Text.verbatim(f.name)),
    ];
    return PlatformAlertDialog(
      title: Text(widget.step ? tr('A further step') : widget.existing == null ? 'New automation' : 'Change automation'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!widget.step) const Text('When'),
            if (!widget.step)
            DropdownButton<AutomationEvent>(
              key: const ValueKey('automation-event'),
              isExpanded: true,
              value: _event,
              items: [
                // a rule of an event that is not announced now (its extension is gone) still shows
                for (final e in [...widget.events, if (!widget.events.contains(_event)) _event]) DropdownMenuItem(value: e, child: Text(e.label)),
              ],
              onChanged: (e) => e == null ? null : _changeEvent(e),
            ),
            if (!widget.step && _event.hasNote && widget.folders.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('For'),
              DropdownButton<String?>(
                key: const ValueKey('automation-scope'),
                isExpanded: true,
                value: _scope,
                items: [
                  const DropdownMenuItem(value: null, child: Text('Any note')),
                  for (final f in widget.folders) DropdownMenuItem(value: f.id, child: Text.verbatim(tr('Notes in {folder}', {'folder': f.name}))),
                ],
                onChanged: (v) => setState(() => _scope = v),
              ),
            ],
            if (!widget.step && _event == AutomationEvent.noteStale) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('automation-weeks'),
                controller: _weeks,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: tr('Weeks without opening it'), helperText: tr('Checked when the app starts and every few hours')),
              ),
            ],
            if (!widget.step && _event == AutomationEvent.triggerPressed) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey('automation-trigger'),
                isExpanded: true,
                initialValue: _trigger,
                decoration: InputDecoration(
                  labelText: tr('Which trigger'),
                  helperText: tr('Bind a key to "Run the automations of trigger 1" in the settings of the shortcuts, or set the side button of the pen to it (Settings, pen)'),
                  helperMaxLines: 3,
                ),
                items: [for (final n in ['1', '2', '3']) DropdownMenuItem(value: n, child: Text.verbatim(tr('Trigger {n}', {'n': n})))],
                onChanged: (v) => setState(() => _trigger = v ?? '1'),
              ),
            ],
            if (!widget.step && _event == AutomationEvent.calendarEventStarting) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('automation-minutes'),
                controller: _minutes,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: tr('Minutes before it starts'), helperText: tr('Looked at every minute while the app runs; each event once')),
              ),
            ],
            if (!widget.step && _event.hasNote) ...[
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('automation-contains'),
                controller: _contains,
                decoration: InputDecoration(
                  labelText: tr('Only when the name contains (optional)'),
                  helperText: tr('The note\'s title or its PDF\'s file name; several words with commas, e.g. Physics, Lecture'),
                  helperMaxLines: 2,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(widget.step ? tr('Do') : 'Then'),
            DropdownButton<AutomationAction>(
              key: const ValueKey('automation-action'),
              isExpanded: true,
              value: _action,
              items: [for (final a in _actions) DropdownMenuItem(value: a, child: Text(a.label))],
              onChanged: (a) => a == null
                  ? null
                  : setState(() {
                      if (a != _action) {
                        _values.clear();
                        for (final c in _inputs.values) {
                          c.dispose();
                        }
                        _inputs.clear();
                      }
                      _action = a;
                      if (!_taskTouched) _taskTitle.text = _defaultTask(_event);
                    }),
            ),
            const SizedBox(height: 8),
            if (_action == AutomationAction.exportPdf || _action == AutomationAction.saveNoteFile)
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('automation-dir'),
                    controller: _dir,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: tr(_action == AutomationAction.exportPdf ? 'Save the PDF in this folder' : 'Save the note file in this folder'),
                      helperText: tr('Named after the note; an older one is replaced'),
                    ),
                  ),
                ),
                IconButton(tooltip: tr('Choose...'), icon: const Icon(Icons.folder_open), onPressed: _browse),
              ]),
            if (_action == AutomationAction.addTask) ...[
              TextField(
                key: const ValueKey('automation-task'),
                controller: _taskTitle,
                onChanged: (_) => setState(() => _taskTouched = true),
                decoration: InputDecoration(
                  labelText: tr('Task'),
                  helperMaxLines: 3,
                  helperText: tr(_event == AutomationEvent.todoFound
                      ? '{summary} is what is to be done, {line} the whole line, {title} the note\'s title. The task is on the day the line says ("by Friday"), else on the day below'
                      : _event == AutomationEvent.dateFound
                      ? 'The task is on the date found. {summary} is the line it was in without the date, '
                          '{line} the whole line, {time} its time (tasks have no time of their own, '
                          'so it goes into the text), {title} the note\'s title'
                      : '{title} is ${_event.hasNote
                                    ? 'the note\'s' : _event == AutomationEvent.appStarted ? 'empty' : 'the event\'s'} title, {date} today\'s date'
                          '${[for (final (name, what) in _event.placeholders) ', $name $what'].join()}'),
                ),
              ),
              const SizedBox(height: 8),
              if (_event == AutomationEvent.dateFound)
                SwitchListTile.adaptive(
                  key: const ValueKey('automation-smart'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Improve the title with the language model'),
                  subtitle: const Text('Rewrites {summary} when the model from Settings is installed; otherwise it stays as it is'),
                  value: _smart,
                  onChanged: (v) => setState(() => _smart = v),
                ),
              if (_event != AutomationEvent.dateFound)
              DropdownButton<TaskDue>(
                key: const ValueKey('automation-due'),
                isExpanded: true,
                value: _due,
                items: [for (final d in TaskDue.values) DropdownMenuItem(value: d, child: Text.verbatim(tr('Due: {when}', {'when': tr(d.label)})))],
                onChanged: (d) => d == null ? null : setState(() => _due = d),
              ),
            ],
            for (final f in _action.fields)
              if (_shown(f)) _fieldInput(f),
            if (_action == AutomationAction.starNote || _action == AutomationAction.summarizeToBox || _action == AutomationAction.outlineToBox || _action == AutomationAction.askAboutNote || _action == AutomationAction.addCitation)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_action == AutomationAction.addCitation
                    ? 'The page the note was made from (its address, its title, the site and the day it was kept) is added to the sources of the citations, to cite in any note with [@key]. A page that is a source already is not added again.'
                    : _action == AutomationAction.askAboutNote
                    ? 'The note is listed on the dashboard: "Still relevant?" with the answers: keep it, archive it, remind me in a week, make flashcards of it, or not now. Nothing changes until you answer.'
                    : _action == AutomationAction.starNote
                    ? 'The note is starred, so that it is listed as a favourite on the dashboard.'
                    : _action == AutomationAction.outlineToBox
                        ? 'The assistant reads the text of the note and writes its outline (topics and points) into a text box under the rest of the last page. A later run replaces it. Needs the assistant.'
                        : 'The assistant reads the text of the note and writes a short summary into a text box under the rest of the last page. A later run replaces it. Needs the assistant.'),
              ),
            if (_action == AutomationAction.titleNote)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'A note whose title is empty or "Untitled Note" is named after what it says: the language model writes a short title if it is '
                  'installed (Settings), else the first line is used when it is short enough. A note that has a title is never changed.',
                ),
              ),
            if (_action == AutomationAction.makeFlashcards) ...[
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'The assistant reads the text of the note and writes flashcards from it, which are kept for review (Flashcards, spaced repetition). '
                  'A question that is kept already is not added again. Needs the assistant; a model on this device takes a minute or so.',
                ),
              ),
              TextField(
                key: const ValueKey('automation-count'),
                controller: _count,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: tr('About how many cards')),
              ),
            ],
            if (_action == AutomationAction.reviewCardsTask)
              TextField(
                key: const ValueKey('automation-task'),
                controller: _taskTitle,
                onChanged: (_) => setState(() => _taskTouched = true),
                decoration: InputDecoration(
                  labelText: tr('Task'),
                  helperText: tr('{n} is how many cards are due. One task a day, today, while there are cards due'),
                  helperMaxLines: 2,
                ),
              ),
            if (_action == AutomationAction.convertHandwriting)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Reads the pen writing of each page in the background and puts the text in a box under it. '
                  'A page is read again only when its writing changes. Needs the handwriting model from Settings; '
                  'a page takes a while on a tablet.',
                ),
              ),
            if (_action == AutomationAction.extensionAction) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  widget.extensions == null || widget.extensions!.actions.isEmpty
                      ? 'No extension has an action to run. Install one in Settings > Extensions and switch it on.'
                      : 'Runs an action of an extension, with the permissions you gave it. What it returns is shown as the result of the automation.',
                ),
              ),
              if (widget.extensions != null && widget.extensions!.actions.isNotEmpty)
                DropdownButton<String>(
                  key: const ValueKey('automation-extension-action'),
                  isExpanded: true,
                  hint: const Text('Choose an action'),
                  value: widget.extensions!.actions.any((x) => '${x.extension.id}/${x.action.id}' == _extAction) ? _extAction : null,
                  items: [
                    for (final x in widget.extensions!.actions)
                      DropdownMenuItem(value: '${x.extension.id}/${x.action.id}', child: Text.verbatim('${x.extension.manifest.name}: ${x.action.title}')),
                  ],
                  onChanged: (v) => setState(() => _extAction = v),
                ),
            ],
            if (_action == AutomationAction.prepareInk) ...[
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'While the note is open, the pen strokes that lie close together are grouped and, after things have been quiet for a moment '
                  '(never while you draw), read in the background. When you then select that writing and convert it, the result is there at once. '
                  'Needs the models from Settings. Nothing is changed in the note.',
                ),
              ),
              DropdownButton<String>(
                key: const ValueKey('automation-ink-what'),
                isExpanded: true,
                value: _inkWhat,
                items: const [
                  DropdownMenuItem(value: 'both', child: Text('Handwriting and formulas')),
                  DropdownMenuItem(value: 'text', child: Text('Handwriting only')),
                  DropdownMenuItem(value: 'formulas', child: Text('Formulas only')),
                ],
                onChanged: (v) => setState(() => _inkWhat = v ?? _inkWhat),
              ),
            ],
            if (_action == AutomationAction.sortIntoFolder) ...[
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 8),
                child: Text(
                  'A language model on this device reads the note and compares it with the notes in each folder; '
                  'the note goes to the folder it resembles most, if that is clear enough. Needs the sentence model '
                  'from Settings. The notes of a folder are read once, and again only when they change.',
                ),
              ),
              DropdownButton<String?>(
                key: const ValueKey('automation-within'),
                isExpanded: true,
                value: widget.folders.any((f) => f.id == _within) ? _within : null,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('File into any folder')),
                  for (final f in widget.folders) DropdownMenuItem<String?>(value: f.id, child: Text.verbatim(tr('Only into the folders inside {folder}', {'folder': f.name}))),
                ],
                onChanged: (v) => setState(() => _within = v),
              ),
              CheckboxListTile.adaptive(
                key: const ValueKey('automation-unfiled'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _unfiledOnly,
                title: const Text('Only notes that are not in a folder yet'),
                onChanged: (v) => setState(() => _unfiledOnly = v ?? true),
              ),
              DropdownButton<SortStrictness>(
                key: const ValueKey('automation-strictness'),
                isExpanded: true,
                value: _strictness,
                items: [for (final s in SortStrictness.values) DropdownMenuItem(value: s, child: Text(s.label))],
                onChanged: (v) => setState(() => _strictness = v ?? _strictness),
              ),
            ],
            if (_action == AutomationAction.moveToFolder)
              DropdownButton<String>(
                key: const ValueKey('automation-target'),
                isExpanded: true,
                hint: const Text('Choose a folder'),
                value: widget.folders.any((f) => f.id == _target) ? _target : null,
                items: folderItems,
                onChanged: (v) => setState(() => _target = v),
              ),
            if (!widget.step && chainable(_action) && AutomationAction.values.any((a) => chainable(a) && a.worksAfter(_stepEvent))) ...[
              const Divider(height: 28),
              Text(tr('Then also, one after the other')),
              for (var i = 0; i < _then.length; i++)
                ListTile(
                  key: ValueKey('automation-step-$i'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(radius: 11, child: Text.verbatim('${i + 2}', style: const TextStyle(fontSize: 11))),
                  title: Text(tr(_then[i].action.label)),
                  trailing: IconButton(
                    key: ValueKey('automation-step-remove-$i'),
                    tooltip: tr('Take this step out'),
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _then = [..._then]..removeAt(i)),
                  ),
                ),
              TextButton.icon(key: const ValueKey('automation-add-step'), onPressed: _addStep, icon: const Icon(Icons.add), label: Text(tr('Add a step'))),
              Text(
                tr('The steps run in the background, one after the other. Each can use {result}, what the one before said, in its text; a step that cannot do its work ends the chain.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('automation-save'),
          onPressed: _valid ? () => Navigator.pop(context, _build()) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
