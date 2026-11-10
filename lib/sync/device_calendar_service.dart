import 'dart:convert';

import 'package:device_calendar_plus/device_calendar_plus.dart' as plugin;
import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import '../l10n/language.dart';
import 'caldav_remote.dart';

/// A calendar on this phone (any account that is set up in the system).
class PhoneCalendar {
  final String id;
  final String name;
  final String? account;
  final String? color;

  /// Events cannot be added to it (a subscribed or a holiday calendar).
  final bool readOnly;

  const PhoneCalendar({required this.id, required this.name, this.account, this.color, this.readOnly = false});
}

/// What is needed from the phone's calendar database; the plugin in the real
/// app, a fake in tests.
abstract class PhoneCalendarApi {
  /// Asks for permission to read calendars (if needed); true if granted.
  Future<bool> requestAccess();
  Future<bool> hasAccess();
  Future<List<PhoneCalendar>> calendars();

  /// Events with repeats already expanded; all-day events have an exclusive
  /// [end]. Times are local.
  Future<List<PhoneEvent>> events(DateTime from, DateTime to, List<String> calendarIds);

  /// Adds an event to the calendar and returns its id.
  Future<String> createEvent(String calendarId, NewEvent event);

  /// Removes an event (one that is gone already is fine).
  Future<void> deleteEvent(String eventId);
}

/// An event of a calendar on the phone, as the plugin gives it.
class PhoneEvent {
  final String title;
  final DateTime start;
  final DateTime end; // exclusive
  final bool allDay;
  final String calendarId;
  final bool repeats;
  final String id;

  const PhoneEvent({
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.calendarId,
    this.repeats = false,
    this.id = '',
  });
}

/// [PhoneCalendarApi] on top of device_calendar_plus (Android and iOS only).
class PluginPhoneCalendarApi implements PhoneCalendarApi {
  plugin.DeviceCalendar get _p => plugin.DeviceCalendar.instance;

  @override
  Future<bool> requestAccess() async => await _p.requestPermissions() == plugin.CalendarPermissionStatus.granted;

  @override
  Future<bool> hasAccess() async => await _p.hasPermissions() == plugin.CalendarPermissionStatus.granted;

  @override
  Future<List<PhoneCalendar>> calendars() async => [
        for (final c in await _p.listCalendars())
          if (!c.hidden) PhoneCalendar(id: c.id, name: c.name, account: c.accountName, color: c.colorHex, readOnly: c.readOnly),
      ];

  @override
  Future<List<PhoneEvent>> events(DateTime from, DateTime to, List<String> calendarIds) async => [
        for (final e in await _p.listEvents(from, to, calendarIds: calendarIds))
          PhoneEvent(
            title: e.title,
            start: e.startDate,
            end: e.endDate,
            allDay: e.isAllDay,
            calendarId: e.calendarId,
            repeats: e.isRecurring,
            id: e.eventId,
          ),
      ];

  @override
  Future<String> createEvent(String calendarId, NewEvent event) {
    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    return _p.createEvent(
      calendarId: calendarId,
      title: event.title,
      description: event.description.isEmpty ? null : event.description,
      isAllDay: event.allDay,
      // an all-day event ends at the start of the day after its last
      startDate: event.allDay ? day(event.start) : event.start,
      endDate: event.allDay
          ? DateTime(day(event.end ?? event.start).year, day(event.end ?? event.start).month, day(event.end ?? event.start).day + 1)
          : (event.end ?? event.start.add(const Duration(hours: 1))),
    );
  }

  @override
  Future<void> deleteEvent(String eventId) async {
    try {
      await _p.deleteEvent(instanceId: eventId);
    } on plugin.DeviceCalendarException catch (e) {
      if (e.errorCode != plugin.DeviceCalendarError.notFound) rethrow;
    }
  }
}

/// The phone's own calendars as a read-only source of events. Nothing is read
/// until the user turns calendars on, so no permission is asked for before.
class DeviceCalendarService extends ChangeNotifier {
  static const _kSelected = 'device_calendars';

  final SettingsRepository _settings;
  final PhoneCalendarApi? _api;

  /// [api] is null where the platform has no calendar database to read
  /// (everything except Android and iOS); the service then does nothing.
  DeviceCalendarService(this._settings, {PhoneCalendarApi? api}) : _api = api;

