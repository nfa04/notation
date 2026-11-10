import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import '../data/task_repository.dart';
import '../l10n/language.dart';
import 'caldav_remote.dart';
import 'caldav_service.dart';
import 'device_calendar_service.dart';

/// Puts the tasks that have a day on a calendar as all-day events, so that they show up in the calendar app of the phone or of
/// the server too: by default the ones that were made by an automation or found in a note. The calendar is chosen in the
/// settings of the calendar; `caldav:<address>` is a calendar of the server, `phone:<id>` one of the phone. An event is
/// removed again when the task is done, deleted or changed (and made anew for the change).
class TaskCalendarMirror extends ChangeNotifier {
  static const _kTarget = 'mirror_target';
  static const _kOnlyAuto = 'mirror_only_auto';

  final SettingsRepository _settings;
  final TaskRepository _tasks;
  final CalDavService? _caldav;
  final DeviceCalendarService? _device;

  TaskCalendarMirror(this._settings, this._tasks, {CalDavService? caldav, DeviceCalendarService? device})
      : _caldav = caldav,
        _device = device;

  String? _target;
  bool _onlyAuto = true;
  StreamSubscription<void>? _watch;
  Timer? _later;
  bool _running = false, _again = false;

  /// The calendar the tasks go to, or null when they do not.
  String? get target => _target;

  /// Only the tasks that were made by an automation or found in a note.
  bool get onlyAuto => _onlyAuto;

  /// Why the last run failed, or null.
  String? problem;

  Future<void> load() async {
    _target = await _settings.get(_kTarget);
    _onlyAuto = (await _settings.get(_kOnlyAuto)) != '0';
    _watch ??= _tasks.changes.listen((_) => runSoon());
  }

  Future<void> setTarget(String? target) async {
    _target = target;
    if (target == null) {
      await _settings.remove(_kTarget);
    } else {
      await _settings.set(_kTarget, target);
    }
    notifyListeners();
    await run();
  }

  Future<void> setOnlyAuto(bool value) async {
    _onlyAuto = value;
    await _settings.set(_kOnlyAuto, value ? '1' : '0');
    notifyListeners();
    await run();
  }

  /// The calendars the tasks can go to: the writable ones of the server and of the phone.
  Future<List<CalendarInfo>> choices() async => [
        ...await _caldav?.writableCalendars().then((l) => [for (final c in l) CalendarInfo('caldav:${c.key}', c.name, c.color)]) ?? const <CalendarInfo>[],
        ...await _device?.writableCalendars() ?? const <CalendarInfo>[],
      ];

  /// A moment after the last change of a task.
  void runSoon() {
    _later?.cancel();
    _later = Timer(const Duration(seconds: 2), run);
  }

  static String _fingerprint(Task t) => '${t.title}|${t.dueDate!.year}-${t.dueDate!.month}-${t.dueDate!.day}';

  /// Brings the events in line with the tasks.
  Future<void> run() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await _once();
      } while (_again);
    } finally {
      _running = false;
    }
  }

  Future<void> _once() async {
    problem = null;
    try {
      final links = await _tasks.taskEvents();
      final wanted = <String, Task>{
        if (_target != null)
          for (final t in await _tasks.listTasks())
            if (t.dueDate != null && !t.done && (!_onlyAuto || t.auto)) t.id: t,
      };
      for (final entry in links.entries.toList()) {
        final t = wanted[entry.key];
        if (t != null && entry.value.target == _target && entry.value.fingerprint == _fingerprint(t)) continue;
        try {
          await _remove(entry.value.target, entry.value.remoteId);
        } catch (e) {
          debugPrint('removing the event of a task failed: $e');
        }
        await _tasks.removeTaskEvent(entry.key);
        links.remove(entry.key);
      }
      final target = _target;
      if (target == null) return;
      for (final t in wanted.values) {
        if (links.containsKey(t.id)) continue;
        final event = NewEvent(title: t.title, start: t.dueDate!, allDay: true, description: tr('From a task in Notation'));
        final remote = await _create(target, event);
        await _tasks.putTaskEvent(t.id, target, remote, _fingerprint(t));
      }
    } catch (e) {
      problem = '$e'.replaceFirst('Bad state: ', '');
      debugPrint('putting tasks on the calendar failed: $e');
    } finally {
      notifyListeners();
    }
  }

  Future<String> _create(String target, NewEvent event) {
    if (target.startsWith('caldav:')) {
      final caldav = _caldav;
      if (caldav == null || !caldav.isConnected) throw StateError(tr('The calendar server is not connected.'));
      return caldav.createEvent(target.substring('caldav:'.length), event);
    }
    final device = _device;
    if (device == null) throw StateError(tr('This device has no calendars to write to.'));
    return device.createEvent(target.substring('phone:'.length), event);
  }

  Future<void> _remove(String target, String remoteId) async {
    if (target.startsWith('caldav:')) {
      await _caldav?.deleteEvent(target.substring('caldav:'.length), remoteId);
    } else {
      await _device?.deleteEvent(remoteId);
    }
  }

  @override
  void dispose() {
    _later?.cancel();
    _watch?.cancel();
    super.dispose();
  }
}
