import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:material_symbols_icons/symbols.dart';

import '../data/card_repository.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/course.dart';
import '../review/grades.dart';
import '../sync/caldav_remote.dart' show DayEvent;
import 'review_view.dart';

/// A grade as it is written on [scale] (rounded to two places, without zeros at the end).
String gradeText(GradeScale scale, double grade) {
  final s = grade.toStringAsFixed(scale.step >= 1 ? 0 : 2);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

/// What a student needs on what is left of a course, in words.
String neededText(Course c) {
  final goal = gradeText(c.scale, c.goal);
  return switch (c.grades.neededFor(c.goal)) {
    AlreadyReached() => tr('{goal} is reached whatever comes.', {'goal': goal}),
    NotReachable(:final best) => tr('{goal} is out of reach: the best still possible is {best}.', {'goal': goal, 'best': gradeText(c.scale, best)}),
    NeedGrade(:final grade) => tr('For {goal}: {need} on average on what is left.', {'goal': goal, 'need': gradeText(c.scale, grade)}),
  };
}

/// Above the notes of a folder that is a course: the term and who teaches it, the next lecture, what is due next, the cards of its notes
/// that are due, and how the grade stands.
class CourseHeader extends StatefulWidget {
  final Course course;
  final CourseRepository courses;

  /// The notes in the folder (and its subfolders): their cards are the course's.
  final List<String> noteIds;
  final CardRepository? cards;

  /// The events between two times (for the next lecture); null: no calendar.
  final Future<List<DayEvent>> Function(DateTime from, DateTime to)? events;

  /// Puts a task with a due date in the to-dos; null: not offered.
  final Future<void> Function(String title, DateTime due)? onAddTask;
  final DateTime Function()? clock;

  const CourseHeader({super.key, required this.course, required this.courses, required this.noteIds, this.cards, this.events, this.onAddTask, this.clock});

  @override
  State<CourseHeader> createState() => _CourseHeaderState();
}

class _CourseHeaderState extends State<CourseHeader> {
  int? _due;
  DayEvent? _lecture;
  StreamSubscription<void>? _sub;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _sub = widget.cards?.changes.listen((_) => _load());
    _load();
  }

  @override
  void didUpdateWidget(CourseHeader old) {
    super.didUpdateWidget(old);
    if (old.noteIds.length != widget.noteIds.length || old.course.eventPattern != widget.course.eventPattern) _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final cards = widget.cards;
    var due = 0;
    if (cards != null) {
      for (final id in widget.noteIds) {
        due += await cards.dueCount(now: _now(), source: id);
      }
    }
    DayEvent? lecture;
    final events = widget.events;
    if (events != null && widget.course.eventPattern.trim().isNotEmpty) {
      try {
        final now = _now();
        final found = [for (final e in await events(now, now.add(const Duration(days: 14)))) if (!e.allDay && e.start.isAfter(now) && widget.course.isEvent(e.title)) e]
          ..sort((a, b) => a.start.compareTo(b.start));
        lecture = found.firstOrNull;
      } catch (_) {
        // (a calendar that cannot be read: no lecture shown)
      }
    }
    if (!mounted) return;
    setState(() {
      _due = due;
      _lecture = lecture;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.course;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = MaterialLocalizations.of(context);
    final quiet = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    final avg = c.grades.average;
    final next = c.upcoming(_now()).take(3).toList();
    final facts = [
      if (c.term.isNotEmpty) c.term,
      if (c.credits > 0) trCount(c.credits.round(), '{n} credit', '{n} credits'),
      if (c.teacher.isNotEmpty) c.teacher,
      if (c.room.isNotEmpty) c.room,
    ];
    return Card(
      key: const ValueKey('course-header'),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Symbols.school, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text.verbatim(facts.isEmpty ? tr('Course') : facts.join(' · '), style: theme.textTheme.titleSmall)),
            TextButton(
              key: const ValueKey('course-details'),
              onPressed: () => showCourseDialog(context, widget.courses, c, onAddTask: widget.onAddTask),
              child: const Text('Course details'),
            ),
          ]),
          if (_lecture case final e?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text.verbatim(tr('Next lecture: {when}', {'when': '${l.formatMediumDate(e.start)}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(e.start))}'}),
                  key: const ValueKey('course-next-lecture'), style: quiet),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 24, runSpacing: 12, children: [
            // the grade
            SizedBox(
              width: 260,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Grade', style: quiet),
                Text.verbatim(avg == null ? tr('Nothing graded yet') : gradeText(c.scale, avg),
                    key: const ValueKey('course-grade'),
                    style: theme.textTheme.headlineSmall?.copyWith(color: avg == null ? null : (c.scale.passes(avg) ? scheme.primary : scheme.error))),
                if (avg != null && c.scale.className(avg) != null) Text.verbatim(tr(c.scale.className(avg)!), style: quiet),
                if (c.parts.isNotEmpty) Text.verbatim(neededText(c), key: const ValueKey('course-needed'), style: quiet),
              ]),
            ),
            // what comes next
            if (next.isNotEmpty)
              SizedBox(
                width: 260,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Next up', style: quiet),
                  for (final p in next)
                    Text.verbatim(p.due == null ? p.name : '${p.name} · ${l.formatShortDate(p.due!)}', key: ValueKey('course-next-${p.id}')),
                ]),
              ),
            // the cards
            if (widget.cards != null && (_due ?? 0) > 0)
              SizedBox(
                width: 200,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Cards', style: quiet),
                  Text.verbatim(trCount(_due!, '{n} card to review', '{n} cards to review'), key: const ValueKey('course-cards-due')),
                  const SizedBox(height: 4),
                  FilledButton.tonal(
                    key: const ValueKey('course-review'),
                    onPressed: () async {
                      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ReviewScreen(cards: widget.cards!, sources: widget.noteIds.toSet(), clock: widget.clock)));
                      _load();
                    },
                    child: const Text('Review'),
                  ),
                ]),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// The details of a course: the term, the credits, how it is graded, its graded parts, its lectures in the calendar. Saved when closed
