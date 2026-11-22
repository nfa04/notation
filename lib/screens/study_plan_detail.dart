import 'package:flutter/material.dart' hide Text;

import '../data/card_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/study_material.dart';
import '../review/study_planner.dart';
import '../review/study_schedule.dart';
import '../review/study_progress.dart';
import 'study_progress_widgets.dart';
import 'study_session_screen.dart';

String _clock(BuildContext context, DateTime t) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));

String _length(int minutes) => minutes < 90 ? trCount(minutes, '{n} minute', '{n} minutes') : tr('{n} hours', {'n': (minutes / 60).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')});

/// A plan as a whole: how far it is, its parts with their progress and summaries, and every session by day (done, missed, to come).
class StudyPlanDetail extends StatelessWidget {
  final StudyPlanner planner;
  final String planId;
  final DateTime Function()? clock;
  final OpenNoteAt? onOpenNoteAt;
  final CardRepository? cards;

  const StudyPlanDetail({super.key, required this.planner, required this.planId, this.clock, this.onOpenNoteAt, this.cards});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: planner,
        builder: (context, _) {
          final e = planner.plans.where((p) => p.id == planId).firstOrNull;
          if (e == null) return Scaffold(appBar: AppBar(), body: const SizedBox());
          return _body(context, e);
        },
      );

  Widget _body(BuildContext context, StudyPlanEntry e) {
    final now = (clock ?? DateTime.now)();
    final l = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final days = DateTime(e.exam.year, e.exam.month, e.exam.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    final progress = PlanProgress.of(e, now, current: planner.current()?.plan.id == e.id ? planner.current()!.session : null);
    final curve = PlanProgress.curve(e, now);
    final sessions = [...e.sessions]..sort((a, b) => a.session.start.compareTo(b.session.start));
    final done = sessions.where((s) => s.credited).length;
    final left = sessions.where((s) => !s.credited && s.session.end.isAfter(now)).fold<int>(0, (n, s) => n + s.session.minutes);
    final parts = e.units.where((u) => u.included).toList();
    final summaries = parts.where((u) => e.material.containsKey(u.id)).length;
    final byDay = <DateTime, List<BookedSession>>{};
    for (final s in sessions) {
      byDay.putIfAbsent(DateTime(s.session.start.year, s.session.start.month, s.session.start.day), () => []).add(s);
    }
    Widget chip(IconData icon, String text) => Chip(avatar: Icon(icon, size: 16), label: Text.verbatim(text), visualDensity: VisualDensity.compact);
    return Scaffold(
      appBar: AppBar(title: Text.verbatim(e.name)),
      body: ListView(key: const ValueKey('plan-detail'), padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Text.verbatim(
          days == 0
              ? tr('The exam is today')
              : trCount(days, '{n} day left: the exam is on {day}', '{n} days left: the exam is on {day}').replaceAll('{day}', l.formatMediumDate(e.exam)),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        const SizedBox(height: 12),
        PlanProgressBlock(progress: progress, barHeight: 10),
        if (sessions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: WeekStrip(sessions: sessions, today: DateTime(now.year, now.month, now.day))),
        if (curve.length > 1) Padding(padding: const EdgeInsets.only(top: 16), child: ProgressDiagram(points: curve, today: DateTime(now.year, now.month, now.day), workAt: (d) => workAround(e, now, d))),
        if (progress.next != null) _nextUp(context, e, progress.next!, now),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          chip(Icons.event_available_outlined, tr('{done} of {all} sessions done', {'done': done, 'all': sessions.length})),
          chip(Icons.timer_outlined, tr('{time} still to study', {'time': _length(left)})),
          chip(Icons.view_agenda_outlined, trCount(parts.length, '{n} part', '{n} parts')),
          if (summaries > 0) chip(Icons.summarize_outlined, trCount(summaries, '{n} summary', '{n} summaries')),
        ]),
        Padding(padding: const EdgeInsets.only(top: 16, bottom: 4), child: Text('Parts', style: theme.textTheme.titleSmall)),
        if (parts.isEmpty) Text('This plan has no parts: it goes by the flashcards.'),
        for (final u in parts) _part(context, e, u),
        Padding(padding: const EdgeInsets.only(top: 16, bottom: 4), child: Text('Sessions', style: theme.textTheme.titleSmall)),
        if (sessions.isEmpty) Text('There are no sessions yet. Approve the plan to get them.', key: const ValueKey('plan-detail-no-sessions')),
        for (final d in byDay.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: Text.verbatim(l.formatFullDate(d.key), style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
          ),
          for (final s in d.value) _session(context, e, s, now),
        ],
      ]),
    );
  }

  Widget _nextUp(BuildContext context, StudyPlanEntry e, BookedSession s, DateTime now) {
    final theme = Theme.of(context);
    final l = MaterialLocalizations.of(context);
    final scheme = theme.colorScheme;
    final running = planner.running?.key == s.key && planner.running?.planId == e.id;
    return Card(
      key: const ValueKey('plan-next-up'),
      color: scheme.primaryContainer,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(running ? 'Studying now' : 'Next up', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimaryContainer)),
              Text.verbatim(s.title, style: theme.textTheme.titleMedium?.copyWith(color: scheme.onPrimaryContainer)),
              Text.verbatim('${l.formatMediumDate(s.session.start)}, ${_clock(context, s.session.start)} · ${_length(s.session.minutes)}', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer)),
            ]),
          ),
          FilledButton(
            key: const ValueKey('plan-next-start'),
            onPressed: () => openStudySession(context, planner, e.id, s.key, cards: cards, onOpenNoteAt: onOpenNoteAt, clock: clock),
            child: Text(running ? 'Go on' : 'Start the session'),
          ),
        ]),
      ),
    );
  }

  Widget _partSessions(BuildContext context, StudyPlanEntry e, StudyUnit u) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = MaterialLocalizations.of(context);
    final rows = <(BookedSession, Set<WorkKind>)>[
      for (final s in [...e.sessions]..sort((a, b) => a.session.start.compareTo(b.session.start)))
        if (!s.gone && (!s.skipped || s.credited))
          if (s.session.items.where((i) => i.unitId == u.id).map((i) => i.kind).toSet() case final kinds when kinds.isNotEmpty) (s, kinds),
    ];
    if (rows.isEmpty) return const SizedBox();
    String kind(WorkKind k) => switch (k) {
          WorkKind.learn => tr('Learn'),
          WorkKind.review => tr('Go over'),
          WorkKind.quiz => tr('Quiz'),
          WorkKind.mistakes => tr('Mistakes'),
          _ => '',
        };
    return Padding(
      key: ValueKey('plan-part-sessions-${u.id}'),
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 6, runSpacing: 4, children: [
        for (final (s, kinds) in rows)
          ActionChip(
            key: ValueKey('plan-part-session-${u.id}-${s.key}'),
            visualDensity: VisualDensity.compact,
            avatar: Icon(s.credited ? Icons.check_circle : Icons.schedule, size: 16, color: s.credited ? scheme.primary : scheme.outline),
            label: Text.verbatim('${l.formatShortDate(s.session.start)}, ${_clock(context, s.session.start)} · ${kinds.map(kind).where((k) => k.isNotEmpty).join(', ')}', style: theme.textTheme.labelSmall),
            onPressed: () => openStudySession(context, planner, e.id, s.key, cards: cards, onOpenNoteAt: onOpenNoteAt, clock: clock),
          ),
      ]),
    );
  }

  Widget _part(BuildContext context, StudyPlanEntry e, StudyUnit u) {
    final theme = Theme.of(context);
    final p = e.progress[u.id];
    final points = e.material[u.id]?.points ?? const <String>[];
    final difficulty = switch (u.difficulty) { Difficulty.easy => tr('Easy'), Difficulty.medium => tr('Medium'), Difficulty.hard => tr('Hard') };
    return Card(
      key: ValueKey('plan-part-${u.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.verbatim(u.title, style: theme.textTheme.bodyLarge),
              Text.verbatim([if (u.hasPages) pagesTitle(u.fromPage!, u.toPage!), _length(u.learnMinutes), difficulty].join(' · '), style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              LayeredBar(value: (p?.reviewed ?? 0).clamp(0.0, p?.learned ?? 0), behind: p?.learned ?? 0, height: 6),
              const SizedBox(height: 2),
              Text.verbatim(
                p == null || p.learned == 0
                    ? tr('Not started')
                    : p.reviewed >= 0.99
                        ? tr('Learnt and gone over')
                        : p.learned >= 0.99
                            ? tr('Learnt, to be gone over')
                            : tr('{n} % learnt', {'n': (p.learned * 100).round()}),
                style: theme.textTheme.labelSmall,
              ),
              _partSessions(context, e, u),
            ]),
          ),
          if (points.isNotEmpty)
            IconButton(
              key: ValueKey('plan-summary-${u.id}'),
              tooltip: tr('Read the summary'),
              icon: const Icon(Icons.summarize_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StudySummaryPage(title: u.title, points: points))),
            ),
          if (onOpenNoteAt != null)
            IconButton(
              tooltip: tr('Open the note'),
              icon: const Icon(Icons.open_in_new),
              onPressed: () {
                Navigator.popUntil(context, (r) => r.isFirst);
                onOpenNoteAt!(u.noteId, u.fromPage);
              },
            ),
        ]),
      ),
    );
  }

  Widget _session(BuildContext context, StudyPlanEntry e, BookedSession s, DateTime now) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final past = s.session.end.isBefore(now);
    final (IconData, String, Color) state = s.credited
        ? (Icons.check_circle, tr('Done'), scheme.primary)
        : s.gone
            ? (Icons.event_busy_outlined, tr('Deleted in the calendar'), scheme.outline)
            : s.unfinished
                ? (Icons.timelapse, tr('Work left undone'), scheme.tertiary)
                : past
                    ? (Icons.error_outline, tr('Not ticked off'), scheme.error)
                    : (Icons.schedule, tr('To come'), scheme.outline);
    return Card(
      key: ValueKey('plan-session-${s.key}'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: s.credited ? scheme.surfaceContainerLow : scheme.surfaceContainerHigh,
      child: InkWell(
        onTap: s.gone ? null : () => openStudySession(context, planner, e.id, s.key, cards: cards, onOpenNoteAt: onOpenNoteAt, clock: clock),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2, right: 10), child: Icon(state.$1, size: 20, color: state.$3)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text.verbatim('${_clock(context, s.session.start)}-${_clock(context, s.session.end)} · ${state.$2}', style: theme.textTheme.labelLarge),
                for (final i in s.session.items) Text.verbatim('• ${itemText(i, i.unitId == null ? null : e.unit(i.unitId!))}', style: theme.textTheme.bodyMedium),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
