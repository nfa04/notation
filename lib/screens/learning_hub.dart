import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../data/card_repository.dart';
import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/course.dart';
import '../review/grades.dart';
import '../review/study_planner.dart';
import 'course_header.dart';
import 'review_export.dart';
import 'review_view.dart';
import 'study_plan_detail.dart';
import 'study_plan_screen.dart';
import 'study_session_screen.dart';

/// The name of a source of cards as a person reads it: the note's title, "Facts of the graph", or the Anki deck.
String cardSourceName(String source, Map<String, String> titles) {
  if (source == CardRepository.graphSource) return tr('Facts of the graph');
  if (source.startsWith(ankiSourcePrefix)) return tr('Anki: {deck}', {'deck': source.substring(ankiSourcePrefix.length)});
  return titles[source] ?? tr('A deleted note');
}

/// The tabs under "Today" in the hub.
enum _HubTab { cards, exams, courses }

/// One source of cards in the hub: how many it has and how many are due.
typedef _Deck = ({String source, String name, int count, int due});

/// The one place for learning: what is due today (the study session, the cards), the cards kept for review by where they came
/// from, and the plans for exams. [planner] is null when the calendar is off (no exams), [cards] when the flashcards are off.
/// Reviewing cards needs no AI: only making them does (in a note's assistant or the graph).
class LearningHub extends StatefulWidget {
  final NoteRepository repository;
  final StudyPlanner? planner;
  final CardRepository? cards;

  /// The courses and their grades; null: not offered.
  final CourseRepository? courses;
  final OpenNoteAt? onOpenNoteAt;
  final DateTime Function()? clock;

  const LearningHub({super.key, required this.repository, this.planner, this.cards, this.courses, this.onOpenNoteAt, this.clock});

  @override
  State<LearningHub> createState() => _LearningHubState();
}

class _LearningHubState extends State<LearningHub> {
  /// The plan whose page is shown here in the tab (null: the hub).
  String? _open;
  List<_Deck>? _decks;
  StreamSubscription<void>? _sub;
  /// The tab shown under Today (the first one there is when this one is off).
  _HubTab _tab = _HubTab.cards;

