import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../reminders/reminder.dart';
import '../reminders/reminder_service.dart';
import '../style/platform_dialog.dart';

/// "Remind me" for a note or a task (or a free text): quick choices for when, a date and time of the person's own, and how often.
/// Makes the reminder; the answer is whether one was made.
Future<bool> showRemindDialog(BuildContext context, ReminderService service, {ReminderKind kind = ReminderKind.custom, String? refId, String title = ''}) async {
  final made = await showDialog<bool>(
    context: context,
    builder: (context) => _RemindDialog(service: service, kind: kind, refId: refId, initialTitle: title, now: DateTime.now()),
  );
  return made ?? false;
}

/// The moments offered as quick choices, as of [now]: in an hour, this evening, tomorrow morning, next Monday morning.
List<(String, DateTime)> reminderPresets(DateTime now) {
  final out = <(String, DateTime)>[
    ('In an hour', now.add(const Duration(hours: 1))),
    if (now.hour < 18) ('This evening', DateTime(now.year, now.month, now.day, 18)),
    ('Tomorrow morning', DateTime(now.year, now.month, now.day + 1, 9)),
    ('Next week', DateTime(now.year, now.month, now.day + (8 - now.weekday), 9)),
  ];
  return out;
}

class _RemindDialog extends StatefulWidget {
  final ReminderService service;
  final ReminderKind kind;
  final String? refId;
  final String initialTitle;
  final DateTime now;

  const _RemindDialog({required this.service, required this.kind, required this.refId, required this.initialTitle, required this.now});

  @override
  State<_RemindDialog> createState() => _RemindDialogState();
}

class _RemindDialogState extends State<_RemindDialog> {
  late final _title = TextEditingController(text: widget.initialTitle);
  late DateTime _at = reminderPresets(widget.now)[1].$2; // this evening, or tomorrow morning when that has passed
  Repeat _repeat = Repeat.none;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final day = await showDatePicker(context: context, initialDate: _at, firstDate: DateTime(widget.now.year, widget.now.month, widget.now.day), lastDate: DateTime(widget.now.year + 5));
    if (day == null || !mounted) return;
    setState(() => _at = DateTime(day.year, day.month, day.day, _at.hour, _at.minute));
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (time == null || !mounted) return;
    setState(() => _at = DateTime(_at.year, _at.month, _at.day, time.hour, time.minute));
  }

  Future<void> _make() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    await widget.service.ensurePermission();
    await widget.service.reminders.add(kind: widget.kind, refId: widget.refId, title: title, at: _at, repeat: _repeat);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final presets = reminderPresets(widget.now);
    return PlatformAlertDialog(
      title: const Text('Remind me'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(key: const ValueKey('remind-title'), controller: _title, autofocus: widget.initialTitle.isEmpty, decoration: InputDecoration(labelText: tr('What for?'))),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (label, time) in presets) ActionChip(key: ValueKey('remind-preset-$label'), label: Text(label), onPressed: () => setState(() => _at = time)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(key: const ValueKey('remind-date'), icon: const Icon(Icons.event, size: 18), label: Text.verbatim(MaterialLocalizations.of(context).formatMediumDate(_at)), onPressed: _pickDate)),
              const SizedBox(width: 8),
              OutlinedButton.icon(key: const ValueKey('remind-time'), icon: const Icon(Icons.schedule, size: 18), label: Text.verbatim(MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_at), alwaysUse24HourFormat: MediaQuery.of(context,).alwaysUse24HourFormat)), onPressed: _pickTime),
            ]),
            const SizedBox(height: 12),
            DropdownButtonFormField<Repeat>(
              key: const ValueKey('remind-repeat'),
              initialValue: _repeat,
              decoration: InputDecoration(labelText: tr('Repeat')),
              items: [for (final r in Repeat.values) DropdownMenuItem(value: r, child: Text(r.label))],
              onChanged: (r) => setState(() => _repeat = r ?? Repeat.none),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('remind-ok'), onPressed: _make, child: const Text('Remind me')),
      ],
    );
  }
}

