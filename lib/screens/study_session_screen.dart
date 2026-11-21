import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_math_fork/flutter_math.dart' show Math;

import '../algebra/mistake_card.dart';
import '../data/card_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/study_material.dart';
import '../review/study_planner.dart';
import '../review/study_schedule.dart';
import 'review_view.dart';
import 'study_plan_screen.dart';

/// Opens the note [noteId] at [page] (null: where it was left).
typedef OpenNoteAt = void Function(String noteId, int? page);

String _clock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// The page of the note where [item] begins (null: the part has no pages, a section of the written document).
int? pageOf(SessionItem item, StudyUnit unit) => unit.hasPages ? unit.fromPage! + (item.from * unit.pageCount).floor().clamp(0, unit.pageCount - 1) : null;

/// Opens the session [sessionKey] of the plan [planId].
Future<void> openStudySession(BuildContext context, StudyPlanner planner, String planId, String sessionKey,
        {CardRepository? cards, OpenNoteAt? onOpenNoteAt, DateTime Function()? clock}) =>
    Navigator.push(
      context,
      MaterialPageRoute<void>(
          builder: (_) => StudySessionScreen(planner: planner, planId: planId, sessionKey: sessionKey, cards: cards, onOpenNoteAt: onOpenNoteAt, clock: clock)),
    );

enum _Step { work, report, done }

/// A session of a study plan: what to do in it (each item opens its note at its page, or the review of the cards), a clock that can be
/// paused, and at the end how long it took, what was done and how it went. That is counted in the plan: the work done, the pace (how
/// long the person takes against the estimates) and the parts that felt hard or easy; the plan says when the rest should be made again.
class StudySessionScreen extends StatefulWidget {
  final StudyPlanner planner;
  final String planId, sessionKey;

  /// The flashcards (null: the cards of a session cannot be reviewed from here).
  final CardRepository? cards;

  /// Opens a note at a page (null: the items have no button to open their note).
  final OpenNoteAt? onOpenNoteAt;
  final DateTime Function()? clock;

  const StudySessionScreen({super.key, required this.planner, required this.planId, required this.sessionKey, this.cards, this.onOpenNoteAt, this.clock});

  @override
  State<StudySessionScreen> createState() => _StudySessionScreenState();
}

class _StudySessionScreenState extends State<StudySessionScreen> {
  Timer? _tick;
  _Step _step = _Step.work;
  final _minutes = TextEditingController();
  Set<int> _done = {};
  SessionFeeling _feeling = SessionFeeling.fine;
  bool _saving = false;
  List<StudyUnit> _changed = const [];

  StudyPlanner get _planner => widget.planner;
  DateTime _now() => (widget.clock ?? DateTime.now)();