  @override
  void initState() {
    super.initState();
    _sub = widget.cards?.changes.listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  DateTime _now() => (widget.clock ?? DateTime.now)();

  Future<void> _load() async {
    final cards = widget.cards;
    if (cards == null) return;
    final counts = await cards.sourceCounts();
    final titles = counts.keys.any((s) => s != CardRepository.graphSource && !s.startsWith(ankiSourcePrefix))
        ? {for (final n in await widget.repository.listNotes()) n.id: n.shownTitle}
        : const <String, String>{};
    final decks = <_Deck>[
      for (final MapEntry(key: source, value: count) in counts.entries)
        (source: source, name: cardSourceName(source, titles), count: count, due: await cards.dueCount(now: _now(), source: source)),
    ];
    // the ones with cards due first, then by name
    decks.sort((a, b) => (a.due > 0) != (b.due > 0) ? (a.due > 0 ? -1 : 1) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (mounted) setState(() => _decks = decks);
  }

  Future<void> _review({String? source}) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ReviewScreen(cards: widget.cards!, source: source, repository: widget.repository, clock: widget.clock)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final planner = widget.planner;
    final open = _open;
    if (planner != null && open != null && planner.plans.any((p) => p.id == open)) {
      return StudyPlanDetail(planner: planner, planId: open, clock: widget.clock, cards: widget.cards, onOpenNoteAt: widget.onOpenNoteAt, onBack: () => setState(() => _open = null));
    }
    // Today stays on top; the cards and the exams are two tabs under it (a plain heading when only one of them is on).
    final sections = [if (widget.cards != null) _HubTab.cards, if (planner != null) _HubTab.exams, if (widget.courses?.courses.isNotEmpty ?? false) _HubTab.courses];
    final shown = sections.contains(_tab) ? _tab : (sections.isEmpty ? null : sections.first);
    Widget page(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Learning hub')),
      body: ListView(
        key: const ValueKey('learning-hub'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _heading(context, tr('Today')),
          ..._today(context),
          if (sections.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: DefaultTabController(
                key: const ValueKey('hub-tabs'),
                length: sections.length,
                initialIndex: sections.indexOf(shown!),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  onTap: (i) => setState(() => _tab = sections[i]),
                  tabs: [for (final s in sections) Tab(key: ValueKey('hub-tab-${s.name}'), text: _tabName(s))],
                ),
              ),
            )
          else if (shown != null)
            _heading(context, _tabName(shown)),
          if (shown == _HubTab.courses) ..._courseRows(context),
          if (shown == _HubTab.cards) ...[
            Wrap(spacing: 8, children: [
              TextButton.icon(
                key: const ValueKey('hub-import-anki'),
                icon: const Icon(Symbols.file_download),
                label: const Text('Import from Anki'),
                onPressed: () async {
                  if (await importCardsFromAnki(context, widget.cards!) != null) _load();
                },
              ),
              if (_decks?.isNotEmpty ?? false)
                TextButton.icon(
                  key: const ValueKey('hub-export-anki'),
                  icon: const Icon(Symbols.ios_share),
                  label: const Text('Export to Anki'),
                  onPressed: () => exportCardsToAnki(context, widget.cards!, repository: widget.repository),
                ),
              TextButton.icon(
                key: const ValueKey('hub-retention'),
                icon: const Icon(Symbols.tune),
                label: const Text('How often cards come back'),
                onPressed: () => askRetention(context, widget.cards!),
              ),
            ]),
            ..._deckRows(context),
          ],
          if (shown == _HubTab.exams && planner != null) ...[
            if (planner.plans.isEmpty)
              _quiet(context, tr('Say what the exam is, when it is and what to study for it. The app cuts the material into parts, finds free times in your calendar and shows you the sessions. Nothing goes in your calendar until you approve it.'),
                  key: const ValueKey('study-plans-empty')),
            for (final p in planner.plans)
              StudyPlanCard(
                  key: ValueKey('hub-plan-${p.id}'),
                  planner: planner,
                  repository: widget.repository,
                  entry: p,
                  now: _now(),
                  clock: widget.clock,
                  cards: widget.cards,
                  onOpenNoteAt: widget.onOpenNoteAt,
                  onView: () => setState(() => _open = p.id)),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('new-study-plan'),
                onPressed: () => newStudyPlan(context, planner, widget.repository, clock: widget.clock),
                icon: const Icon(Symbols.add),
                label: const Text('New plan'),
              ),
            ),
          ],
        ],
      ),
    );
    final listen = Listenable.merge([?planner, ?widget.courses]);
    return ListenableBuilder(listenable: listen, builder: (context, _) => page(context));
  }

  static String _tabName(_HubTab t) => switch (t) {
        _HubTab.cards => tr('Cards'),
        _HubTab.exams => tr('Exams'),
        _HubTab.courses => tr('Courses'),
      };

  Map<String, String> _folderNames = const {};

  Future<void> _loadFolderNames() async {
    final names = {for (final f in await widget.repository.listFolders()) f.id: f.name};
    if (mounted) setState(() => _folderNames = names);
  }

  /// The courses by term (the latest first as they are named), each with its grade and what it needs, and the average by credits of
  /// a term (for the courses graded on one scale).
  List<Widget> _courseRows(BuildContext context) {
    final courses = widget.courses!.courses.values.toList();
    if (_folderNames.isEmpty) unawaited(_loadFolderNames());
    final scheme = Theme.of(context).colorScheme;
    final byTerm = <String, List<Course>>{};
    for (final c in courses) {
      (byTerm[c.term] ??= []).add(c);
    }
    final terms = byTerm.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final term in terms) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text.verbatim(term.isEmpty ? tr('No term') : term, style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final c in byTerm[term]!..sort((a, b) => (_folderNames[a.folderId] ?? '').compareTo(_folderNames[b.folderId] ?? '')))
          ListTile(
            key: ValueKey('hub-course-${c.folderId}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: const Icon(Symbols.school),
            title: Text.verbatim(_folderNames[c.folderId] ?? tr('A deleted folder')),
            subtitle: Text.verbatim(c.parts.isEmpty ? tr('No graded parts yet') : neededText(c), style: TextStyle(color: scheme.onSurfaceVariant)),
            trailing: Text.verbatim(c.grades.average == null ? '-' : gradeText(c.scale, c.grades.average!), style: Theme.of(context).textTheme.titleMedium),
            onTap: () => showCourseDialog(context, widget.courses!, c),
          ),
        for (final scale in {for (final c in byTerm[term]!) c.scale})
          if (creditAverage(scale, [for (final c in byTerm[term]!) if (c.scale == scale) (credits: c.credits, grade: c.grades.average)]) case final avg?)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text.verbatim(tr('Average by credits: {g}', {'g': gradeText(scale, avg)}), key: ValueKey('hub-term-average-$term-${scale.name}'), style: TextStyle(color: scheme.primary)),
            ),
      ],
    ];
  }

  List<Widget> _today(BuildContext context) {
    final planner = widget.planner;
    final session = planner?.current();
    final due = _decks?.fold<int>(0, (n, d) => n + d.due) ?? 0;
    return [
      if (planner != null) StudySessionCard(planner: planner, cards: widget.cards, onOpenNoteAt: widget.onOpenNoteAt, clock: widget.clock),
      if (due > 0)
        Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: ListTile(
            leading: const Icon(Symbols.style),
            title: Text.verbatim(trCount(due, '{n} card to review', '{n} cards to review'), key: const ValueKey('hub-due')),
            trailing: FilledButton.tonal(key: const ValueKey('hub-review-due'), onPressed: _review, child: const Text('Review')),
          ),
        ),
      if (due == 0 && session == null && (widget.cards == null || _decks != null)) _quiet(context, tr('Nothing is due today.'), key: const ValueKey('hub-nothing-due')),
    ];
  }

  List<Widget> _deckRows(BuildContext context) {
    final decks = _decks;
    if (decks == null) return const [Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator.adaptive()))];
    if (decks.isEmpty) {
      return [
        _quiet(context, tr('No cards yet. Make them with Flashcards in the assistant of a note or on a topic of the graph, keep a maths mistake from the check, or import a deck from Anki.'),
            key: const ValueKey('hub-no-cards')),
      ];
    }
    final scheme = Theme.of(context).colorScheme;
    return [
      for (final d in decks)
        ListTile(
          key: ValueKey('deck-${d.source}'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(d.source == CardRepository.graphSource ? Symbols.hub : (d.source.startsWith(ankiSourcePrefix) ? Symbols.file_download : Symbols.description)),
          title: Text.verbatim(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text.verbatim('${trCount(d.count, '{n} card', '{n} cards')} · ${d.due == 0 ? tr('none due') : tr('{n} due', {'n': d.due})}',
              style: TextStyle(color: d.due > 0 ? scheme.primary : scheme.onSurfaceVariant)),
          trailing: const Icon(Symbols.chevron_right),
          onTap: () => _review(source: d.source),
        ),
    ];
  }

  Widget _heading(BuildContext context, String text, {List<Widget> actions = const []}) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Row(children: [
          Expanded(child: Text.verbatim(text, style: Theme.of(context).textTheme.titleMedium)),
          ...actions,
        ]),
      );

  Widget _quiet(BuildContext context, String text, {Key? key}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text.verbatim(text, key: key, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

/// On the dashboard: one row for what there is to learn today (the cards due and the next study session), with a button for the
/// session (or the review when there is none) and the hub behind a tap on the row. Nothing is shown when nothing is due.
class LearnTodayRow extends StatefulWidget {
  final StudyPlanner? planner;
  final CardRepository? cards;
  final NoteRepository? repository;
  final OpenNoteAt? onOpenNoteAt;

  /// Opens the learning hub; null: the row has no tap of its own.
  final VoidCallback? onOpenHub;
  final DateTime Function()? clock;

  const LearnTodayRow({super.key, this.planner, this.cards, this.repository, this.onOpenNoteAt, this.onOpenHub, this.clock});

  @override
  State<LearnTodayRow> createState() => _LearnTodayRowState();
}

class _LearnTodayRowState extends State<LearnTodayRow> {
  var _due = 0;
  StreamSubscription<void>? _sub;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sub = widget.cards?.changes.listen((_) => _load());
    widget.planner?.addListener(_changed);
    // (the minutes of a running session, and a session that comes into today or goes by)
    if (widget.planner != null) _tick = Timer.periodic(const Duration(seconds: 30), (_) => _changed());
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    widget.planner?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final due = await widget.cards?.dueCount(now: (widget.clock ?? DateTime.now)()) ?? 0;
    if (mounted && due != _due) setState(() => _due = due);
  }

  @override
  Widget build(BuildContext context) {
    final found = widget.planner?.current();
    if (_due == 0 && found == null) return const SizedBox.shrink();
    final parts = <String>[if (_due > 0) trCount(_due, '{n} card to review', '{n} cards to review')];
    Widget? button;
    if (found != null) {
      final (:plan, :session) = found;
      final running = widget.planner!.running;
      final mine = running != null && running.planId == plan.id && running.key == session.key;
      final now = (widget.clock ?? DateTime.now)();
      final at = MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(session.session.start), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
      parts.add(mine
          ? tr('{what}: studying for {n} min', {'what': session.title, 'n': running.elapsed(now).inMinutes})
          : tr('{what} at {time}', {'what': session.title, 'time': at}));
      button = FilledButton.tonal(
        key: const ValueKey('study-session-open'),
        onPressed: () => openStudySession(context, widget.planner!, plan.id, session.key, cards: widget.cards, onOpenNoteAt: widget.onOpenNoteAt, clock: widget.clock),
        child: Text(mine ? 'Go on' : 'Open'),
      );
    } else {
      button = FilledButton.tonal(
        key: const ValueKey('learn-today-review'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ReviewScreen(cards: widget.cards!, repository: widget.repository, clock: widget.clock)));
          _load();
        },
        child: const Text('Review'),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        key: const ValueKey('learn-today'),
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Symbols.school),
          title: const Text('Learn today'),
          subtitle: Text.verbatim(parts.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: button,
          onTap: widget.onOpenHub,
        ),
      ),
    );
  }
}