/// with Save.
Future<void> showCourseDialog(BuildContext context, CourseRepository courses, Course course, {Future<void> Function(String title, DateTime due)? onAddTask}) async {
  final saved = await showDialog<Course>(context: context, builder: (_) => _CourseDialog(course: course, onAddTask: onAddTask));
  if (saved != null) await courses.save(saved);
}

class _CourseDialog extends StatefulWidget {
  final Course course;
  final Future<void> Function(String title, DateTime due)? onAddTask;

  const _CourseDialog({required this.course, this.onAddTask});

  @override
  State<_CourseDialog> createState() => _CourseDialogState();
}

class _CourseDialogState extends State<_CourseDialog> {
  late final _term = TextEditingController(text: widget.course.term);
  late final _credits = TextEditingController(text: widget.course.credits > 0 ? gradeText(GradeScale.swiss, widget.course.credits) : '');
  late final _teacher = TextEditingController(text: widget.course.teacher);
  late final _room = TextEditingController(text: widget.course.room);
  late final _events = TextEditingController(text: widget.course.eventPattern);
  late final _target = TextEditingController(text: widget.course.target == null ? '' : gradeText(widget.course.scale, widget.course.target!));
  late var _scale = widget.course.scale;
  late var _parts = [...widget.course.parts];

  @override
  void dispose() {
    for (final c in [_term, _credits, _teacher, _room, _events, _target]) {
      c.dispose();
    }
    super.dispose();
  }

