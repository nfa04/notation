import 'dart:convert';

import '../data/note_repository.dart';

import 'package:caldav/caldav.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/settings_repository.dart';
import '../data/task_repository.dart';
import 'caldav_connect.dart';
import 'caldav_remote.dart';
import 'task_sync.dart';
import '../l10n/language.dart';
import '../data/app_secure_storage.dart';

/// Where the account password is kept: the platform keystore.
abstract class SecretStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// [SecretStore] in the secure storage of the system (the password of the CalDAV account).
class KeystoreSecretStore implements SecretStore {
  final String _key;
  final FlutterSecureStorage _storage;

  const KeystoreSecretStore([this._storage = appSecureStorage, this._key = 'caldav_password']);

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// The saved, non-secret part of the account.
class CalDavConfig {
  final String serverUrl;
  final String username;

  /// `href` of the calendar the tasks sync with.
  final String? taskCalendar;

  /// `href`s of the calendars whose events are shown.
  final Set<String> eventCalendars;

  const CalDavConfig({
    required this.serverUrl,
    required this.username,
    this.taskCalendar,
    this.eventCalendars = const {},
  });
}

/// Connects the app to a CalDAV server (tested against the Nextcloud layout):
/// two-way sync of the tasks with one calendar, and the events of chosen
/// calendars for the month view. Everything else in the app works without it.
class CalDavService extends ChangeNotifier {
  final SettingsRepository _settings;
  final TaskRepository _tasks;
  final SecretStore _secret;

  /// [allowInsecure] is for tests against a local server only.
  CalDavService(this._settings, this._tasks,
      {SecretStore secret = const KeystoreSecretStore(), bool allowInsecure = false})
      : _secret = secret,
        _allowInsecure = allowInsecure;

  final bool _allowInsecure;

  static const _kUrl = 'caldav_url';
  static const _kUser = 'caldav_user';
  static const _kTaskCal = 'caldav_task_calendar';
  static const _kEventCals = 'caldav_event_calendars';
  static const _kLastSync = 'caldav_last_sync';

  CalDavConfig? _config;
  CalDavConfig? get config => _config;

  /// The login for things other than calendars on the same server (sharing a note); null if not connected.
  Future<({String serverUrl, String username, String password})?> login() async {
    final c = _config;
    final password = c == null ? null : await _secret.read();
    return c == null || password == null ? null : (serverUrl: c.serverUrl, username: c.username, password: password);
  }
  bool get isConnected => _config != null;

  bool _syncing = false;
  bool get syncing => _syncing;

  DateTime? lastSync;

  /// Outcome of the last sync, for display; [lastSyncFailed] if it did not work.
  String? lastMessage;
  bool lastSyncFailed = false;

  CalDavClient? _client;
  final Map<String, List<DayEvent>> _events = {};

  Future<void> load() async {
    final url = await _settings.get(_kUrl);
    final user = await _settings.get(_kUser);
    if (url == null || user == null) return;
    final events = await _settings.get(_kEventCals);
    _config = CalDavConfig(
      serverUrl: url,
      username: user,
      taskCalendar: await _settings.get(_kTaskCal),
      eventCalendars: events == null ? {} : (jsonDecode(events) as List).cast<String>().toSet(),
    );
    final last = await _settings.get(_kLastSync);
    lastSync = last == null ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(last));
    notifyListeners();
  }

  // ---- connecting ----------------------------------------------------------

  /// Logs in and lists the server's calendars, without saving anything.
  /// Returns the address that worked: for Nextcloud it is found automatically,
  /// whether the user typed the site or a longer link from the browser.
  Future<({String serverUrl, List<Calendar> calendars})> testConnection(
      String serverUrl, String username, String password,
      {bool allowInsecure = false}) async {
    final connection = await connectToServer(serverUrl, username, password, allowInsecure: allowInsecure || _allowInsecure,);
    try {
      return (serverUrl: connection.endpoint, calendars: await connection.client.getCalendars());
    } finally {
      connection.client.close();
    }
  }