  /// The real service for this platform.
  factory DeviceCalendarService.forPlatform(SettingsRepository settings) {
    final supported = !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    return DeviceCalendarService(settings, api: supported ? PluginPhoneCalendarApi() : null);
  }

  bool get isSupported => _api != null;

  Set<String> _selected = {};
  Set<String> get selected => _selected;

  /// Names of the selected calendars, for display (filled by [calendars]).
  final Map<String, PhoneCalendar> _known = {};

  Future<void> load() async {
    final saved = await _settings.get(_kSelected);
    _selected = saved == null ? {} : (jsonDecode(saved) as List).cast<String>().toSet();
  }

  Future<bool> hasAccess() async => _api != null && await _api.hasAccess();

  /// Asks for access and lists the calendars; null if access is refused.
  Future<List<PhoneCalendar>?> requestCalendars() async {
    final api = _api;
    if (api == null || !await api.requestAccess()) return null;
    final list = await api.calendars();
    _known
      ..clear()
      ..addEntries(list.map((c) => MapEntry(c.id, c)));
    return list;
  }

  /// The selected phone calendars (empty if none, or access was withdrawn).
  Future<List<CalendarInfo>> selectedCalendars() async {
    final api = _api;
    if (api == null || _selected.isEmpty) return const [];
    try {
      if (!await api.hasAccess()) return const [];
      return [
        for (final c in await api.calendars())
          if (_selected.contains(c.id)) CalendarInfo('phone:${c.id}', c.name, c.color),
      ];
    } catch (e) {
      debugPrint('listing phone calendars failed: $e');
      return const [];
    }
  }

  /// The selected phone calendars that events can be added to.
  Future<List<CalendarInfo>> writableCalendars() async {
    final api = _api;
    if (api == null || _selected.isEmpty) return const [];
    try {
      if (!await api.hasAccess()) return const [];
      return [
        for (final c in await api.calendars())
          if (_selected.contains(c.id) && !c.readOnly) CalendarInfo('phone:${c.id}', c.name, c.color),
      ];
    } catch (e) {
      debugPrint('listing phone calendars failed: $e');
      return const [];
    }
  }

  /// Adds [event] to the phone calendar [calendarId] and returns the id of the new event.
  Future<String> createEvent(String calendarId, NewEvent event) async {
    final api = _api;
    if (api == null) throw StateError(tr('This device has no calendars to write to.'));
    final id = await api.createEvent(calendarId, event);
    _cache.clear();
    notifyListeners();
    return id;
  }

  Future<void> deleteEvent(String eventId) async {
    await _api?.deleteEvent(eventId);
    _cache.clear();
    notifyListeners();
  }

  Future<void> setSelected(Set<String> ids) async {
    _selected = ids;
    await _settings.set(_kSelected, jsonEncode(ids.toList()));
    _cache.clear();
    notifyListeners();
  }

  final Map<String, List<DayEvent>> _cache = {};

  /// Events of the selected calendars between [from] and [to]. Empty (and
  /// silent) if nothing is selected, access was withdrawn, or on any failure.
  Future<List<DayEvent>> events(DateTime from, DateTime to) async {
    final api = _api;
    if (api == null || _selected.isEmpty) return const [];
    final key = '${from.toIso8601String()}|${to.toIso8601String()}';
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      if (!await api.hasAccess()) return const [];
      if (_known.isEmpty) {
        for (final c in await api.calendars()) {
          _known[c.id] = c;
        }
      }
      final found = await api.events(from, to, _selected.toList());
      return _cache[key] = [for (final e in found) _toDayEvent(e)];
    } catch (e) {
      debugPrint('reading phone calendars failed: $e');
      return const [];
    }
  }

  DayEvent _toDayEvent(PhoneEvent e) {
    final calendar = _known[e.calendarId];
    DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
    // the plugin's end is exclusive; the view wants the last day for all-day events
    final endDay = day(e.end);
    final inclusiveEnd = e.allDay ? DateTime(endDay.year, endDay.month, endDay.day - 1) : e.end;
    return DayEvent(
      title: e.title,
      start: e.allDay ? day(e.start) : e.start,
      end: e.allDay && !inclusiveEnd.isAfter(day(e.start)) ? null : inclusiveEnd,
      allDay: e.allDay,
      calendarName: calendar?.name ?? 'Phone',
      color: calendar?.color,
      repeats: e.repeats,
      calendarKey: 'phone:${e.calendarId}',
      uid: e.id,
    );
  }
}
