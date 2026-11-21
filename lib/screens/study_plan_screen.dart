import 'package:flutter/material.dart' hide Text;

import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/study_calendar.dart';
import '../review/study_material.dart';
import '../review/study_planner.dart';
import '../review/study_schedule.dart';
import '../review/study_topics.dart';
import '../ai/text_provider.dart' show AiCancel;
import '../style/platform_dialog.dart';
import '../sync/caldav_remote.dart';
import '../data/card_repository.dart';
import 'note_picker_dialog.dart';
import 'study_session_screen.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String _time(BuildContext context, DateTime t) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));

String _minutesOfDay(BuildContext context, int m) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay(hour: m ~/ 60, minute: m % 60), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));

String _hours(int minutes) =>
    minutes < 90 ? trCount(minutes, '{n} minute', '{n} minutes') : tr('{n} hours', {'n': (minutes / 60).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')});

/// The plans for exams: how far each is, its next session, and what wants it made again (missed sessions, a new event at the time of
/// one). A new plan is made on [StudyPlanSetup] and shown as a proposal ([StudyProposalPage]) before anything goes in the calendar.
class StudyPlanScreen extends StatelessWidget {
  final StudyPlanner planner;
  final NoteRepository repository;
  final DateTime Function()? clock;

  /// For the sessions' screen: the flashcards, and opening a note at a page.
  final CardRepository? cards;
  final OpenNoteAt? onOpenNoteAt;

  const StudyPlanScreen({super.key, required this.planner, required this.repository, this.clock, this.cards, this.onOpenNoteAt});

  DateTime _now() => (clock ?? DateTime.now)();

  void _create(BuildContext context) {
    final today = _day(_now());
    final draft = planner.draft(name: '', exam: DateTime(today.year, today.month, today.day + 14));
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StudyPlanSetup(planner: planner, repository: repository, entry: draft, isNew: true, clock: clock)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: planner,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: Text('Study plans')),
          floatingActionButton: FloatingActionButton.extended(
            key: const ValueKey('new-study-plan'),
            onPressed: () => _create(context),
            icon: const Icon(Icons.add),
            label: Text('New plan'),
          ),
          body: planner.plans.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Say what the exam is, when it is and what to study for it. The app cuts the material into parts, finds free times in your calendar and shows you the sessions. Nothing goes in your calendar until you approve it.',
                      key: const ValueKey('study-plans-empty'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  children: [
                    for (final p in planner.plans) _PlanCard(planner: planner, repository: repository, entry: p, now: _now(), clock: clock, cards: cards, onOpenNoteAt: onOpenNoteAt),
                  ],
                ),
        ),
      );
}

class _PlanCard extends StatelessWidget {
  final StudyPlanner planner;
  final NoteRepository repository;
  final StudyPlanEntry entry;
  final DateTime now;
  final DateTime Function()? clock;
  final CardRepository? cards;
  final OpenNoteAt? onOpenNoteAt;

  const _PlanCard({required this.planner, required this.repository, required this.entry, required this.now, this.clock, this.cards, this.onOpenNoteAt});