  Future<void> save(String serverUrl, String username, String password,
      {required String? taskCalendar, required Set<String> eventCalendars}) async {
    // the password first, and read back: an address and a user without a password that can be read would look like a connected account
    // and then fail on every request (a keystore that is locked or gone may take a write and give nothing back)
    await _secret.write(password);
    if (await _secret.read() != password) {
      throw StateError(
        tr(
          'The system keystore did not keep the password, so the account was not saved. Is the keyring unlocked?',
        ),
      );
    }
    await _settings.set(_kUrl, serverUrl);
    await _settings.set(_kUser, username);
    if (taskCalendar == null) {
      await _settings.remove(_kTaskCal);
    } else {
      await _settings.set(_kTaskCal, taskCalendar);
    }
    await _settings.set(_kEventCals, jsonEncode(eventCalendars.toList()));
    _config = CalDavConfig(
        serverUrl: serverUrl, username: username, taskCalendar: taskCalendar, eventCalendars: eventCalendars);
    _closeClient();
    _events.clear();
    notifyListeners();
  }

  /// Removes the account. Local tasks stay; they are just no longer linked to
  /// the server.
  Future<void> disconnect() async {
    for (final k in [_kUrl, _kUser, _kTaskCal, _kEventCals, _kLastSync]) {
      await _settings.remove(k);
    }
    await _secret.delete();
    await _tasks.detachFromServer();
    _config = null;
    lastSync = null;
    lastMessage = null;
    lastSyncFailed = false;
    _closeClient();
    _events.clear();
    _tasks.clearEventCache().catchError((Object _) {});
    notifyListeners();
  }

  Future<CalDavClient> _connected() async {
    final existing = _client;
    if (existing != null) return existing;
    final c = _config!;
    final password = await _secret.read();
    if (password == null) throw StateError(tr('The saved password is missing: connect again.'));
    return _client = await openCalDavClient(c.serverUrl, c.username, password,
        knownEndpoint: c.serverUrl.endsWith('/remote.php/dav'), allowInsecure: _allowInsecure);
  }

  void _closeClient() {
    _client?.close();
    _client = null;
  }

  Calendar? _find(List<Calendar> all, String? href) {
    for (final c in all) {
      if (c.href.toString() == href) return c;
    }
    return null;
  }

  // ---- tasks ---------------------------------------------------------------