/// The setting of how well the cards are to be known: the chance of remembering a card at which it comes back. More means more
/// reviews a day and less forgotten.
Future<void> askRetention(BuildContext context, CardRepository cards) async {
  var r = (await cards.scheduler()).retention;
  if (!context.mounted) return;
  final chosen = await showDialog<double>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final scheme = Theme.of(context).colorScheme;
        final percent = (r * 100).round();
        return AlertDialog(
          title: const Text('How often cards come back'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('A card comes back when you are this likely to still remember it. Higher means more reviews each day and less forgotten; lower means fewer reviews and more forgotten.',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Text.verbatim(tr('Remembered: {n} %', {'n': percent}), key: const ValueKey('retention-value'), style: Theme.of(context).textTheme.titleMedium),
            Slider.adaptive(
              key: const ValueKey('retention-slider'),
              value: r,
              min: CardRepository.minRetention,
              max: CardRepository.maxRetention,
              divisions: ((CardRepository.maxRetention - CardRepository.minRetention) * 100).round(),
              label: '$percent %',
              onChanged: (v) => setState(() => r = (v * 100).round() / 100),
            ),
            Text(percent > 93 ? 'Many reviews: worth it in the last weeks before an exam.' : (percent < 85 ? 'Few reviews: for cards you only want to keep in mind.' : 'The usual choice (90 %).'),
                key: const ValueKey('retention-hint'), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('retention-save'), onPressed: () => Navigator.pop(context, r), child: const Text('Save')),
          ],
        );
      },
    ),
  );
  if (chosen != null) await cards.setRetention(chosen);
}