  Future<void> _again(BuildContext context) async {
    final proposal = await planner.propose(entry);
    if (!context.mounted) return;
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => StudyProposalPage(planner: planner, proposal: proposal)));
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: Text.verbatim(tr('Delete the plan "{name}"?', {'name': entry.name})),
        content: Text('The sessions that are still to come are taken off your calendar and your to-dos. What you did stays.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel')),
          FilledButton(key: const ValueKey('study-delete-confirm'), onPressed: () => Navigator.pop(context, true), child: Text('Delete')),
        ],
      ),
    );
    if (ok == true) await planner.remove(entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final days = entry.exam.difference(_day(now)).inDays;
    final next = entry.sessions.where((s) => s.session.start.isAfter(now) && !s.credited).firstOrNull;
    // the session to open: the one being studied or today's, else the next one
    final current = planner.current();
    final open = current != null && current.plan.id == entry.id ? current.session : next;
    final attention = planner.attentionOf(entry.id);
    final reasons = [
      if (attention.unbooked) tr('The sessions are not in your calendar yet.'),
      if (attention.missed > 0) trCount(attention.missed, '{n} session went by without being ticked off.', '{n} sessions went by without being ticked off.'),
      if (attention.clashes > 0) trCount(attention.clashes, '{n} session now clashes with an event.', '{n} sessions now clash with an event.'),
      if (attention.dropped > 0) trCount(attention.dropped, 'The to-do of {n} session was deleted.', 'The to-dos of {n} sessions were deleted.'),
      if (attention.unfinished > 0) trCount(attention.unfinished, '{n} session left work undone.', '{n} sessions left work undone.'),
      if (attention.removed > 0)
        trCount(attention.removed, '{n} session was deleted in your calendar: its time is kept free.', '{n} sessions were deleted in your calendar: their time is kept free.'),
      if ((attention.pace ?? 1) > 1) tr('You take about {n} % longer than the plan expected.', {'n': ((attention.pace! - 1) * 100).round()}),
      if ((attention.pace ?? 1) < 1) tr('You are about {n} % quicker than the plan expected.', {'n': ((1 - attention.pace!) * 100).round()}),
    ];
    return Card(
      key: ValueKey('study-plan-${entry.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text.verbatim(entry.name, style: Theme.of(context).textTheme.titleMedium)),
            PopupMenuButton<String>(
              key: ValueKey('study-menu-${entry.id}'),
              tooltip: tr('More'),
              onSelected: (v) {
                if (v == 'edit') {
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StudyPlanSetup(planner: planner, repository: repository, entry: entry, clock: clock)));
                } else if (v == 'again') {
                  _again(context);
                } else {
                  _delete(context);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(key: const ValueKey('study-edit'), value: 'edit', child: Text('Change the plan')),
                PopupMenuItem(key: const ValueKey('study-again'), value: 'again', child: Text('Make the plan again')),
                PopupMenuItem(key: ValueKey('study-remove-${entry.id}'), value: 'delete', child: Text('Delete')),
              ],
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.verbatim(days == 0
                  ? tr('The exam is today')
                  : trCount(days, '{n} day left: the exam is on {day}', '{n} days left: the exam is on {day}').replaceAll('{day}', l.formatMediumDate(entry.exam))),
              if (entry.units.any((u) => u.included)) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: entry.learned, minHeight: 6, borderRadius: BorderRadius.circular(3)),
                const SizedBox(height: 4),
                Text.verbatim(tr('{n} % of the material learnt', {'n': (entry.learned * 100).round()}), style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 6),
              Text.verbatim(
                next == null ? tr('No session to come') : tr('Next: {when}, {what}', {'when': '${l.formatMediumDate(next.session.start)} ${_time(context, next.session.start)}', 'what': next.title}),
                key: ValueKey('study-next-${entry.id}'),
              ),
              if (open != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: ValueKey('study-open-${entry.id}'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => openStudySession(context, planner, entry.id, open.key, cards: cards, onOpenNoteAt: onOpenNoteAt, clock: clock),
                    icon: const Icon(Icons.play_circle_outline),
                    label: Text.verbatim(planner.running?.key == open.key && planner.running?.planId == entry.id ? tr('Go on with the session') : tr('Open the session')),
                  ),
                ),
              if (reasons.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  key: ValueKey('study-attention-${entry.id}'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final r in reasons) Text.verbatim(r, style: TextStyle(color: scheme.onSecondaryContainer)),
                    const SizedBox(height: 6),
                    FilledButton.tonal(key: ValueKey('study-replan-${entry.id}'), onPressed: () => _again(context), child: Text('Make the plan again')),
                  ]),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// How the flashcards are part of a plan.
enum _Cards { notes, all, none }

/// What a plan is made of: the exam, the material (the notes, cut into parts that can be left out and said to be easy or hard), the
/// flashcards, the hours to study in and where the sessions go. "See the plan" shows the proposal; nothing is kept before it is approved.
class StudyPlanSetup extends StatefulWidget {
  final StudyPlanner planner;
  final NoteRepository repository;
  final StudyPlanEntry entry;
  final bool isNew;
  final DateTime Function()? clock;

  const StudyPlanSetup({super.key, required this.planner, required this.repository, required this.entry, this.isNew = false, this.clock});

  @override
  State<StudyPlanSetup> createState() => _StudyPlanSetupState();
}

class _StudyPlanSetupState extends State<StudyPlanSetup> {
  late final _name = TextEditingController(text: widget.entry.name);
  late StudyPlanEntry _e = widget.entry;
  late _Cards _cards = widget.isNew || (widget.entry.cardSources?.isNotEmpty ?? false) ? _Cards.notes : (widget.entry.cardSources == null ? _Cards.all : _Cards.none);
  Map<String, NoteSummary> _notes = const {};
  Map<String, int> _cardCounts = const {};
  List<CalendarInfo> _calendars = const [];
  List<CalendarPlace> _places = const [];
  bool _loaded = false, _busy = false;

  /// The note whose pages are being cut by topic, how far that is, and what stops it.
  String? _splitting;
  double? _splitDone;
  AiCancel? _splitCancel;

  DateTime get _today => _day((widget.clock ?? DateTime.now)());

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final notes = await widget.repository.listNotes();
    final counts = await widget.planner.sourceCounts();
    final cal = widget.planner.calendar;
    var calendars = const <CalendarInfo>[];
    try {
      calendars = await cal?.writable() ?? const [];
    } catch (_) {
      // no calendar to offer
    }
    if (!mounted) return;
    setState(() {
      _notes = {for (final n in notes) n.id: n};
      _cardCounts = counts;
      _calendars = calendars;
      _places = cal?.places ?? const [];
      _loaded = true;
      if (widget.isNew && _e.target.isNone) {
        final study = calendars.where((c) => c.name == tr('Study')).firstOrNull;
        _e = _e.copyWith(
          target: study != null
              ? CalendarTarget.calendar(study.key)
              : _places.isNotEmpty
                  ? CalendarTarget.makeAt(_places.first)
                  : const CalendarTarget.none(),
        );
      }
    });
  }

  List<String> get _noteIds => <String>{for (final u in _e.units) u.noteId}.toList();

  /// The notes whose cards are studied with "the cards of these notes": the plan's notes, or (for an old plan of cards only, which
  /// has no notes) the notes it took its cards from.
  Iterable<String> get _cardNotes => _noteIds.isNotEmpty ? _noteIds : (widget.entry.cardSources ?? const <String>{});

  Future<void> _addNote() async {
    final taken = _noteIds.toSet();
    final choices = [for (final n in _notes.values) if (!n.locked && !taken.contains(n.id)) n];
    final id = await showDialog<String>(context: context, builder: (_) => NotePickerDialog(notes: choices, title: tr('A note to study')));
    if (id == null) return;
    final units = await widget.planner.unitsOf(id);
    if (!mounted) return;
    if (units.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nothing to study was found in that note.')));
      return;
    }
    setState(() => _e = _e.copyWith(units: [..._e.units, ...units]));
  }

  bool _canSplit(String noteId) => (widget.planner.topics?.ready ?? false) && StudyTopicSplitter.canSplit(_e.units, noteId);

  /// Cuts the runs of pages of [noteId] by their topics (with the AI model); what was done of them is carried over page by page.
  Future<void> _split(String noteId) async {
    final topics = widget.planner.topics;
    if (topics == null) return;
    final cancel = AiCancel();
    setState(() {
      _splitting = noteId;
      _splitDone = null;
      _splitCancel = cancel;
    });
    try {
      final r = await topics.split(_e.units, _e.progress, noteId, cancel: cancel, onProgress: (d) {
        if (mounted) setState(() => _splitDone = d);
      });
      if (mounted) setState(() => _e = _e.copyWith(units: r.units, progress: r.progress));
    } catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text.verbatim('$err'.replaceFirst('Bad state: ', ''))));
    } finally {
      if (mounted) {
        setState(() {
          _splitting = null;
          _splitCancel = null;
        });
      }
    }
  }

  void _setUnit(StudyUnit u) => setState(() => _e = _e.copyWith(units: [for (final x in _e.units) x.id == u.id ? u : x]));

  Set<String>? get _cardSources => switch (_cards) { _Cards.all => null, _Cards.none => const {}, _Cards.notes => _cardNotes.toSet() };

  int _cardsOf(_Cards c) => switch (c) {
        _Cards.all => _cardCounts.values.fold(0, (n, v) => n + v),
        _Cards.none => 0,
        _Cards.notes => _cardNotes.fold(0, (n, id) => n + (_cardCounts[id] ?? 0)),
      };

  bool get _ready => _name.text.trim().isNotEmpty && (_e.units.any((u) => u.included) || _cardsOf(_cards) > 0) && _e.windowEnd > _e.windowStart && _e.daysOff.length < 7;

  Future<void> _see() async {
    setState(() => _busy = true);
    try {
      final draft = _e.copyWith(name: _name.text.trim(), cardSources: () => _cardSources);
      final proposal = await widget.planner.propose(draft);
      if (!mounted) return;
      final approved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => StudyProposalPage(planner: widget.planner, proposal: proposal)));
      if (approved == true && mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<int?> _pickTime(int minutes) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60));
    return t == null ? null : t.hour * 60 + t.minute;
  }

  /// The plan's calendar is a phone calendar of another device (this device's calendars are not it, whatever their names).
  late final bool _elsewhere = !widget.planner.writesCalendarOf(widget.entry);

  String _targetLabel(CalendarTarget t) {
    if (t.make == CalendarPlace.phone) return tr('A new "Study" calendar on this device');
    if (t.make == CalendarPlace.server) return tr('A new "Study" calendar on the calendar server');
    if (t.key == null) return tr('No calendar: to-dos only');
    if (_elsewhere && t.key == widget.entry.target.key) return tr('The calendar on your other device');
    return _calendars.where((c) => c.key == t.key).firstOrNull?.name ?? tr('The calendar chosen before');
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text.verbatim(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    final targets = <CalendarTarget>{
      for (final c in _calendars)
        if (!_elsewhere || c.key != widget.entry.target.key) CalendarTarget.calendar(c.key),
      for (final p in _places) CalendarTarget.makeAt(p),
      const CalendarTarget.none(),
      _e.target,
    }.toList();
    return Scaffold(
      appBar: AppBar(title: Text.verbatim(widget.isNew ? tr('New study plan') : tr('Change the plan'))),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(key: const ValueKey('study-setup-list'), padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                  TextField(
                    key: const ValueKey('study-name'),
                    controller: _name,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(labelText: tr('What is the exam?'), hintText: tr('Biology')),
                  ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(
                      key: const ValueKey('study-exam-day'),
                      icon: const Icon(Icons.calendar_today_outlined, size: 18),
                      label: Text.verbatim('${tr('Exam on')} ${l.formatMediumDate(_e.exam)}'),
                      onPressed: () async {
                        final picked = await showDatePicker(context: context, initialDate: _e.exam.isBefore(_today) ? _today : _e.exam, firstDate: _today, lastDate: DateTime(_today.year + 2));
                        if (picked != null) setState(() => _e = _e.copyWith(exam: picked));
                      },
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('study-exam-time'),
                      icon: const Icon(Icons.schedule, size: 18),
                      label: Text.verbatim(_e.examTime == null ? tr('At what time? (optional)') : tr('At {time}', {'time': _minutesOfDay(context, _e.examTime!)})),
                      onPressed: () async {
                        final t = await _pickTime(_e.examTime ?? 9 * 60);
                        if (t != null) setState(() => _e = _e.copyWith(examTime: () => t));
                      },
                    ),
                    if (_e.examTime != null)
                      IconButton(tooltip: tr('No time'), icon: const Icon(Icons.close), onPressed: () => setState(() => _e = _e.copyWith(examTime: () => null))),
                  ]),

                  _heading(tr('What to study')),
                  if (_e.units.isEmpty)
                    Text('Add the notes and PDFs for this exam. Each is cut into parts by its chapters and headings (or into runs of pages); leave out what is not needed and say what is hard.'),
                  for (final id in _noteIds) _noteBlock(id),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(key: const ValueKey('study-add-note'), onPressed: _addNote, icon: const Icon(Icons.add), label: Text('Add a note')),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<_Cards>(
                    key: const ValueKey('study-cards'),
                    isExpanded: true,
                    initialValue: _cards,
                    decoration: InputDecoration(labelText: tr('Flashcards')),
                    items: [
                      DropdownMenuItem(value: _Cards.notes, child: Text.verbatim(tr('The cards of these notes ({n})', {'n': _cardsOf(_Cards.notes)}))),
                      DropdownMenuItem(value: _Cards.all, child: Text.verbatim(tr('All my cards ({n})', {'n': _cardsOf(_Cards.all)}))),
                      DropdownMenuItem(value: _Cards.none, child: Text('No flashcards')),
                    ],
                    onChanged: (v) => setState(() => _cards = v ?? _cards),
                  ),

                  _heading(tr('When to study')),
                  Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
                    Text('Between'),
                    OutlinedButton(
                      key: const ValueKey('study-from'),
                      onPressed: () async {
                        final t = await _pickTime(_e.windowStart);
                        if (t != null) setState(() => _e = _e.copyWith(windowStart: t));
                      },
                      child: Text.verbatim(_minutesOfDay(context, _e.windowStart)),
                    ),
                    Text('and'),
                    OutlinedButton(
                      key: const ValueKey('study-until'),
                      onPressed: () async {
                        final t = await _pickTime(_e.windowEnd);
                        if (t != null) setState(() => _e = _e.copyWith(windowEnd: t));
                      },
                      child: Text.verbatim(_minutesOfDay(context, _e.windowEnd)),
                    ),
                  ]),
                  if (_e.windowEnd <= _e.windowStart) Text('The end has to be after the start.', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  Text('No study on'),
                  Wrap(spacing: 6, children: [
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        key: ValueKey('study-off-$d'),
                        label: Text.verbatim(l.narrowWeekdays[d % 7]),
                        selected: _e.daysOff.contains(d),
                        onSelected: (on) => setState(() => _e = _e.copyWith(daysOff: on ? {..._e.daysOff, d} : ({..._e.daysOff}..remove(d)))),
                      ),
                  ]),
                  const SizedBox(height: 8),
                  Text.verbatim(tr('At most {time} a day', {'time': _hours(_e.maxPerDay)})),
                  Slider.adaptive(
                    key: const ValueKey('study-max'),
                    min: 30,
                    max: 360,
                    divisions: 22,
                    value: _e.maxPerDay.clamp(30, 360).toDouble(),
                    onChanged: (v) => setState(() => _e = _e.copyWith(maxPerDay: v.round())),
                  ),
                  Text('Sessions of'),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, children: [
                    for (final m in const [25, 45, 60, 90])
                      ChoiceChip(
                        key: ValueKey('study-length-$m'),
                        label: Text.verbatim(trCount(m, '{n} minute', '{n} minutes')),
                        selected: _e.sessionLength == m,
                        onSelected: (_) => setState(() => _e = _e.copyWith(sessionLength: m)),
                      ),
                  ]),

                  _heading(tr('Where the sessions go')),
                  DropdownButtonFormField<CalendarTarget>(
                    key: const ValueKey('study-target'),
                    isExpanded: true,
                    initialValue: _e.target,
                    items: [for (final t in targets) DropdownMenuItem(value: t, child: Text.verbatim(_targetLabel(t), overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() => _e = _e.copyWith(target: v)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Each session is also a to-do. The events of the calendars shown in the app count as busy times.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const ValueKey('study-see'),
                    onPressed: _ready && !_busy ? _see : null,
                    icon: _busy ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.event_note_outlined),
                    label: Text('See the plan'),
                  ),
                ]),
              ),
            ),
    );
  }

  Widget _noteBlock(String noteId) {
    final units = [for (final u in _e.units) if (u.noteId == noteId) u];
    final title = _notes[noteId]?.shownTitle ?? tr('A note that is gone');
    final minutes = units.where((u) => u.included).fold<int>(0, (n, u) => n + u.learnMinutes);
    return Card(
      key: ValueKey('study-note-$noteId'),
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text.verbatim(title, style: Theme.of(context).textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis)),
            Text.verbatim(_hours(minutes), style: Theme.of(context).textTheme.bodySmall),
            if (_splitting == noteId)
              IconButton(
                key: ValueKey('study-split-stop-$noteId'),
                tooltip: tr('Stop'),
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: () => _splitCancel?.cancel(),
              )
            else if (_canSplit(noteId))
              IconButton(
                key: ValueKey('study-split-$noteId'),
                tooltip: tr('Cut the pages by their topics (with AI)'),
                icon: const Icon(Icons.auto_awesome_outlined),
                onPressed: _splitting == null ? () => _split(noteId) : null,
              ),
            IconButton(
              key: ValueKey('study-drop-note-$noteId'),
              tooltip: tr('Take this note out'),
              icon: const Icon(Icons.close),
              onPressed: _splitting == noteId ? null : () => setState(() => _e = _e.copyWith(units: [for (final u in _e.units) if (u.noteId != noteId) u])),
            ),
          ]),
          if (_splitting == noteId) Padding(padding: const EdgeInsets.only(right: 8, bottom: 4), child: LinearProgressIndicator(value: _splitDone)),
          for (final u in units)
            Row(key: ValueKey('study-unit-${u.id}'), children: [
              Checkbox(
                key: ValueKey('study-unit-on-${u.id}'),
                value: u.included,
                onChanged: (v) => _setUnit(u.copyWith(included: v ?? true)),
              ),
              Expanded(
                child: Text.verbatim(
                  u.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: u.included ? null : TextStyle(color: Theme.of(context).disabledColor),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text.verbatim(trCount(u.learnMinutes, '{n} min', '{n} min'), style: Theme.of(context).textTheme.bodySmall),
              ),
              DropdownButton<Difficulty>(
                key: ValueKey('study-unit-diff-${u.id}'),
                value: u.difficulty,
                underline: const SizedBox(),
                isDense: true,
                items: [
                  DropdownMenuItem(value: Difficulty.easy, child: Text('Easy')),
                  DropdownMenuItem(value: Difficulty.medium, child: Text('Medium')),
                  DropdownMenuItem(value: Difficulty.hard, child: Text('Hard')),
                ],
                onChanged: u.included ? (d) => _setUnit(u.copyWith(difficulty: d)) : null,
              ),
            ]),
        ]),
      ),
    );
  }
}