  /// Syncs the tasks now; does nothing if not connected or already running.
  Future<SyncReport?> sync() async {
    final c = _config;
    if (c == null || c.taskCalendar == null || _syncing) return null;
    _syncing = true;
    notifyListeners();
    try {
      final client = await _connected();
      final calendar = _find(await client.getCalendars(), c.taskCalendar);
      if (calendar == null) throw StateError(tr('The task calendar no longer exists on the server.'));
      final report = await syncTasks(_tasks, CalDavRemoteTodos(client, calendar));
      lastSync = DateTime.now();
      await _settings.set(_kLastSync, '${lastSync!.millisecondsSinceEpoch}');
      lastSyncFailed = report.hasProblems;
      lastMessage = report.hasProblems ? tr('Synced with problems: {error}', {'error': report.errors.first}) : tr('Synced: {report}', {'report': report});
      if (report.conflicts.isNotEmpty) {
        lastMessage = tr('{message}. Changed in both places, server version kept: {titles}', {'message': lastMessage, 'titles': report.conflicts.join(', ')});
      }
      _events.clear();
      return report;
    } catch (e) {
      _closeClient(); // the connection may be what is broken
      lastSyncFailed = true;
      lastMessage = tr('Sync failed: {error}', {'error': _describe(e)});
      return null;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  // ---- events --------------------------------------------------------------

  /// The calendars whose events are shown (empty if not connected or on any failure).
  Future<List<CalendarInfo>> eventCalendars() async {
    final c = _config;
    if (c == null || c.eventCalendars.isEmpty) return const [];
    try {
      final all = await (await _connected()).getCalendars();
      return [
        for (final cal in all)
          if (c.eventCalendars.contains(cal.href.toString())) CalendarInfo(cal.href.toString(), cal.displayName, cal.color, readOnly: cal.isReadOnly),
      ];
    } catch (e) {
      debugPrint('listing calendars failed: $e');
      return const [];
    }
  }

  static String _rangeKey(DateTime from, DateTime to) => '${from.millisecondsSinceEpoch}|${to.millisecondsSinceEpoch}';

  /// What the server answered last time for these days, from the database: shown at once while the server is asked again
  /// ([events]). Null if nothing was kept.
  Future<List<DayEvent>?> cachedEvents(DateTime from, DateTime to) async {
    final c = _config;
    if (c == null || c.eventCalendars.isEmpty) return null;
    try {
      final kept = await _tasks.cachedEvents(_cacheSource, _rangeKey(from, to));
      if (kept == null) return null;
      return [for (final j in jsonDecode(kept.payload) as List) DayEvent.fromJson((j as Map).cast<String, Object?>())];
    } catch (e) {
      debugPrint('reading the kept events failed: $e');
      return null;
    }
  }

  /// The key of the kept events: they belong to the account and the calendars that are shown.
  String get _cacheSource {
    final c = _config!;
    return 'caldav:${c.serverUrl}|${c.username}|${(c.eventCalendars.toList()..sort()).join(',')}';
  }

  /// Events of the chosen calendars in [from] to [to] (cached until the next
  /// sync; [fresh] asks the server regardless). The answer is kept in the database for [cachedEvents]; when the
  /// server cannot be reached, what was kept is given. Failures give an empty list: events are a nice-to-have.
  Future<List<DayEvent>> events(DateTime from, DateTime to, {bool fresh = false}) async {
    final c = _config;
    if (c == null || c.eventCalendars.isEmpty) return const [];
    final key = '${from.toIso8601String()}|${to.toIso8601String()}';
    final cached = fresh ? null : _events[key];
    if (cached != null) return cached;
    try {
      final client = await _connected();
      final all = await client.getCalendars();
      final result = <DayEvent>[];
      for (final href in c.eventCalendars) {
        final calendar = _find(all, href);
        if (calendar == null) continue;
        final found = await client.getEvents(calendar, start: from.toUtc(), end: to.toUtc());
        result.addAll(found.map((e) => DayEvent.from(e, calendar)));
      }
      result.sort((a, b) => a.start.compareTo(b.start));
      _tasks.cacheEvents(_cacheSource, _rangeKey(from, to), jsonEncode([for (final e in result) e.toJson()])).catchError((Object _) {});
      return _events[key] = result;
    } catch (e) {
      debugPrint('loading events failed: $e');
      return await cachedEvents(from, to) ?? const [];
    }
  }

  // ---- writing events -------------------------------------------------------

  /// The shown calendars that events can be added to.
  Future<List<CalendarInfo>> writableCalendars() async => [for (final c in await eventCalendars()) if (!c.readOnly) c];

  /// Adds [event] to the calendar at [calendarHref] and returns the address of the new event on the server.
  Future<String> createEvent(String calendarHref, NewEvent event) async {
    final client = await _connected();
    final calendar = _find(await client.getCalendars(), calendarHref);
    if (calendar == null) throw StateError(tr('That calendar no longer exists on the server.'));
    DateTime plain(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    final created = await client.createEvent(
      calendar,
      CalendarEvent(
        uid: NoteRepository.newId(),
        calendarId: calendar.uid,
        summary: event.title,
        description: event.description.isEmpty ? null : event.description,
        isAllDay: event.allDay,
        start: event.allDay ? plain(event.start) : event.start.toUtc(),
        end: event.allDay
            ? (event.end == null || !plain(event.end!).isAfter(plain(event.start)) ? null : plain(event.end!))
            : (event.end ?? event.start.add(const Duration(hours: 1))).toUtc(),
      ),
    );
    _forgetEvents();
    return created.href.toString();
  }

  /// Removes the event at [href] (what [createEvent] returned); one that is gone already is fine.
  Future<void> deleteEvent(String calendarHref, String href) async {
    final client = await _connected();
    final calendar = _find(await client.getCalendars(), calendarHref);
    if (calendar == null) return;
    await client.deleteEvent(CalendarEvent(uid: '', calendarId: calendar.uid, href: Uri.parse(href), start: DateTime.now().toUtc(), summary: ''));
    _forgetEvents();
  }

  void _forgetEvents() {
    _events.clear();
    _tasks.clearEventCache().catchError((Object _) {});
    notifyListeners();
  }

  static String _describe(Object e) {
    if (e is AuthenticationException) return tr('wrong user name or password.');
    if (e is CalDavException) return e.message;
    if (e is CalDavConnectError) return e.toString();
    return '$e';
  }

  /// A readable message for errors from [testConnection].
  static String describeError(Object e) => _describe(e);

  @override
  void dispose() {
    _closeClient();
    super.dispose();
  }
}
