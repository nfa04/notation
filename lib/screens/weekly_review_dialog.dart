import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../reminders/reminder.dart';
import '../reminders/reminder_service.dart';
import '../review/weekly_review.dart';
import '../review/weekly_review_service.dart';
import '../style/platform_dialog.dart';

/// The next Sunday at [hour] o'clock (today when it is a Sunday before that hour).
DateTime nextSunday(DateTime now, {int hour = 18}) {
  final today = DateTime(now.year, now.month, now.day, hour);
  final days = (7 - now.weekday) % 7;
  final at = DateTime(now.year, now.month, now.day + days, hour);
  return at.isBefore(now) ? DateTime(today.year, today.month, today.day + 7, hour) : at;
}

/// Offers the weekly review: this week or the last one, with or without the assistant's summary, and a reminder every Sunday evening.
/// Makes the review and opens it with [onOpenNote].
Future<void> showWeeklyReview(BuildContext context, {required WeeklyReviewService service, ReminderService? reminders, required ValueChanged<String> onOpenNote}) async {
  final id = await showDialog<String>(context: context, builder: (context) => _ReviewDialog(service: service, reminders: reminders));
  if (id != null) onOpenNote(id);
}

class _ReviewDialog extends StatefulWidget {
  final WeeklyReviewService service;
  final ReminderService? reminders;

  const _ReviewDialog({required this.service, this.reminders});

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  bool _lastWeek = false;
  late bool _assistant = widget.service.assistantReady;
  bool _remind = false;
  bool _busy = false;
  String _status = '';
  String? _problem;
  String? _existing;
  String? _reminderId;

  WeeklyReviewService get _service => widget.service;
  DateTime get _week {
    final t = weekStart(_service.today);
    return _lastWeek ? DateTime(t.year, t.month, t.day - 7) : t;
  }

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _look() async {
    final existing = await _service.existing(_week);
    String? reminder;
    final r = widget.reminders;
    if (r != null) {
      for (final x in await r.reminders.all()) {
        if (x.kind == ReminderKind.review) reminder = x.id;
      }
    }
    if (mounted) {
      setState(() {
        _existing = existing;
        _reminderId = reminder;
        _remind = reminder != null;
      });
    }
  }

  Future<void> _make() async {
    setState(() {
      _busy = true;
      _problem = null;
      _status = tr('Gathering the week...');
    });
    try {
      final id = await _service.make(_week, withAssistant: _assistant, onStatus: (s) {
        if (mounted) setState(() => _status = s);
      });
      await _keepReminder();
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  /// Makes or takes away the reminder for Sunday evening to match the switch.
  Future<void> _keepReminder() async {
    final r = widget.reminders;
    if (r == null) return;
    if (_remind && _reminderId == null) {
      await r.ensurePermission();
      await r.reminders.add(kind: ReminderKind.review, title: tr('Weekly review'), at: nextSunday(DateTime.now()), repeat: Repeat.weekly);
    } else if (!_remind && _reminderId != null) {
      await r.reminders.remove(_reminderId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = MaterialLocalizations.of(context);
    final from = _week, to = DateTime(from.year, from.month, from.day + 6);
    return PlatformAlertDialog(
      title: const Text('Weekly review'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('A note about your week: what you wrote and what it says, the tasks, the week ahead, and old notes worth another look.', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
                showSelectedIcon: false,
              key: const ValueKey('review-week'),
              segments: [
                ButtonSegment(value: false, label: const Text('This week')),
                ButtonSegment(value: true, label: const Text('Last week')),
              ],
              selected: {_lastWeek},
              onSelectionChanged: _busy
                  ? null
                  : (s) {
                      setState(() => _lastWeek = s.first);
                      _look();
                    },
            ),
            Padding(padding: const EdgeInsets.only(top: 6), child: Text.verbatim('${l.formatMediumDate(from)} - ${l.formatMediumDate(to)}', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
            if (_existing != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('The review of this week was made before; making it again brings it up to date.', key: const ValueKey('review-exists'), style: TextStyle(fontSize: 12, color: scheme.primary))),
            SwitchListTile.adaptive(
              key: const ValueKey('review-assistant'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Have the assistant write a summary'),
              subtitle: _service.assistantReady ? null : (_service.aiEnabled?.call() ?? true)
                    ? const Text('Needs the assistant to be set up')
                    : const Text(
                        'The AI features are turned off in the settings',),
              value: _assistant && _service.assistantReady,
              onChanged: _busy || !_service.assistantReady ? null : (v) => setState(() => _assistant = v),
            ),
            if (widget.reminders != null)
              SwitchListTile.adaptive(
                key: const ValueKey('review-remind'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Remind me every Sunday evening'),
                value: _remind,
                onChanged: _busy ? null : (v) => setState(() => _remind = v),
              ),
            if (_busy) Padding(padding: const EdgeInsets.only(top: 8), child: Row(children: [const SizedBox(width: 18, height: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)), const SizedBox(width: 12),
                      Expanded(
                        child: Text.verbatim(_status, key: const ValueKey('review-status'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,))])),
            if (_problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_problem!, key: const ValueKey('review-problem'), style: TextStyle(color: scheme.error))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        if (_existing != null) TextButton(key: const ValueKey('review-open'), onPressed: _busy ? null : () => Navigator.pop(context, _existing), child: const Text('Open it')),
        FilledButton(key: const ValueKey('review-make'), onPressed: _busy ? null : _make, child: Text(_existing == null ? 'Make the review' : 'Make it again')),
      ],
    );
  }
}
