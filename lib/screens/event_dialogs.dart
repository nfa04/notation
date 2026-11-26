import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../sync/caldav_remote.dart';
import '../sync/repeat_rule.dart';
import '../sync/task_calendar_mirror.dart';
import '../style/platform_dialog.dart';

String _dateText(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
String _timeText(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Whether events of the calendar [key] can repeat, and can have people invited, as far as this app can write it (a phone calendar
/// is written through the phone's own calendar database, where the app sets neither).
bool calendarCanRepeat(String key) => !key.startsWith('phone:');
bool calendarCanInvite(String key) => !key.startsWith('phone:');

/// The text for an alarm [minutes] before the start.
String alarmLabel(int minutes) {
  if (minutes <= 0) return tr('At the start');
  if (minutes % 1440 == 0) return tr('{n} days before', {'n': minutes ~/ 1440});
  if (minutes % 60 == 0) return tr('{n} h before', {'n': minutes ~/ 60});
  return tr('{n} min before', {'n': minutes});
}

const _alarmChoices = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080];
const _weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
final _emailPattern = RegExp(r'^[^\s@,;:<>"]+@[^\s@,;:<>"]+\.[^\s@,;:<>"]+$');

/// Asks for the details of a new event on [day] and the calendar to put it in (one of [targets]); [save] writes it.
/// Shows what went wrong when [save] throws, and stays open.
///
/// With [existing] it changes that event instead: the fields start with its values and [save] is given the changed event. A
/// different calendar than the one it is in means the event is to be moved there (the caller does that). The notes are only asked
/// for when [existing] has them ([DayEvent.notes] is not null) or the event is new: an event whose notes are not known keeps them.
/// An event that repeats is changed as a whole series.
Future<bool> newEventDialog(
  BuildContext context, {
  required DateTime day,
  required List<CalendarInfo> targets,
  required Future<void> Function(CalendarInfo target, NewEvent event) save,
  DayEvent? existing,
}) async {
  final editing = existing != null;
  final title = TextEditingController(text: existing?.title ?? '');
  final notes = TextEditingController(text: existing?.notes ?? '');
  final location = TextEditingController(text: existing?.location ?? '');
  final link = TextEditingController(text: existing?.url ?? '');
  final invitee = TextEditingController();
  var allDay = existing?.allDay ?? false;
  var first = DateTime(day.year, day.month, day.day);
  var last = first;
  var from = const TimeOfDay(hour: 9, minute: 0);
  var to = const TimeOfDay(hour: 10, minute: 0);
  if (existing != null) {
    first = DateTime(existing.start.year, existing.start.month, existing.start.day);
    final end = existing.end ?? existing.start.add(allDay ? Duration.zero : const Duration(hours: 1));
    last = DateTime(end.year, end.month, end.day);
    if (!allDay) {
      from = TimeOfDay(hour: existing.start.hour, minute: existing.start.minute);
      to = TimeOfDay(hour: end.hour, minute: end.minute);
    }
  }
  var target = targets.firstWhere((t) => t.key == existing?.calendarKey, orElse: () => targets.first);
  final showNotes = !editing || existing.notes != null;
  var alarms = [...?existing?.alarms];
  final attendees = [...?existing?.attendees];
  // the repeat: a rule the dialog can take apart, or one it cannot (kept as it is while the person does not change it)
  var rule = RepeatRule.parse(existing?.rrule);
  var customRepeat = existing?.rrule != null && existing!.rrule!.isNotEmpty && rule == null;
  final repeatEvery = TextEditingController(text: '${rule?.interval ?? 1}');
  final repeatCount = TextEditingController(text: '${rule?.count ?? 10}');
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
        final canRepeat = calendarCanRepeat(target.key);
        final canInvite = calendarCanInvite(target.key);
        final scheme = Theme.of(context).colorScheme;
        final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);

        void addInvitee() {
          final mail = invitee.text.trim();
          if (mail.isEmpty) return;
          if (!_emailPattern.hasMatch(mail)) {
            setLocal(() => problem = tr('Not a valid email address.'));
            return;
          }
          setLocal(() {
            problem = null;
            if (!attendees.any((a) => a.toLowerCase() == mail.toLowerCase())) attendees.add(mail);
            invitee.clear();
          });
        }

        Future<void> submit() async {
          if (title.text.trim().isEmpty || endBeforeStart || saving) return;
          if (invitee.text.trim().isNotEmpty && canInvite) addInvitee();
          if (problem != null && invitee.text.trim().isNotEmpty) return;
          setLocal(() {
            saving = true;
            problem = null;
          });
          try {
            final every = int.tryParse(repeatEvery.text.trim()) ?? 1;
            final count = int.tryParse(repeatCount.text.trim()) ?? 1;
            final written = rule?.copyWith(interval: every < 1 ? 1 : every, count: count < 1 ? 1 : count);
            await save(
              target,
              NewEvent(
                title: title.text.trim(),
                allDay: allDay,
                start: allDay ? first : at(first, from),
                end: allDay ? (last == first ? null : last) : at(last, to),
                description: notes.text.trim(),
                keepNotes: !showNotes,
                location: location.text.trim(),
                url: link.text.trim(),
                alarms: alarms,
                attendees: canInvite ? attendees : null,
                // (null: as it is: a rule the dialog does not know stays untouched; '' ends the repeat)
                rrule: !canRepeat || customRepeat ? null : (written == null ? '' : written.toRrule(allDay: allDay)),
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

        Widget section(IconData icon, Widget child) => Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 12, right: 12), child: Icon(icon, size: 20, color: scheme.onSurfaceVariant)),
                Expanded(child: child),
              ]),
            );

        String repeatChoice() => customRepeat ? 'custom' : (rule == null ? 'none' : rule!.frequency.name);
        void chooseRepeat(String v) {
          setLocal(() {
            customRepeat = v == 'custom';
            if (v == 'none' || v == 'custom') {
              rule = null;
              return;
            }
            final frequency = RepeatFrequency.values.byName(v);
            rule = (rule ?? const RepeatRule(frequency: RepeatFrequency.daily)).copyWith(
              frequency: frequency,
              weekdays: frequency == RepeatFrequency.weekly ? (rule?.weekdays.isNotEmpty == true ? rule!.weekdays : {first.weekday}) : <int>{},
            );
          });
        }

        final unit = {RepeatFrequency.daily: 'days', RepeatFrequency.weekly: 'weeks', RepeatFrequency.monthly: 'months', RepeatFrequency.yearly: 'years'};

        return PlatformAlertDialog(
          title: Text(editing ? 'Edit event' : 'New event'),
          content: SizedBox(
            width: 440,
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
                if (endBeforeStart) Text(tr('The event must end after it starts.'), style: TextStyle(color: scheme.error, fontSize: 12)),
                const SizedBox(height: 8),
                DropdownButtonFormField<CalendarInfo>(
                  key: const ValueKey('event-calendar'),
                  isExpanded: true,
                  initialValue: target,
                  decoration: InputDecoration(labelText: tr(editing ? 'Calendar (a different one moves the event)' : 'Calendar')),
                  items: [for (final t in targets) DropdownMenuItem(value: t, child: Text.verbatim(t.name, overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setLocal(() {
                    target = v ?? target;
                    if (!calendarCanRepeat(target.key)) {
                      rule = null;
                      customRepeat = false;
                    }
                  }),
                ),
                if (canRepeat)
                  section(
                    Symbols.repeat,
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      DropdownButtonFormField<String>(
                        key: const ValueKey('event-repeat'),
                        isExpanded: true,
                        initialValue: repeatChoice(),
                        decoration: InputDecoration(labelText: tr('Repeat')),
                        items: [
                          DropdownMenuItem(value: 'none', child: Text('Does not repeat')),
                          DropdownMenuItem(value: 'daily', child: Text('Every day')),
                          DropdownMenuItem(value: 'weekly', child: Text('Every week')),
                          DropdownMenuItem(value: 'monthly', child: Text('Every month')),
                          DropdownMenuItem(value: 'yearly', child: Text('Every year')),
                          if (customRepeat) DropdownMenuItem(value: 'custom', child: Text('Custom (as set in your calendar app)', overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) => chooseRepeat(v ?? 'none'),
                      ),
                      if (rule != null) ...[
                        Row(children: [
                          Text('Every'),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 56,
                            child: TextField(key: const ValueKey('event-repeat-every'), controller: repeatEvery, keyboardType: TextInputType.number, textAlign: TextAlign.center),
                          ),
                          const SizedBox(width: 8),
                          Text(unit[rule!.frequency]!),
                        ]),
                        if (rule!.frequency == RepeatFrequency.weekly)
                          Wrap(spacing: 4, children: [
                            for (var d = 1; d <= 7; d++)
                              FilterChip(
                                key: ValueKey('event-repeat-day-$d'),
                                label: Text(_weekdayShort[d - 1]),
                                selected: rule!.weekdays.contains(d),
                                onSelected: (on) => setLocal(() {
                                  final days = {...rule!.weekdays};
                                  if (on) {
                                    days.add(d);
                                  } else if (days.length > 1) {
                                    days.remove(d);
                                  }
                                  rule = rule!.copyWith(weekdays: days);
                                }),
                              ),
                          ]),
                        Row(children: [
                          Expanded(
                            child: DropdownButtonFormField<RepeatEnd>(
                              key: const ValueKey('event-repeat-end'),
                        isExpanded: true,
                              initialValue: rule!.end,
                              decoration: InputDecoration(labelText: tr('Ends')),
                              items: [
                                DropdownMenuItem(value: RepeatEnd.never, child: Text('Never')),
                                DropdownMenuItem(value: RepeatEnd.onDay, child: Text('On a day')),
                                DropdownMenuItem(value: RepeatEnd.afterCount, child: Text('After a number of times')),
                              ],
                              onChanged: (v) => setLocal(() => rule = rule!.copyWith(end: v, until: v == RepeatEnd.onDay ? (rule!.until ?? first.add(const Duration(days: 30))) : null)),
                            ),
                          ),
                          if (rule!.end == RepeatEnd.onDay)
                            TextButton(
                              key: const ValueKey('event-repeat-until'),
                              onPressed: () async {
                                final d = await showDatePicker(context: context, initialDate: rule!.until ?? first, firstDate: first, lastDate: DateTime(2100));
                                if (d != null) setLocal(() => rule = rule!.copyWith(until: d));
                              },
                              child: Text.verbatim(_dateText(rule!.until ?? first)),
                            ),
                          if (rule!.end == RepeatEnd.afterCount)
                            SizedBox(width: 56, child: TextField(key: const ValueKey('event-repeat-count'), controller: repeatCount, keyboardType: TextInputType.number, textAlign: TextAlign.center)),
                        ]),
                      ],
                      if (editing && (existing.repeats)) Padding(padding: const EdgeInsets.only(top: 4), child: Text('This changes every event of the series.', style: muted)),
                    ]),
                  ),
                section(
                  Symbols.notifications,
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(padding: const EdgeInsets.only(top: 12), child: Text('Reminders', style: muted)),
                    Wrap(spacing: 6, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      for (final m in alarms)
                        InputChip(
                          key: ValueKey('event-alarm-$m'),
                          label: Text.verbatim(alarmLabel(m)),
                          onDeleted: () => setLocal(() => alarms = [...alarms]..remove(m)),
                        ),
                      PopupMenuButton<int>(
                        key: const ValueKey('event-add-alarm'),
                        tooltip: tr('Add reminder'),
                        icon: const Icon(Symbols.add_alert, size: 20),
                        onSelected: (m) => setLocal(() {
                          if (!alarms.contains(m)) alarms = [...alarms, m]..sort();
                        }),
                        itemBuilder: (_) => [for (final m in _alarmChoices) if (!alarms.contains(m)) PopupMenuItem(value: m, child: Text.verbatim(alarmLabel(m)))],
                      ),
                    ]),
                  ]),
                ),
                section(Symbols.location_on, TextField(key: const ValueKey('event-location'), controller: location, decoration: InputDecoration(labelText: tr('Location')))),
                section(Symbols.link, TextField(key: const ValueKey('event-link'), controller: link, keyboardType: TextInputType.url, decoration: InputDecoration(labelText: tr('Link')))),
                if (canInvite)
                  section(
                    Symbols.group,
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('event-invitee'),
                            controller: invitee,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(labelText: tr('Invite people (email address)')),
                            onSubmitted: (_) => addInvitee(),
                          ),
                        ),
                        IconButton(key: const ValueKey('event-add-invitee'), icon: const Icon(Symbols.add), tooltip: tr('Add'), onPressed: addInvitee),
                      ]),
                      Wrap(spacing: 6, children: [
                        for (final a in attendees) InputChip(key: ValueKey('event-attendee-$a'), label: Text.verbatim(a), onDeleted: () => setLocal(() => attendees.remove(a))),
                      ]),
                      if (attendees.isNotEmpty) Text('The people are saved with the event. Whether they get an invitation depends on your calendar server.', style: muted),
                    ]),
                  ),
                if (showNotes) section(Symbols.notes, TextField(key: const ValueKey('event-notes'), controller: notes, minLines: 1, maxLines: 4, decoration: InputDecoration(labelText: tr('Notes')))),
                if (problem != null) ...[
                  const SizedBox(height: 8),
                  Text.verbatim(problem!, key: const ValueKey('event-problem'), style: TextStyle(color: scheme.error)),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('event-save'), onPressed: saving ? null : submit, child: Text(editing ? 'Save' : 'Add')),
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