  static double? _number(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  Course get _course => widget.course.copyWith(
        term: _term.text.trim(),
        credits: _number(_credits.text) ?? 0,
        teacher: _teacher.text.trim(),
        room: _room.text.trim(),
        scale: _scale,
        target: () => _number(_target.text) == null ? null : _scale.clamp(_number(_target.text)!),
        parts: _parts,
        eventPattern: _events.text.trim(),
      );

  Future<void> _editPart([Assessment? part]) async {
    final edited = await showDialog<Assessment>(context: context, builder: (_) => _PartDialog(part: part, scale: _scale));
    if (edited == null) return;
    setState(() {
      final i = _parts.indexWhere((p) => p.id == edited.id);
      i >= 0 ? _parts[i] = edited : _parts.add(edited);
    });
  }

  Widget _field(TextEditingController c, String label, {Key? key, TextInputType? keyboard, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(key: key, controller: c, keyboardType: keyboard, decoration: InputDecoration(labelText: tr(label), hintText: hint == null ? null : tr(hint), border: const OutlineInputBorder(), isDense: true)),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = MaterialLocalizations.of(context);
    final course = _course;
    final avg = course.grades.average;
    return AlertDialog(
      title: const Text('Course details'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _field(_term, 'Term', key: const ValueKey('course-term'), hint: 'Autumn 2026'),
          Row(children: [
            Expanded(child: _field(_credits, 'Credits', key: const ValueKey('course-credits'), keyboard: const TextInputType.numberWithOptions(decimal: true))),
            const SizedBox(width: 8),
            Expanded(child: _field(_room, 'Room', key: const ValueKey('course-room'))),
          ]),
          _field(_teacher, 'Teacher', key: const ValueKey('course-teacher')),
          _field(_events, 'Its events in the calendar are called', key: const ValueKey('course-events'), hint: 'Linear Algebra*  (* stands for anything)'),
          const SizedBox(height: 8),
          DropdownButtonFormField<GradeScale>(
            key: const ValueKey('course-scale'),
            initialValue: _scale,
            isExpanded: true,
            decoration: InputDecoration(labelText: tr('Grades'), border: const OutlineInputBorder(), isDense: true),
            items: [for (final s in GradeScale.values) DropdownMenuItem(value: s, child: Text(s.label))],
            onChanged: (s) => setState(() => _scale = s ?? _scale),
          ),
          const SizedBox(height: 8),
          _field(_target, 'Grade I aim for', key: const ValueKey('course-target'), keyboard: const TextInputType.numberWithOptions(decimal: true), hint: 'empty: passing'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text('Graded parts', style: Theme.of(context).textTheme.titleSmall)),
            TextButton.icon(key: const ValueKey('course-add-part'), icon: const Icon(Symbols.add), label: const Text('Add'), onPressed: _editPart),
          ]),
          if (_parts.isEmpty)
            Text('Add the exams, assignments and other parts that make the grade, with how much each counts.', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          for (final p in _parts)
            ListTile(
              key: ValueKey('course-part-${p.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text.verbatim(p.name),
              subtitle: Text.verbatim([
                '${gradeText(GradeScale.percent, p.weight)} %',
                if (p.due != null) l.formatShortDate(p.due!),
                if (p.gradeOn(_scale) case final g?) tr('grade {g}', {'g': gradeText(_scale, g)}),
                if (!p.counts) tr('practice'),
              ].join(' · ')),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (widget.onAddTask != null && p.due != null && p.gradeOn(_scale) == null)
                  IconButton(
                    tooltip: tr('Add to my tasks'),
                    icon: const Icon(Symbols.add_task),
                    onPressed: () async {
                      await widget.onAddTask!(p.name, p.due!);
                      if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text.verbatim(tr('"{name}" is in your tasks', {'name': p.name}))));
                    },
                  ),
                IconButton(tooltip: tr('Remove'), icon: const Icon(Symbols.delete_outline), onPressed: () => setState(() => _parts = [for (final x in _parts) if (x.id != p.id) x])),
              ]),
              onTap: () => _editPart(p),
            ),
          if (avg != null) ...[
            const SizedBox(height: 8),
            Text.verbatim('${tr('Grade so far: {g}', {'g': gradeText(_scale, avg)})}. ${neededText(course)}', key: const ValueKey('course-dialog-grade')),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('course-save'), onPressed: () => Navigator.pop(context, _course), child: const Text('Save')),
      ],
    );
  }
}

/// One graded part: its name, kind, weight, day, and the grade (or the points) it got.
class _PartDialog extends StatefulWidget {
  final Assessment? part;
  final GradeScale scale;

  const _PartDialog({this.part, required this.scale});

  @override
  State<_PartDialog> createState() => _PartDialogState();
}