/// All the reminders to come, the settings for the due dates of tasks, and the permission to notify.
class RemindersScreen extends StatefulWidget {
  final ReminderService service;

  const RemindersScreen({super.key, required this.service});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  List<Reminder> _list = const [];
  bool _loaded = false;

  ReminderService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _service.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _service.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final list = await _service.upcoming();
    if (mounted) {
      setState(() {
        _list = list;
        _loaded = true;
      });
    }
  }

  Future<void> _pickTaskTime() async {
    final m = _service.taskMinutes;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
    if (time != null) await _service.setTaskMinutes(time.hour * 60 + time.minute);
  }

  IconData _icon(Reminder r) => switch (r.kind) {
        ReminderKind.note => Icons.sticky_note_2_outlined,
        ReminderKind.task => Icons.check_circle_outline,
        ReminderKind.review => Icons.event_note_outlined,
        ReminderKind.custom => Icons.notifications_none,
      };

  String _when(Reminder r) {
    final t = r.pending ?? r.at;
    final l = MaterialLocalizations.of(context);
    final text = '${l.formatMediumDate(t)}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat)}';
    return r.repeat == Repeat.none ? text : '$text - ${tr(r.repeat.label)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = _service.taskMinutes;
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('new-reminder'),
        icon: const Icon(Icons.add_alert_outlined),
        label: const Text('New reminder'),
        onPressed: () async {
          if (await showRemindDialog(context, _service)) await _load();
        },
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
        if (!_service.available)
          _Banner(key: const ValueKey('reminders-unavailable'), icon: Icons.notifications_off_outlined, color: scheme.errorContainer, text: tr('Notifications are not available on this system. Reminders are kept, but nothing can tell you.'))
        else if (!_service.allowed)
          _Banner(
            key: const ValueKey('reminders-denied'),
            icon: Icons.notifications_off_outlined,
            color: scheme.errorContainer,
            text: tr('Notifications are not allowed for this app, so reminders cannot tell you.'),
            action: TextButton(key: const ValueKey('allow-notifications'), onPressed: _service.askPermission, child: const Text('Allow')),
          ),
        SwitchListTile.adaptive(
          key: const ValueKey('reminders-tasks'),
          title: const Text('Remind me of tasks on their due date'),
          value: _service.tasksOn,
          onChanged: (on) async {
            if (on) await _service.ensurePermission();
            await _service.setTasksOn(on);
          },
        ),
        if (_service.tasksOn)
          ListTile(
            key: const ValueKey('reminders-task-time'),
            title: const Text('Time of day'),
            trailing: Text.verbatim(MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay(hour: m ~/ 60, minute: m % 60), alwaysUse24HourFormat: MediaQuery.of(context,).alwaysUse24HourFormat)),
            onTap: _pickTaskTime,
          ),
        const Divider(),
        if (!_loaded)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator.adaptive()))
        else if (_list.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No reminders. Choose "Remind me" in the menu of a note, or make one here.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        for (final r in _list)
          ListTile(
            key: ValueKey('reminder-${r.id}'),
            leading: Icon(_icon(r)),
            title: Text.verbatim(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text.verbatim(_when(r)),
            trailing: r.auto
                ? null
                : IconButton(key: ValueKey('delete-reminder-${r.id}'), tooltip: tr('Delete'), icon: const Icon(Icons.delete_outline), onPressed: () async {
                    await _service.reminders.remove(r.id);
                    await _load();
                  }),
          ),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  const _Banner({super.key, required this.icon, required this.color, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [Icon(icon), const SizedBox(width: 12), Expanded(child: Text.verbatim(text)), ?action]),
      );
}

/// The button on the dashboard that opens the reminders.
class RemindersButton extends StatelessWidget {
  final ReminderService service;

  const RemindersButton({super.key, required this.service});

  @override
  Widget build(BuildContext context) => IconButton(
        key: const ValueKey('open-reminders'),
        tooltip: tr('Reminders'),
        icon: const Icon(Icons.notifications_none),
        onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RemindersScreen(service: service))),
      );
}
