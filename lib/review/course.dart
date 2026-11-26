import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import 'grades.dart';

/// A course: a folder of notes that is marked as one, with what a student keeps about it besides the notes - the term, the credits, who
/// teaches it and where, how it is graded and its graded parts, the exam plans for it, and how its lectures are named in an imported
/// timetable.
///
/// A course is the folder: the notes stay where they are. It is kept in the settings as `course:<folder id>` (synced to the other
/// devices like the study plans); a course that is no longer one stays there as `removed`, so that the others hear of it too.
class Course {
  final String folderId;
  final String term;
  final double credits;
  final String teacher, room;
  final GradeScale scale;

  /// The grade the student aims at (on [scale]); null: passing.
  final double? target;
  final List<Assessment> parts;

  /// The ids of the study plans (exams) of the course.
  final List<String> plans;

  /// How the course's events are named in the calendar (`Linear Algebra*`: `*` stands for anything); empty: none are matched.
  final String eventPattern;

  final bool removed;

  const Course({
    required this.folderId,
    this.term = '',
    this.credits = 0,
    this.teacher = '',
    this.room = '',
    this.scale = GradeScale.percent,
    this.target,
    this.parts = const [],
    this.plans = const [],
    this.eventPattern = '',
    this.removed = false,
  });

  CourseGrades get grades => CourseGrades(scale, parts);

  /// The grade aimed at, or the pass mark.
  double get goal => target ?? scale.pass;

  /// Whether an event called [title] is one of this course's (its pattern, letters in any case, `*` for anything).
  bool isEvent(String title) {
    final p = eventPattern.trim();
    if (p.isEmpty) return false;
    final re = RegExp('^${p.split('*').map(RegExp.escape).join('.*')}\$', caseSensitive: false);
    return re.hasMatch(title.trim());
  }

  /// The parts not graded yet that are still to come (or have no day), the soonest first.
  List<Assessment> upcoming(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return [
      for (final p in parts)
        if (p.gradeOn(scale) == null && (p.due == null || !p.due!.isBefore(day))) p,
    ]..sort((a, b) => (a.due ?? DateTime(9999)).compareTo(b.due ?? DateTime(9999)));
  }

  Map<String, Object?> toJson() => removed
      ? {'folder': folderId, 'removed': true}
      : {
          'folder': folderId,
          if (term.isNotEmpty) 'term': term,
          if (credits > 0) 'credits': credits,
          if (teacher.isNotEmpty) 'teacher': teacher,
          if (room.isNotEmpty) 'room': room,
          'scale': scale.name,
          'target': ?target,
          'parts': [for (final p in parts) p.toJson()],
          if (plans.isNotEmpty) 'plans': plans,
          if (eventPattern.isNotEmpty) 'events': eventPattern,
        };

  static Course? fromJson(Object? j) {
    if (j is! Map || j['folder'] is! String) return null;
    String text(Object? v) => v is String ? v : '';
    return Course(
      folderId: j['folder'] as String,
      term: text(j['term']),
      credits: j['credits'] is num ? (j['credits'] as num).toDouble() : 0,
      teacher: text(j['teacher']),
      room: text(j['room']),
      scale: GradeScale.byName(j['scale'] as String?),
      target: j['target'] is num ? (j['target'] as num).toDouble() : null,
      parts: [for (final p in (j['parts'] as List?) ?? const []) ?Assessment.fromJson(p)],
      plans: [for (final p in (j['plans'] as List?) ?? const []) if (p is String) p],
      eventPattern: text(j['events']),
      removed: j['removed'] == true,
    );
  }

  Course copyWith({
    String? term,
    double? credits,
    String? teacher,
    String? room,
    GradeScale? scale,
    double? Function()? target,
    List<Assessment>? parts,
    List<String>? plans,
    String? eventPattern,
  }) =>
      Course(
        folderId: folderId,
        term: term ?? this.term,
        credits: credits ?? this.credits,
        teacher: teacher ?? this.teacher,
        room: room ?? this.room,
        scale: scale ?? this.scale,
        target: target == null ? this.target : target(),
        parts: parts ?? this.parts,
        plans: plans ?? this.plans,
        eventPattern: eventPattern ?? this.eventPattern,
      );
}

/// The courses, kept in the settings (see [Course]).
class CourseRepository extends ChangeNotifier {
  static const keyPrefix = 'course:';

  final SettingsRepository settings;
  StreamSubscription<String>? _sync;

  CourseRepository(this.settings) {
    _sync = settings.changedBySync.listen((key) {
      if (key.startsWith(keyPrefix)) unawaited(load());
    });
  }

  Map<String, Course> _courses = const {};

  /// The courses (not the removed ones), by folder.
  Map<String, Course> get courses => _courses;

  Course? of(String? folderId) => folderId == null ? null : _courses[folderId];

  Future<void> load() async {
    final all = await settings.allWhere((k) => k.startsWith(keyPrefix));
    final out = <String, Course>{};
    for (final e in all.entries) {
      try {
        final c = Course.fromJson(jsonDecode(e.value.value));
        if (c != null && !c.removed) out[c.folderId] = c;
      } on FormatException {
        // (a broken line is left out)
      }
    }
    _courses = out;
    notifyListeners();
  }

  Future<void> save(Course c) async {
    await settings.set('$keyPrefix${c.folderId}', jsonEncode(c.toJson()));
    _courses = {..._courses, c.folderId: c};
    notifyListeners();
  }

  /// The folder is no longer a course (its notes stay).
  Future<void> remove(String folderId) async {
    await settings.set('$keyPrefix$folderId', jsonEncode(Course(folderId: folderId, removed: true).toJson()));
    _courses = {..._courses}..remove(folderId);
    notifyListeners();
  }

  @override
  void dispose() {
    _sync?.cancel();
    super.dispose();
  }
}