  RunningSession? get _mine {
    final r = _planner.running;
    return r != null && r.planId == widget.planId && r.key == widget.sessionKey ? r : null;
  }

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _mine != null && !_mine!.paused) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _check(int i, bool on) async {
    if (_mine == null) await _planner.begin(widget.planId, widget.sessionKey);
    await _planner.check(i, on);
  }

  void _openNote(String noteId, int? page) {
    Navigator.pop(context); // (the clock goes on: the session is found again on the dashboard)
    widget.onOpenNoteAt!(noteId, page);
  }

  Future<void> _reviewCards(StudyPlanEntry plan) async {
    if (_mine == null) await _planner.begin(widget.planId, widget.sessionKey);
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ReviewScreen(cards: widget.cards!, sources: plan.cardSources, clock: widget.clock)));
  }

  /// The maths mistakes of [unit] to do again; one of them can open its page (the session's screen is left, as for a note).
  Future<void> _mistakes(StudyUnit unit) async {
    if (_mine == null) await _planner.begin(widget.planId, widget.sessionKey);
    final cards = await _planner.mistakesOf(unit);
    if (!mounted) return;
    final open = await Navigator.push<int?>(
        context, MaterialPageRoute(builder: (_) => _MistakesPage(title: unit.title, mistakes: cards, canOpen: widget.onOpenNoteAt != null)));
    if (open != null && mounted) _openNote(unit.noteId, open);
  }

  Future<void> _quiz(StudyUnit unit) async {
    if (_mine == null) await _planner.begin(widget.planId, widget.sessionKey);
    final facts = await _planner.factsOf(unit);
    if (!mounted) return;
    if (facts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('There is nothing to make a quiz of now: it needs facts of this part in a knowledge graph, and an AI model.')));
      return;
    }
    await _planner.facts!.quiz(context, unit.title, facts, cards: widget.cards);
  }

  void _toReport(BookedSession s) {
    final r = _mine;
    _minutes.text = '${r == null ? s.session.minutes : (r.elapsed(_now()).inSeconds / 60).round().clamp(1, 24 * 60)}';
    _done = {...?r?.checked};
    setState(() => _step = _Step.report);
  }

  Future<void> _save() async {
    final spent = int.tryParse(_minutes.text.trim());
    if (spent == null || spent < 0) return;
    setState(() => _saving = true);
    final changed = await _planner.finish(widget.planId, widget.sessionKey, SessionReport(spent: spent, done: _done, feeling: _feeling));
    if (!mounted) return;
    setState(() {
      _saving = false;
      _changed = changed;
      _step = _Step.done;
    });
  }

  Future<void> _replan(StudyPlanEntry plan) async {
    final proposal = await _planner.propose(plan);
    if (!mounted) return;
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => StudyProposalPage(planner: _planner, proposal: proposal)));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _planner,
        builder: (context, _) {
          final found = _planner.find(widget.planId, widget.sessionKey);
          if (found == null) {
            return Scaffold(
              appBar: AppBar(),
              body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('This session is not part of a plan any more.', textAlign: TextAlign.center))),
            );
          }
          final (:plan, :session) = found;
          return Scaffold(
            appBar: AppBar(title: Text.verbatim(session.title, maxLines: 2)),
            body: ListView(
              key: const ValueKey('session-list'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: switch (_step) {
                _Step.work => session.report != null ? _reported(context, session) : _work(context, plan, session),
                _Step.report => _report(context, plan, session),
                _Step.done => _summary(context, plan, session),
              },
            ),
          );
        },
      );

  Widget _when(BuildContext context, BookedSession s) {
    final l = MaterialLocalizations.of(context);
    String time(DateTime t) => l.formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
    return Text.verbatim('${l.formatMediumDate(s.session.start)}, ${time(s.session.start)} - ${time(s.session.end)}',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant));
  }

  List<Widget> _work(BuildContext context, StudyPlanEntry plan, BookedSession s) {
    final r = _mine;
    final other = _planner.running != null && r == null;
    final scheme = Theme.of(context).colorScheme;
    return [
      _when(context, s),
      const SizedBox(height: 16),
      Center(
        child: Text.verbatim(
          _clock(r?.elapsed(_now()) ?? Duration.zero),
          key: const ValueKey('session-clock'),
          style: Theme.of(context).textTheme.displayMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], color: r?.paused == true ? scheme.outline : null),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 8, children: [
        if (r == null)
          FilledButton.icon(
              key: const ValueKey('session-start'), onPressed: () => _planner.begin(widget.planId, widget.sessionKey), icon: const Icon(Icons.play_arrow), label: Text('Start the session'))
        else if (r.paused)
          FilledButton.tonalIcon(key: const ValueKey('session-resume'), onPressed: () => _planner.pause(false), icon: const Icon(Icons.play_arrow), label: Text('Go on'))
        else
          OutlinedButton.icon(key: const ValueKey('session-pause'), onPressed: () => _planner.pause(true), icon: const Icon(Icons.pause), label: Text('Pause')),
        FilledButton.icon(key: const ValueKey('session-finish'), onPressed: () => _toReport(s), icon: const Icon(Icons.flag_outlined), label: Text('Finish')),
      ]),
      if (other) ...[
        const SizedBox(height: 8),
        Text('Another session is running. Starting this one stops its clock.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
      ],
      const SizedBox(height: 16),
      for (final (i, item) in s.session.items.indexed) _item(context, plan, i, item, r?.checked.contains(i) ?? false),
    ];
  }

  Widget _item(BuildContext context, StudyPlanEntry plan, int i, SessionItem item, bool checked) {
    final unit = item.unitId == null ? null : plan.unit(item.unitId!);
    Widget? action;
    if (unit != null && widget.onOpenNoteAt != null && (item.kind == WorkKind.learn || item.kind == WorkKind.review)) {
      action = IconButton(
          key: ValueKey('session-open-$i'), tooltip: tr('Open the note'), icon: const Icon(Icons.open_in_new), onPressed: () => _openNote(unit.noteId, pageOf(item, unit)));
    } else if (item.kind == WorkKind.cards && widget.cards != null) {
      action = IconButton(key: ValueKey('session-cards-$i'), tooltip: tr('Review the cards'), icon: const Icon(Icons.style_outlined), onPressed: () => _reviewCards(plan));
    } else if (item.kind == WorkKind.mistakes && unit != null) {
      action = IconButton(key: ValueKey('session-mistakes-$i'), tooltip: tr('Show the lines'), icon: const Icon(Icons.edit_note), onPressed: () => _mistakes(unit));
    } else if (item.kind == WorkKind.quiz && unit != null && _planner.facts != null) {
      action = IconButton(key: ValueKey('session-quiz-$i'), tooltip: tr('Start the quiz'), icon: const Icon(Icons.quiz_outlined), onPressed: () => _quiz(unit));
    }
    return Row(children: [
      Expanded(
        child: CheckboxListTile(
          key: ValueKey('session-item-$i'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: checked,
          onChanged: (on) => _check(i, on ?? false),
          title: Text.verbatim(itemText(item, unit)),
          subtitle: Text.verbatim(trCount(item.minutes, '{n} minute', '{n} minutes')),
        ),
      ),
      ?action,
    ]);
  }

  List<Widget> _report(BuildContext context, StudyPlanEntry plan, BookedSession s) {
    final spent = int.tryParse(_minutes.text.trim());
    return [
      Text('How did it go?', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('session-minutes'),
        controller: _minutes,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: tr('Minutes studied'), border: const OutlineInputBorder()),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 16),
      Text('What did you get done?', style: Theme.of(context).textTheme.titleSmall),
      for (final (i, item) in s.session.items.indexed)
        CheckboxListTile(
          key: ValueKey('session-done-$i'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _done.contains(i),
          onChanged: (on) => setState(() => on == true ? _done.add(i) : _done.remove(i)),
          title: Text.verbatim(itemText(item, item.unitId == null ? null : plan.unit(item.unitId!))),
        ),
      const SizedBox(height: 16),
      Text('How hard was it?', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      SegmentedButton<SessionFeeling>(
        key: const ValueKey('session-feeling'),
        segments: [
          ButtonSegment(value: SessionFeeling.easy, label: Text('Easy', key: const ValueKey('session-feel-easy'))),
          ButtonSegment(value: SessionFeeling.fine, label: Text('As expected', key: const ValueKey('session-feel-fine'))),
          ButtonSegment(value: SessionFeeling.hard, label: Text('Hard', key: const ValueKey('session-feel-hard'))),
        ],
        selected: {_feeling},
        onSelectionChanged: (v) => setState(() => _feeling = v.first),
      ),
      const SizedBox(height: 8),
      Text('What you found easy or hard gets less or more time when the plan is made again.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 24),
      Wrap(alignment: WrapAlignment.end, spacing: 12, runSpacing: 8, children: [
        TextButton(onPressed: () => setState(() => _step = _Step.work), child: Text('Back')),
        FilledButton(key: const ValueKey('session-save'), onPressed: _saving || spent == null || spent < 0 ? null : _save, child: Text('Save')),
      ]),
    ];
  }

  List<Widget> _summary(BuildContext context, StudyPlanEntry plan, BookedSession s) {
    final report = s.report;
    final attention = _planner.attentionOf(plan.id);
    final pace = attention.pace;
    final lines = [
      if (report != null) tr('{done} of {all} done, in {n} minutes.', {'done': report.done.length, 'all': s.session.items.length, 'n': report.spent}),
      for (final u in _changed)
        _feeling == SessionFeeling.hard ? tr('"{part}" now counts as harder.', {'part': u.title}) : tr('"{part}" now counts as easier.', {'part': u.title}),
      if (pace != null && pace > 1) tr('You take about {n} % longer than the plan expected.', {'n': ((pace - 1) * 100).round()}),
      if (pace != null && pace < 1) tr('You are about {n} % quicker than the plan expected.', {'n': ((1 - pace) * 100).round()}),
      if (s.unfinished) tr('What was left goes into the next sessions when the plan is made again.'),
    ];
    final replan = attention.unfinished > 0 || pace != null || _changed.isNotEmpty;
    return [
      Text('Session saved', key: const ValueKey('session-saved'), style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text.verbatim(l)),
      const SizedBox(height: 16),
      Wrap(alignment: WrapAlignment.end, spacing: 12, runSpacing: 8, children: [
        TextButton(key: const ValueKey('session-close'), onPressed: () => Navigator.pop(context), child: Text('Close')),
        if (replan) FilledButton(key: const ValueKey('session-replan'), onPressed: () => _replan(plan), child: Text('Make the plan again')),
      ]),
    ];
  }

  List<Widget> _reported(BuildContext context, BookedSession s) {
    final r = s.report!;
    return [
      _when(context, s),
      const SizedBox(height: 16),
      Text.verbatim(tr('{done} of {all} done, in {n} minutes.', {'done': r.done.length, 'all': s.session.items.length, 'n': r.spent}), key: const ValueKey('session-reported')),
      const SizedBox(height: 8),
      for (final (i, item) in s.session.items.indexed)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(r.done.contains(i) ? Icons.check_circle : Icons.radio_button_unchecked),
          title: Text.verbatim(itemText(item, item.unitId == null ? null : _planner.find(widget.planId, widget.sessionKey)?.plan.unit(item.unitId!))),
        ),
    ];
  }
}

/// On the dashboard: the study session of today that comes next, or the one being studied, with a button to open it.
class StudySessionCard extends StatefulWidget {
  final StudyPlanner planner;
  final CardRepository? cards;
  final OpenNoteAt? onOpenNoteAt;
  final DateTime Function()? clock;

  const StudySessionCard({super.key, required this.planner, this.cards, this.onOpenNoteAt, this.clock});

  @override
  State<StudySessionCard> createState() => _StudySessionCardState();
}

class _StudySessionCardState extends State<StudySessionCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // (the minutes of a running session, and a session that comes into today or goes by)
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.planner,
        builder: (context, _) {
          final found = widget.planner.current();
          if (found == null) return const SizedBox.shrink();
          final (:plan, :session) = found;
          final running = widget.planner.running;
          final mine = running != null && running.planId == plan.id && running.key == session.key;
          final now = (widget.clock ?? DateTime.now)();
          final l = MaterialLocalizations.of(context);
          final at = l.formatTimeOfDay(TimeOfDay.fromDateTime(session.session.start), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              key: const ValueKey('study-session-card'),
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.school_outlined),
                title: Text.verbatim(session.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text.verbatim(mine
                    ? (running.paused ? tr('Paused after {n} min', {'n': running.elapsed(now).inMinutes}) : tr('Studying for {n} min', {'n': running.elapsed(now).inMinutes}))
                    : tr('Today at {time}, {n} min', {'time': at, 'n': session.session.minutes})),
                trailing: FilledButton.tonal(
                  key: const ValueKey('study-session-open'),
                  onPressed: () => openStudySession(context, widget.planner, plan.id, session.key, cards: widget.cards, onOpenNoteAt: widget.onOpenNoteAt, clock: widget.clock),
                  child: Text(mine ? 'Go on' : 'Open'),
                ),
              ),
            ),
          );
        },
      );
}