class _PartDialogState extends State<_PartDialog> {
  static const kinds = ['exam', 'assignment', 'quiz', 'lab', 'other'];
  late final _name = TextEditingController(text: widget.part?.name ?? '');
  late final _weight = TextEditingController(text: widget.part == null ? '' : gradeText(GradeScale.percent, widget.part!.weight));
  late final _grade = TextEditingController(text: widget.part?.grade == null ? '' : gradeText(widget.scale, widget.part!.grade!));
  late final _points = TextEditingController(text: widget.part?.points == null ? '' : gradeText(GradeScale.swiss, widget.part!.points!));
  late final _max = TextEditingController(text: widget.part?.maxPoints == null ? '' : gradeText(GradeScale.swiss, widget.part!.maxPoints!));
  late var _kind = widget.part?.kind ?? 'exam';
  late var _due = widget.part?.due;
  late var _counts = widget.part?.counts ?? true;

  @override
  void dispose() {
    for (final c in [_name, _weight, _grade, _points, _max]) {
      c.dispose();
    }
    super.dispose();
  }

  static double? _number(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  static String _kindLabel(String k) => switch (k) {
        'exam' => tr('Exam'),
        'assignment' => tr('Assignment'),
        'quiz' => tr('Quiz'),
        'lab' => tr('Lab'),
        _ => tr('Other'),
      };

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    InputDecoration deco(String label, {String? hint}) => InputDecoration(labelText: tr(label), hintText: hint == null ? null : tr(hint), border: const OutlineInputBorder(), isDense: true);
    const numbers = TextInputType.numberWithOptions(decimal: true);
    return AlertDialog(
      title: Text(widget.part == null ? 'New graded part' : 'Graded part'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(key: const ValueKey('part-name'), controller: _name, autofocus: widget.part == null, decoration: deco('Name', hint: 'Midterm'), onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _kind,
                isExpanded: true,
                decoration: deco('Kind'),
                items: [for (final k in kinds) DropdownMenuItem(value: k, child: Text.verbatim(_kindLabel(k)))],
                onChanged: (k) => setState(() => _kind = k ?? _kind),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: TextField(key: const ValueKey('part-weight'), controller: _weight, keyboardType: numbers, decoration: deco('Counts (%)'))),
          ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('part-due'),
            icon: const Icon(Symbols.event, size: 18),
            label: Text.verbatim(_due == null ? tr('No date') : l.formatMediumDate(_due!)),
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(context: context, initialDate: _due ?? now, firstDate: DateTime(now.year - 5), lastDate: DateTime(now.year + 5));
              if (d != null) setState(() => _due = d);
            },
          ),
          const SizedBox(height: 12),
          Text.verbatim(tr('The grade it got ({scale}), or the points:', {'scale': tr(widget.scale.label)}), style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: TextField(key: const ValueKey('part-grade'), controller: _grade, keyboardType: numbers, decoration: deco('Grade'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(key: const ValueKey('part-points'), controller: _points, keyboardType: numbers, decoration: deco('Points'))),
            const SizedBox(width: 4),
            const Text('/'),
            const SizedBox(width: 4),
            Expanded(child: TextField(key: const ValueKey('part-max'), controller: _max, keyboardType: numbers, decoration: deco('of'))),
          ]),
          SwitchListTile.adaptive(
            key: const ValueKey('part-counts'),
            contentPadding: EdgeInsets.zero,
            value: _counts,
            onChanged: (v) => setState(() => _counts = v),
            title: const Text('Counts towards the grade'),
            subtitle: const Text('Off for a practice exam.'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('part-save'),
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    Assessment(
                      id: widget.part?.id ?? DateTime.now().microsecondsSinceEpoch.toRadixString(36),
                      name: _name.text.trim(),
                      kind: _kind,
                      weight: (_number(_weight.text) ?? 1).clamp(0, 1000).toDouble(),
                      due: _due,
                      grade: _number(_grade.text),
                      points: _number(_points.text),
                      maxPoints: _number(_max.text),
                      counts: _counts,
                    ),
                  ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