/// A plan as it would be, day by day among the events of the calendars: what is new, what changed, what is taken away, and what does not
/// fit. A session can be refused ("not at this time"); the plan is then made again around it. Approving it writes the sessions to the
/// calendar and the to-dos; until then nothing is changed. Pops with true once approved.
class StudyProposalPage extends StatefulWidget {
  final StudyPlanner planner;
  final StudyProposal proposal;

  const StudyProposalPage({super.key, required this.planner, required this.proposal});

  @override
  State<StudyProposalPage> createState() => _StudyProposalPageState();
}

class _StudyProposalPageState extends State<StudyProposalPage> {
  late StudyProposal _p = widget.proposal;
  bool _working = false;
  String _target = '';

  bool get _existing => widget.planner.plans.any((x) => x.id == _p.entry.id);

  @override
  void initState() {
    super.initState();
    _loadTarget();
  }

  Future<void> _loadTarget() async {
    final t = _p.entry.target;
    var name = '';
    if (t.make == CalendarPlace.phone) {
      name = tr('A new "Study" calendar on this device');
    } else if (t.make == CalendarPlace.server) {
      name = tr('A new "Study" calendar on the calendar server');
    } else if (t.key == null) {
      name = tr('No calendar: to-dos only');
    } else if (!widget.planner.writesCalendarOf(_p.entry)) {
      name = tr('The calendar on your other device');
    } else {
      try {
        name = (await widget.planner.calendar?.writable())?.where((c) => c.key == t.key).firstOrNull?.name ?? '';
      } catch (_) {}
      if (name.isEmpty) name = tr('Your calendar');
    }
    if (mounted) setState(() => _target = name);
  }

