import 'package:flutter/material.dart' hide Text;

import '../data/card_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/study_material.dart';
import '../widgets/paper.dart';
import '../review/study_planner.dart';
import '../review/study_schedule.dart';
import '../review/study_progress.dart';
import 'study_progress_widgets.dart';
import 'study_session_screen.dart';

String _clock(BuildContext context, DateTime t) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));

String _length(int minutes) => minutes < 90 ? trCount(minutes, '{n} minute', '{n} minutes') : tr('{n} hours', {'n': (minutes / 60).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')});

/// The surfaces of the plan are ruled, not boxed: no ground, a hairline under (or around the top and bottom of) the rows.
Card _flat(BuildContext context, {Key? key, EdgeInsetsGeometry margin = EdgeInsets.zero, bool top = false, bool bottom = false, Color? color, required Widget child}) {
  final line = BorderSide(color: Theme.of(context).colorScheme.outlineVariant);
  return Card(key: key, elevation: 0, margin: margin, color: color ?? Colors.transparent, clipBehavior: Clip.antiAlias, shape: Border(top: top ? line : BorderSide.none, bottom: bottom ? line : BorderSide.none), child: child);
}

/// A plan as a whole: how far it is, its parts with their progress and summaries, and every session by day (done, missed, to come).
class StudyPlanDetail extends StatefulWidget {
  final StudyPlanner planner;
  final String planId;
  final DateTime Function()? clock;
  final OpenNoteAt? onOpenNoteAt;
  final CardRepository? cards;

  /// Set when the page is shown inside a tab: the back button then calls this instead of closing a page.
  final VoidCallback? onBack;

  const StudyPlanDetail({super.key, required this.planner, required this.planId, this.clock, this.onOpenNoteAt, this.cards, this.onBack});

  @override
  State<StudyPlanDetail> createState() => _StudyPlanDetailState();
}

enum _Tab { overview, parts, sessions }

class _StudyPlanDetailState extends State<StudyPlanDetail> {
  _Tab _tab = _Tab.overview;

  StudyPlanner get planner => widget.planner;
  String get planId => widget.planId;
  DateTime Function()? get clock => widget.clock;
  OpenNoteAt? get onOpenNoteAt => widget.onOpenNoteAt;
  CardRepository? get cards => widget.cards;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: planner,
        builder: (context, _) {
          final e = planner.plans.where((p) => p.id == planId).firstOrNull;
          if (e == null) return Scaffold(appBar: AppBar(leading: widget.onBack == null ? null : BackButton(onPressed: widget.onBack)), body: const SizedBox());
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
    final byDay = <DateTime, List<BookedSession>>{};
    for (final s in sessions) {
      byDay.putIfAbsent(DateTime(s.session.start.year, s.session.start.month, s.session.start.day), () => []).add(s);
    }
    final today = DateTime(now.year, now.month, now.day);
    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack == null ? null : BackButton(onPressed: widget.onBack),
        title: Text.verbatim(e.name),
      ),
      body: ListView(key: const ValueKey('plan-detail'), padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        if (progress.next != null) _nextUp(context, e, progress.next!, now),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<_Tab>(
            key: const ValueKey('plan-tabs'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: _Tab.overview, label: Text('Overview', key: const ValueKey('plan-tab-overview')), icon: const Icon(Icons.insights_outlined)),
              ButtonSegment(value: _Tab.parts, label: Text.verbatim('${tr('Parts')} (${parts.length})', key: const ValueKey('plan-tab-parts')), icon: const Icon(Icons.view_agenda_outlined)),
              ButtonSegment(value: _Tab.sessions, label: Text.verbatim('${tr('Sessions')} (${sessions.length})', key: const ValueKey('plan-tab-sessions')), icon: const Icon(Icons.event_note_outlined)),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
        ),
        const SizedBox(height: 12),
        if (_tab == _Tab.overview) ...[
          _hero(context, e, progress, days, done, sessions.length, left, now),
          if (parts.isNotEmpty) _standing(context, e, parts),
          if (parts.isNotEmpty) _focus(context, e, parts),
          _today(context, e, sessions, now, today),
          if (sessions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: WeekStrip(sessions: sessions, today: today)),
          if (curve.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _flat(
                context,
                child: Padding(padding: const EdgeInsets.fromLTRB(0, 12, 0, 8), child: ProgressDiagram(points: curve, today: today, exam: DateTime(e.exam.year, e.exam.month, e.exam.day), workAt: (d) => workAround(e, now, d))),
              ),
            ),
          if (sessions.isEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: Text('There are no sessions yet. Approve the plan to get them.', key: const ValueKey('plan-detail-no-sessions'))),
        ],
        if (_tab == _Tab.parts) ...[
          if (parts.isEmpty) Text('This plan has no parts: it goes by the flashcards.'),
          for (final u in parts) _part(context, e, u),
        ],
        if (_tab == _Tab.sessions) ...[
          if (sessions.isEmpty) Text('There are no sessions yet. Approve the plan to get them.'),
          for (final d in byDay.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Text.verbatim(l.formatFullDate(d.key), style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w500)),
            ),
            for (final s in d.value) _session(context, e, s, now),
          ],
        ],
      ]),
    );
  }

  Widget _hero(BuildContext context, StudyPlanEntry e, PlanProgress progress, int days, int done, int all, int left, DateTime now) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = MaterialLocalizations.of(context);
    final studied = studiedMinutes(e);
    final color = switch (progress.pace) { PlanPace.behind => scheme.tertiary, _ => scheme.primary };
    final facts = [
      tr('{done} of {all} sessions done', {'done': done, 'all': all}),
      if (studied > 0) tr('{time} studied', {'time': _length(studied)}),
      tr('{time} still to study', {'time': _length(left)}),
    ];
    return _flat(
      context,
      key: const ValueKey('plan-progress'),
      bottom: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 20),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (progress.hasParts) ...[ReadinessRing(value: progress.readiness, marker: progress.planned, color: color), const SizedBox(width: 16)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.verbatim(days == 0 ? tr('The exam is today') : trCount(days, '{n} day to go', '{n} days to go'), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w300)),
              Text.verbatim(l.formatFullDate(e.exam), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              if (progress.hasParts)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Flexible(child: Text.verbatim(PlanProgressBlock.paceText(progress), key: const ValueKey('plan-pace'), style: theme.textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w500))),
                  ]),
                ),
              const SizedBox(height: 6),
              Text.verbatim(facts.join('  ·  '), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _section(BuildContext context, String title, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(top: 28, bottom: 10),
        child: Row(children: [
          Expanded(child: Text.verbatim(title, style: PaperSection.style(context))),
          ?trailing,
        ]),
      );

  /// How many parts are not started, being learnt, learnt but to go over, and done: one bar split in four, with the counts below it.
  Widget _standing(BuildContext context, StudyPlanEntry e, List<StudyUnit> parts) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final count = {for (final s in PartStanding.values) s: parts.where((u) => partStanding(e.progress[u.id]) == s).length};
    final colors = {
      PartStanding.notStarted: scheme.surfaceContainerHighest,
      PartStanding.learning: scheme.primary.withValues(alpha: 0.35),
      PartStanding.toGoOver: scheme.primary.withValues(alpha: 0.65),
      PartStanding.done: scheme.primary,
    };
    final names = {
      PartStanding.notStarted: tr('Not started'),
      PartStanding.learning: tr('Learning'),
      PartStanding.toGoOver: tr('To go over'),
      PartStanding.done: tr('Done'),
    };
    return Column(key: const ValueKey('plan-standing'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      _section(context, tr('Where the parts stand')),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 4,
          child: Row(children: [
            for (final s in PartStanding.values.reversed)
              if (count[s]! > 0) Expanded(flex: count[s]!, child: Container(color: colors[s])),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 20, runSpacing: 4, children: [
        for (final s in PartStanding.values.reversed)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: colors[s], shape: BoxShape.circle, border: s == PartStanding.notStarted ? Border.all(color: scheme.outlineVariant) : null)),
            const SizedBox(width: 6),
            Text.verbatim('${names[s]} (${count[s]})', style: theme.textTheme.bodySmall),
          ]),
      ]),
    ]);
  }

  /// The parts that need the most work, each with how far it is; a tap opens the parts.
  Widget _focus(BuildContext context, StudyPlanEntry e, List<StudyUnit> parts) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final focus = focusParts(e);
    if (focus.isEmpty) {
      return Column(key: const ValueKey('plan-focus'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        _section(context, tr('Focus on these')),
        Row(children: [Icon(Icons.emoji_events_outlined, color: scheme.primary), const SizedBox(width: 8), Expanded(child: Text('Every part is learnt and gone over.'))]),
      ]);
    }
    final names = {
      PartStanding.notStarted: tr('Not started'),
      PartStanding.learning: tr('Learning'),
      PartStanding.toGoOver: tr('To go over'),
      PartStanding.done: tr('Done'),
    };
    return Column(key: const ValueKey('plan-focus'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      _section(context, tr('Focus on these'), trailing: TextButton(onPressed: () => setState(() => _tab = _Tab.parts), child: Text('All parts'))),
      _flat(
        context,
        top: true,
        bottom: true,
        child: Column(children: [
          for (final (i, u) in focus.indexed) ...[
            if (i > 0) const Divider(height: 1),
            InkWell(
              onTap: () => setState(() => _tab = _Tab.parts),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text.verbatim(u.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge)),
                    Text.verbatim(names[partStanding(e.progress[u.id])]!, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ]),
                  const SizedBox(height: 6),
                  LayeredBar(value: e.progress[u.id]?.reviewed ?? 0, behind: e.progress[u.id]?.learned ?? 0, height: 3),
                ]),
              ),
            ),
          ],
        ]),
      ),
    ]);
  }

  /// What is on today.
  Widget _today(BuildContext context, StudyPlanEntry e, List<BookedSession> sessions, DateTime now, DateTime today) {
    final mine = [for (final s in sessions) if (!s.gone && (!s.skipped || s.credited) && DateUtils.isSameDay(s.session.start, today)) s];
    if (mine.isEmpty) return const SizedBox();
    return Column(key: const ValueKey('plan-today'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      _section(context, tr('Today')),
      for (final s in mine) _session(context, e, s, now),
    ]);
  }

  Widget _nextUp(BuildContext context, StudyPlanEntry e, BookedSession s, DateTime now) {
    final theme = Theme.of(context);
    final l = MaterialLocalizations.of(context);
    final scheme = theme.colorScheme;
    final running = planner.running?.key == s.key && planner.running?.planId == e.id;
    return Card(
      key: const ValueKey('plan-next-up'),
      elevation: 0,
      color: scheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
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
    return _flat(
      context,
      key: ValueKey('plan-part-${u.id}'),
      bottom: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 10, 4, 10),
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
    return _flat(
      context,
      key: ValueKey('plan-session-${s.key}'),
      bottom: true,
      child: InkWell(
        onTap: s.gone ? null : () => openStudySession(context, planner, e.id, s.key, cards: cards, onOpenNoteAt: onOpenNoteAt, clock: clock),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
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