/// The lines of maths of a part that were found wrong, to work again: each line, and on demand what was wrong with it. Closes with the
/// page of a line when it is to be opened.
class _MistakesPage extends StatefulWidget {
  final String title;
  final List<ReviewCard> mistakes;
  final bool canOpen;

  const _MistakesPage({required this.title, required this.mistakes, required this.canOpen});

  @override
  State<_MistakesPage> createState() => _MistakesPageState();
}

class _MistakesPageState extends State<_MistakesPage> {
  final _shown = <int>{};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text.verbatim(widget.title, maxLines: 2)),
      body: widget.mistakes.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('There are no mistakes left to do again here.', key: const ValueKey('mistakes-none'), textAlign: TextAlign.center)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text('Work each line again without looking, then check what was wrong.', style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                for (final (i, m) in widget.mistakes.indexed)
                  Card(
                    key: ValueKey('mistake-$i'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Math.tex(mistakeLineOf(m.card.front), textStyle: const TextStyle(fontSize: 18), onErrorFallback: (_) => Text.verbatim(mistakeLineOf(m.card.front))),
                        ),
                        if (_shown.contains(i)) ...[
                          const SizedBox(height: 8),
                          Text.verbatim(m.card.back, key: ValueKey('mistake-back-$i')),
                        ],
                        const SizedBox(height: 4),
                        Wrap(spacing: 8, children: [
                          if (!_shown.contains(i))
                            TextButton(key: ValueKey('mistake-show-$i'), onPressed: () => setState(() => _shown.add(i)), child: Text('What was wrong?')),
                          if (widget.canOpen && m.card.page != null)
                            TextButton.icon(
                              key: ValueKey('mistake-open-$i'),
                              onPressed: () => Navigator.pop(context, m.card.page),
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: Text.verbatim(tr('Open page {n}', {'n': m.card.page! + 1})),
                            ),
                        ]),
                      ]),
                    ),
                  ),
              ],
            ),
    );
  }
}
