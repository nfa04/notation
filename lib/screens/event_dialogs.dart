import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../sync/caldav_remote.dart';
import '../sync/task_calendar_mirror.dart';
import '../style/platform_dialog.dart';

String _dateText(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
String _timeText(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Asks for the details of a new event on [day] and the calendar to put it in (one of [targets]); [save] writes it.
/// Shows what went wrong when [save] throws, and stays open.
Future<bool> newEventDialog(
  BuildContext context, {
  required DateTime day,
  required List<CalendarInfo> targets,
  required Future<void> Function(CalendarInfo target, NewEvent event) save,
}) async {
  final title = TextEditingController();
  final notes = TextEditingController();
  var allDay = false;
  var first = DateTime(day.year, day.month, day.day);
  var last = first;
  var from = const TimeOfDay(hour: 9, minute: 0);
  var to = const TimeOfDay(hour: 10, minute: 0);
  var target = targets.first;
  String? problem;
  var saving = false;

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) {
        Future<void> pickDay(bool start) async {
          final d = await showDatePicker(context: context, initialDate: start ? first : last, firstDate: DateTime(2000), lastDate: DateTime(2100));
          if (d == null) return;
          setLocal(() {
            if (start) {
              first = d;
              if (last.isBefore(first)) last = first;
            } else {
              last = d.isBefore(first) ? first : d;
            }
          });
        }

        Future<void> pickTime(bool start) async {
          final t = await showTimePicker(context: context, initialTime: start ? from : to);
          if (t != null) setLocal(() => start ? from = t : to = t);
        }

        DateTime at(DateTime d, TimeOfDay t) => DateTime(d.year, d.month, d.day, t.hour, t.minute);
        final endBeforeStart = !allDay && !at(last, to).isAfter(at(first, from));

        Future<void> submit() async {
          if (title.text.trim().isEmpty || endBeforeStart || saving) return;
          setLocal(() {
            saving = true;
            problem = null;
          });
          try {
            await save(
              target,
              NewEvent(
                title: title.text.trim(),
                allDay: allDay,
                start: allDay ? first : at(first, from),
                end: allDay ? (last == first ? null : last) : at(last, to),
                description: notes.text.trim(),
              ),
            );
            if (context.mounted) Navigator.pop(context, true);
          } catch (e) {
            setLocal(() {
              saving = false;
              problem = '$e'.replaceFirst('Bad state: ', '');
            });
          }
        }

        return PlatformAlertDialog(
          title: const Text('New event'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(key: const ValueKey('event-title'), controller: title, autofocus: true, decoration: InputDecoration(labelText: tr('Title')), onSubmitted: (_) => submit()),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  key: const ValueKey('event-allday'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('All day'),
                  value: allDay,
                  onChanged: (v) => setLocal(() => allDay = v),
                ),
                Row(children: [
                  Expanded(child: TextButton(key: const ValueKey('event-start-day'), onPressed: () => pickDay(true), child: Text.verbatim(_dateText(first)))),
                  if (!allDay) TextButton(key: const ValueKey('event-start-time'), onPressed: () => pickTime(true), child: Text.verbatim(_timeText(from))),
                ]),
                Row(children: [
                  Expanded(child: TextButton(key: const ValueKey('event-end-day'), onPressed: () => pickDay(false), child: Text.verbatim(_dateText(last)))),
                  if (!allDay) TextButton(key: const ValueKey('event-end-time'), onPressed: () => pickTime(false), child: Text.verbatim(_timeText(to))),
                ]),
                if (endBeforeStart) Text(tr('The event must end after it starts.'), style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                const SizedBox(height: 8),
                DropdownButtonFormField<CalendarInfo>(
                  key: const ValueKey('event-calendar'),
                  initialValue: target,
                  decoration: InputDecoration(labelText: tr('Calendar')),
                  items: [for (final t in targets) DropdownMenuItem(value: t, child: Text.verbatim(t.name))],
                  onChanged: (v) => setLocal(() => target = v ?? target),
                ),
                const SizedBox(height: 8),
                TextField(controller: notes, minLines: 1, maxLines: 3, decoration: InputDecoration(labelText: tr('Notes'))),
                if (problem != null) ...[
                  const SizedBox(height: 8),
                  Text.verbatim(problem!, key: const ValueKey('event-problem'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('event-save'), onPressed: saving ? null : submit, child: const Text('Add')),
          ],
        );
      },
    ),
  );
  // (the controllers are not disposed here: the dialog is still on screen while it closes)
  return saved == true;
}

/// Chooses the calendar the tasks that have a day are put on as events (or none), and which tasks.
Future<void> mirrorDialog(BuildContext context, TaskCalendarMirror mirror) async {
  final choices = await mirror.choices();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: mirror,
      builder: (context, _) => PlatformAlertDialog(
        title: const Text('Tasks on a calendar'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('A task with a day can also be put on a calendar as an all-day event, so that it shows up in the calendar app of the phone or of the server. It goes again when the task is done or deleted.'),
              const SizedBox(height: 12),
              if (choices.isEmpty)
                const Text('There is no calendar to put them on: connect a server or turn on a calendar of the phone first (both must allow writing).', key: ValueKey('mirror-none'))
              else
                RadioGroup<String?>(
                  groupValue: mirror.target,
                  onChanged: (v) => mirror.setTarget(v),
                  child: Column(children: [
                    const RadioListTile<String?>.adaptive(key: ValueKey('mirror-off'), value: null, title: Text('Not on a calendar')),
                    for (final c in choices) RadioListTile<String?>.adaptive(key: ValueKey('mirror-${c.key}'), value: c.key.startsWith('caldav:') || c.key.startsWith('phone:') ? c.key : 'caldav:${c.key}', title: Text.verbatim(c.name)),
                  ]),
                ),
              SwitchListTile.adaptive(
                key: const ValueKey('mirror-only-auto'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Only the tasks that were made by an automation or found in a note'),
                value: mirror.onlyAuto,
                onChanged: mirror.target == null ? null : mirror.setOnlyAuto,
              ),
              if (mirror.problem != null) Text.verbatim(mirror.problem!, key: const ValueKey('mirror-problem'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    ),
  );
}
