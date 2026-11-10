import 'dart:async';

import '../data/audio_repository.dart';
import '../data/note_repository.dart';
import '../data/task_repository.dart';
import 'event_bus.dart';

/// Announced every so often; `AutomationService` looks for notes that went stale on it.
const tickEvent = EventType('tick', 'Time passes', internal: true);

/// Announces `noteCreated` for every note the repository makes.
class NoteEventSource {
  final NoteRepository _notes;
  final EventBus _bus;
  StreamSubscription<String>? _created;

  NoteEventSource(this._notes, this._bus);

  void start() {
    _created ??= _notes.created.listen((id) async {
      final info = await _notes.noteInfo(id);
      if (info == null) return;
      await _bus.emit(AppEvent('noteCreated', noteId: id, title: info.title, folderId: info.folderId));
    });
  }

  void dispose() {
    _created?.cancel();
    _created = null;
  }
}

/// Announces [tickEvent] a moment after the app started and every few hours while it runs.
class TickSource {
  final EventBus _bus;
  Timer? _first, _every;

  TickSource(this._bus);

  void start({Duration every = const Duration(hours: 6), Duration first = const Duration(seconds: 8)}) {
    dispose();
    _first = Timer(first, () => _bus.emit(const AppEvent('tick')));
    _every = Timer.periodic(every, (_) => _bus.emit(const AppEvent('tick')));
  }

  void dispose() {
    _first?.cancel();
    _every?.cancel();
  }
}

/// Announces `notePaused` for a note that was saved and then not saved again for [pause]: the person stopped writing (the note may still
/// be open).
class IdleSource {
  final NoteRepository _notes;
  final EventBus _bus;
  final Duration pause;
  final _timers = <String, Timer>{};
  StreamSubscription<String>? _saved;

  IdleSource(this._notes, this._bus, {this.pause = const Duration(seconds: 30)});

  void start() {
    _saved ??= _notes.saved.listen((id) {
      _timers[id]?.cancel();
      _timers[id] = Timer(pause, () async {
        _timers.remove(id);
        final info = await _notes.noteInfo(id);
        if (info == null) return;
        await _bus.emit(AppEvent('notePaused', noteId: id, title: info.title, folderId: info.folderId));
      });
    });
  }

  void dispose() {
    _saved?.cancel();
    _saved = null;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}

/// What an event says that a rule can put in its texts as `{name}`: `AppEvent.data['vars']`.
Map<String, Object?> eventVars(Map<String, String> vars) => {'vars': vars};

/// Announces what happens to notes, tasks and recordings: `pageAdded`, `highlightAdded`, `noteLinked` and `pdfImported` as a save adds
/// them to a note, `taskCompleted` as a task is ticked off, `audioRecorded` as a recording is kept.
class ActivitySource {
  final NoteRepository _notes;
  final TaskRepository? _tasks;
  final AudioRepository? _audio;
  final EventBus _bus;
  final _subs = <StreamSubscription<Object?>>[];

  ActivitySource(this._notes, this._bus, {TaskRepository? tasks, AudioRepository? audio})
      : _tasks = tasks,
        _audio = audio;

  void start() {
    if (_subs.isNotEmpty) return;
    _subs.add(_notes.activity.listen((a) async {
      final info = await _notes.noteInfo(a.noteId);
      if (info == null) return;
      Future<void> say(String type, Map<String, String> vars) =>
          _bus.emit(AppEvent(type, noteId: a.noteId, title: info.title, folderId: info.folderId, data: eventVars(vars)));
      if (a.pdfAdded != null) await say('pdfImported', {'pdf': a.pdfAdded!});
      if (a.pagesAdded > 0) await say('pageAdded', {'pages': '${a.pages}'});
      if (a.highlightsAdded > 0) await say('highlightAdded', {'n': '${a.highlightsAdded}'});
      for (final target in a.newLinks) {
        final other = await _notes.noteInfo(target);
        if (other != null) await say('noteLinked', {'target': other.title, 'targetId': target});
      }
    }));
    final tasks = _tasks;
    if (tasks != null) {
      _subs.add(tasks.completed.listen((t) async {
        final due = t.dueDate;
        final day = due == null ? '' : '${due.year.toString().padLeft(4, '0')}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')}';
        await _bus.emit(AppEvent('taskCompleted', title: t.title, data: eventVars({'due': day})));
      }));
    }
    final audio = _audio;
    if (audio != null) {
      _subs.add(audio.recorded.listen((a) async {
        final info = await _notes.noteInfo(a.noteId);
        if (info == null) return;
        final minutes = (a.duration.inSeconds / 60).ceil().clamp(1, 100000);
        await _bus.emit(AppEvent('audioRecorded',
            noteId: a.noteId, title: info.title, folderId: info.folderId, data: eventVars({'audio': a.title, 'minutes': '$minutes'})));
      }));
    }
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }
}

/// A calendar event that is coming up.
class UpcomingEvent {
  final String title;
  final DateTime start;
  final bool allDay;

  /// When it ends; null when the calendar does not say.
  final DateTime? end;

  /// Tells it from the others (the calendar's own id, else the title).
  final String uid;

  const UpcomingEvent(this.title, this.start, {this.allDay = false, this.end, String? uid}) : uid = uid ?? title;
}

/// Announced every minute while the app runs; `AutomationService` looks for calendar events that are about to start on it.
const minuteEvent = EventType('minute', 'A minute passes', internal: true);

class MinuteSource {
  final EventBus _bus;
  Timer? _timer;

  MinuteSource(this._bus);

  void start({Duration every = const Duration(minutes: 1)}) {
    dispose();
    _timer = Timer.periodic(every, (_) => _bus.emit(const AppEvent('minute')));
  }

  void dispose() => _timer?.cancel();
}
