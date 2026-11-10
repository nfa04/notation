import 'package:flutter/material.dart' hide Text;

import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/study_plan.dart';
import '../review/study_planner.dart';
import '../style/platform_dialog.dart';

/// The plans for exams: each says how many days are left, what today's session is and whether the time is enough; a new one asks for the
/// exam, the cards (all, or those of a note) and the minutes a day. The sessions are tasks on the calendar.
class StudyPlanScreen extends StatelessWidget {
  final StudyPlanner planner;
  final NoteRepository repository;
  final DateTime Function()? clock;

  const StudyPlanScreen({super.key, required this.planner, required this.repository, this.clock});

  DateTime _now() => (clock ?? DateTime.now)();

  Future<void> _create(BuildContext context) async {
    final made = await showDialog<_NewPlan>(context: context, builder: (_) => _NewPlanDialog(planner: planner, repository: repository, today: _now()));
    if (made == null) return;
    await planner.create(name: made.name, source: made.source, exam: made.exam, minutes: made.minutes, daysOff: made.daysOff);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: planner,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: Text(tr('Plan for an exam'))),
          floatingActionButton: FloatingActionButton.extended(
            key: const ValueKey('new-study-plan'),
            onPressed: () => _create(context),
            icon: const Icon(Icons.add),
            label: Text(tr('New plan')),
          ),
          body: planner.plans.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr('Say when the exam is. The app works backwards from that day and puts a short session on each day of the calendar, and changes the sessions every day for what you got right.'),
                      key: const ValueKey('study-plans-empty'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(padding: const EdgeInsets.all(12), children: [for (final p in planner.plans) _card(context, p)]),
        ),
      );

  Widget _card(BuildContext context, StudyPlanEntry p) {
    final today = DateTime(_now().year, _now().month, _now().day);
    final days = p.exam.difference(today).inDays;
    return FutureBuilder<StudyPlan>(
      future: planner.planOf(p),
      builder: (context, snapshot) {
        final plan = snapshot.data;
        final todays = plan?.sessions.where((s) => s.day == today).firstOrNull;
        return Card(
          key: ValueKey('study-plan-${p.id}'),
          child: ListTile(
            isThreeLine: true,
            leading: const Icon(Icons.event_available_outlined),
            title: Text.verbatim(p.name),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.verbatim(days == 0
                  ? tr('The exam is today')
                  : trCount(days, '{n} day left: the exam is on {day}', '{n} days left: the exam is on {day}').replaceAll('{day}', dayKey(p.exam))),
              Text.verbatim(todays == null ? tr('No session today') : sessionTitle(p.name, todays), key: ValueKey('study-today-${p.id}')),
              if (plan != null && plan.unplanned > 0)
                Text.verbatim(
                  trCount(plan.unplanned, '{n} new card does not fit in the time: more minutes a day would help', '{n} new cards do not fit in the time: more minutes a day would help'),
                  key: ValueKey('study-warning-${p.id}'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ]),
            trailing: IconButton(
              key: ValueKey('study-remove-${p.id}'),
              tooltip: tr('Delete the plan and its sessions that are still to come'),
              icon: const Icon(Icons.delete_outline),
              onPressed: () => planner.remove(p.id),
            ),
          ),
        );
      },
    );
  }
}

class _NewPlan {
  final String name;
  final String? source;
  final DateTime exam;
  final int minutes;
  final Set<int> daysOff;

  const _NewPlan(this.name, this.source, this.exam, this.minutes, this.daysOff);
}

class _NewPlanDialog extends StatefulWidget {
  final StudyPlanner planner;
  final NoteRepository repository;
  final DateTime today;

  const _NewPlanDialog({required this.planner, required this.repository, required this.today});

  @override
  State<_NewPlanDialog> createState() => _NewPlanDialogState();
}

class _NewPlanDialogState extends State<_NewPlanDialog> {
  final _name = TextEditingController();
  late DateTime _exam = DateTime(widget.today.year, widget.today.month, widget.today.day + 14);
  double _minutes = 20;
  String? _source;
  final _off = <int>{};
  List<(String, String)> _sources = const [];

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    final counts = await widget.planner.sourceCounts();
    final out = <(String, String)>[];
    for (final e in counts.entries) {
      if (e.key.startsWith('anki:')) {
        out.add((e.key, '${e.key.substring(5)} (${e.value})'));
        continue;
      }
      final info = await widget.repository.noteInfo(e.key);
      if (info != null) out.add((e.key, '${info.title.isEmpty ? tr('Untitled') : info.title} (${e.value})'));
    }
    if (mounted) setState(() => _sources = out);
  }

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    return PlatformAlertDialog(
      title: Text(tr('New plan for an exam')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(key: const ValueKey('study-name'), controller: _name, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: tr('What is the exam?'), hintText: tr('Biology'))),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('study-exam-day'),
              icon: const Icon(Icons.calendar_today_outlined, size: 18),
              label: Text.verbatim('${tr('Exam on')} ${l.formatFullDate(_exam)}'),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _exam,
                  firstDate: DateTime(widget.today.year, widget.today.month, widget.today.day),
                  lastDate: DateTime(widget.today.year + 2),
                );
                if (picked != null) setState(() => _exam = picked);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              key: const ValueKey('study-source'),
              isExpanded: true,
              initialValue: _source,
              decoration: InputDecoration(labelText: tr('Which cards')),
              items: [
                DropdownMenuItem(value: null, child: Text(tr('All my cards'))),
                for (final (id, name) in _sources) DropdownMenuItem(value: id, child: Text.verbatim(name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _source = v),
            ),
            const SizedBox(height: 12),
            Text(trCount(_minutes.round(), '{n} minute a day', '{n} minutes a day')),
            Slider.adaptive(key: const ValueKey('study-minutes'), min: 5, max: 120, divisions: 23, value: _minutes, onChanged: (v) => setState(() => _minutes = v)),
            Text(tr('No session on')),
            Wrap(spacing: 6, children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  key: ValueKey('study-off-$d'),
                  label: Text.verbatim(l.narrowWeekdays[d % 7]),
                  selected: _off.contains(d),
                  onSelected: (on) => setState(() => on ? _off.add(d) : _off.remove(d)),
                ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(
          key: const ValueKey('study-create'),
          onPressed: _name.text.trim().isEmpty ? null : () => Navigator.pop(context, _NewPlan(_name.text.trim(), _source, _exam, _minutes.round(), {..._off})),
          child: Text(tr('Make the plan')),
        ),
      ],
    );
  }
}