  Future<void> _refuse(PlannedSession s) async {
    setState(() => _working = true);
    try {
      final entry = _p.entry.copyWith(blocked: [..._p.entry.blocked, (start: s.start, end: s.end)]);
      final next = await widget.planner.propose(entry);
      if (mounted) setState(() => _p = next);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _approve() async {
    setState(() => _working = true);
    try {
      await widget.planner.approve(_p);
      if (!mounted) return;
      final problem = widget.planner.problem;
      if (problem != null) {
        await showDialog<void>(
          context: context,
          builder: (context) => PlatformAlertDialog(
            title: Text('Not everything could go in the calendar'),
            content: Text.verbatim('${tr('The to-dos are made. Making the plan again later tries the calendar again.')}\n\n$problem'),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text('OK'))],
          ),
        );
      }
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final s = _p.schedule;
    final e = _p.entry;
    final sessionMinutes = _p.sessions.fold<int>(0, (n, x) => n + x.session.minutes);
    final days = <DateTime>{
      for (final x in _p.sessions) _day(x.session.start),
      for (final x in _p.removed) _day(x.session.start), // (only sessions still to come are ever taken away)
    }.toList()
      ..sort();
    final unitNames = [for (final id in s.unitsLeftOver) e.unit(id)?.title ?? ''].where((t) => t.isNotEmpty).toList();
    final canApprove = !_existing || _p.hasChanges || e.target.make != null;
    return Scaffold(
      appBar: AppBar(title: Text.verbatim(tr('The plan for {name}', {'name': e.name}))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(key: const ValueKey('study-proposal-list'), padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
            Text.verbatim(
              trCount(_p.sessions.length, '{n} session, {time} in all, until {day}', '{n} sessions, {time} in all, until {day}')
                  .replaceAll('{time}', _hours(sessionMinutes))
                  .replaceAll('{day}', l.formatMediumDate(e.exam)),
              key: const ValueKey('study-summary'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (s.learnLeftOver > 0)
              _note(
                  'study-short',
                  tr('About {time} of learning does not fit before the exam ({parts}). More time a day, fewer days off or fewer parts would help.',
                      {'time': _hours(s.learnLeftOver), 'parts': unitNames.join(', ')}),
                  scheme.errorContainer,
                  scheme.onErrorContainer),
            if (s.learnLeftOver == 0 && s.reviewLeftOver > 0)
              _note('study-no-review', tr('There is not enough time to go over everything a second time ({time} short).', {'time': _hours(s.reviewLeftOver)}), scheme.tertiaryContainer,
                  scheme.onTertiaryContainer),
            if (!widget.planner.writesCalendarOf(e))
              _note('study-elsewhere', tr('The calendar of this plan is on another device: the sessions are put in it there, the next time the app is open on it.'),
                  scheme.surfaceContainerHighest, scheme.onSurface),
            if (_p.calendarUnread)
              _note('study-unread', tr('The calendars could not be read, so their events were not taken into account.'), scheme.tertiaryContainer, scheme.onTertiaryContainer),
            if (_existing && !_p.hasChanges) _note('study-unchanged', tr('Nothing changes.'), scheme.surfaceContainerHighest, scheme.onSurface),
            for (final d in days) ..._dayBlock(context, d),
          ]),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            Expanded(
              child: Text.verbatim(_target, key: const ValueKey('study-target-label'), maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(width: 12),
            FilledButton(
              key: const ValueKey('study-approve'),
              onPressed: _working ? null : (canApprove ? _approve : () => Navigator.pop(context, false)),
              child: _working
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text.verbatim(!canApprove ? tr('Close') : (_existing ? tr('Apply the changes') : (e.target.isNone ? tr('Add to my to-dos') : tr('Add to the calendar')))),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _note(String key, String text, Color background, Color foreground) => Container(
        key: ValueKey(key),
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
        child: Text.verbatim(text, style: TextStyle(color: foreground)),
      );

  List<Widget> _dayBlock(BuildContext context, DateTime day) {
    final l = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final rows = <(DateTime, Widget)>[];
    for (final ev in _p.events) {
      if (_day(ev.start) != day) continue;
      rows.add((
        ev.start,
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(width: 100, child: Text.verbatim('${_time(context, ev.start)}-${_time(context, ev.end ?? ev.start)}', style: theme.textTheme.bodySmall)),
            Expanded(child: Text.verbatim(ev.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor))),
          ]),
        ),
      ));
    }
    for (final x in _p.sessions) {
      if (_day(x.session.start) != day) continue;
      rows.add((x.session.start, _sessionCard(context, x)));
    }
    for (final x in _p.removed) {
      if (_day(x.session.start) != day) continue;
      rows.add((
        x.session.start,
        Padding(
          key: ValueKey('study-removed-${x.key}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 100, child: Text.verbatim('${_time(context, x.session.start)}-${_time(context, x.session.end)}', style: theme.textTheme.bodySmall)),
            Expanded(
              child: Text.verbatim('${tr('Taken away')}: ${x.title}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(decoration: TextDecoration.lineThrough, color: theme.disabledColor)),
            ),
          ]),
        ),
      ));
    }
    rows.sort((a, b) => a.$1.compareTo(b.$1));
    return [
      Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 4),
        child: Text.verbatim(l.formatMediumDate(day), style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
      ),
      for (final r in rows) r.$2,
    ];
  }

  Widget _sessionCard(BuildContext context, ProposedSession x) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = _p.entry;
    final badge = switch (x.change) {
      SessionChange.added => _existing ? tr('New') : null,
      SessionChange.changed => tr('Changed'),
      SessionChange.same => null,
    };
    return Card(
      key: ValueKey('study-session-${x.session.key}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text.verbatim('${_time(context, x.session.start)}-${_time(context, x.session.end)}',
                    style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: scheme.tertiary, borderRadius: BorderRadius.circular(4)),
                    child: Text.verbatim(badge, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onTertiary)),
                  ),
              ]),
              const SizedBox(height: 2),
              for (final i in x.session.items)
                Text.verbatim('• ${itemText(i, i.unitId == null ? null : e.unit(i.unitId!))}', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onPrimaryContainer)),
            ]),
          ),
          IconButton(
            key: ValueKey('study-refuse-${x.session.key}'),
            tooltip: tr('Not at this time'),
            icon: Icon(Icons.close, color: scheme.onPrimaryContainer),
            onPressed: _working ? null : () => _refuse(x.session),
          ),
        ]),
      ),
    );
  }
}
