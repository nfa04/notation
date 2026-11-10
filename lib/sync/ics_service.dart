import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data' show BytesBuilder;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'caldav_remote.dart' show CalendarInfo, DayEvent;
import 'ics.dart';
import '../l10n/language.dart';

/// A calendar the user imported from an `.ics` file, or follows by link.
class IcsSource {
  final String id;
  final String name;
  final String? color;

  /// Set for a calendar followed by link: it is fetched again now and then.
  final String? url;
  final int eventCount;
  final DateTime importedAt;

  const IcsSource({
    required this.id,
    required this.name,
    this.color,
    this.url,
    required this.eventCount,
    required this.importedAt,
  });

  String get key => 'ics:$id';
}

/// Fetches the text at [url]; tests pass a fake.
typedef IcsFetch = Future<String> Function(Uri url);

/// The most a calendar may be: a link that leads to something else (a video, say) is not read to the end.
const _maxCalendarBytes = 20 << 20;

Future<String> _fetchWithDio(Uri url) async {
  final response = await Dio(BaseOptions(connectTimeout: const Duration(seconds: 20))).getUri<ResponseBody>(
    url,
    options: Options(
      responseType: ResponseType.stream,
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept': 'text/calendar, */*'},
    ),
  );
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.data!.stream) {
    bytes.add(chunk);
    if (bytes.length > _maxCalendarBytes) throw StateError(tr('This calendar is too big.'));
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

/// Calendars from `.ics` files and links as a source of events for the calendar
/// view, next to the CalDAV server and the phone's own calendars. Read-only; the
/// events never leave this device.
class IcsCalendarService extends ChangeNotifier {
  final Database _db;
  final IcsFetch _fetch;
  final DateTime Function() _now;

  /// How old a followed calendar may get before it is fetched again.
  final Duration refreshAfter;

  IcsCalendarService(this._db,
      {IcsFetch? fetch, DateTime Function()? now, this.refreshAfter = const Duration(hours: 6)})
      : _fetch = fetch ?? _fetchWithDio,
        _now = now ?? DateTime.now;

  List<IcsSource> _sources = [];
  List<IcsSource> get sources => List.unmodifiable(_sources);
  bool get isEmpty => _sources.isEmpty;

  final Map<String, IcsCalendar> _parsed = {};
  final Map<String, List<DayEvent>> _cache = {};

  Future<void> load() async {
    final rows = await _db.query('ics_calendars',
        columns: ['id', 'name', 'color', 'url', 'event_count', 'imported_at'], orderBy: 'imported_at');
    _sources = [
      for (final r in rows)
        IcsSource(
          id: r['id'] as String,
          name: r['name'] as String,
          color: r['color'] as String?,
          url: r['url'] as String?,
          eventCount: r['event_count'] as int,
          importedAt: DateTime.fromMillisecondsSinceEpoch(r['imported_at'] as int),
        ),
    ];
    notifyListeners();
  }

  void _changed() {
    _cache.clear();
    notifyListeners();
  }

  // ---- importing -----------------------------------------------------------

  /// Imports the text of an `.ics` file. [fileName] gives the calendar its name
  /// when the file has none. A file imported again (same name) replaces the
  /// earlier import. Throws [FormatException] if there is nothing to import.
  Future<IcsSource> importFile(String fileName, String content) async {
    final calendar = parseIcs(content);
    if (calendar.events.isEmpty) {
      throw FormatException(tr('There are no events in this file. Is it an .ics calendar?'));
    }
    final base = fileName.replaceAll(RegExp(r'\.(ics|ical|ifb)$', caseSensitive: false), '').trim();
    final name = calendar.name ?? (base.isEmpty ? 'Imported calendar' : base);
    final existing = _sources.where((s) => s.url == null && s.name == name).firstOrNull;
    return _store(existing?.id, name, calendar, content, null);
  }

  /// Follows the calendar at [address] (`webcal://` works too): it is read now
  /// and again when it has got old.
  Future<IcsSource> addLink(String address) async {
    final url = _addressOf(address);
    final content = await _fetch(url);
    final calendar = parseIcs(content);
    if (calendar.events.isEmpty) {
      throw FormatException(tr('There are no events at this address. Is it a link to an .ics calendar?'));
    }
    final existing = _sources.where((s) => s.url == url.toString()).firstOrNull;
    final name = existing?.name ?? calendar.name ?? (url.host.isEmpty ? 'Linked calendar' : url.host);
    return _store(existing?.id, name, calendar, content, url.toString());
  }

  static Uri _addressOf(String address) {
    var text = address.trim();
    if (text.toLowerCase().startsWith('webcal://')) text = 'https://${text.substring(9)}';
    final url = Uri.tryParse(text);
    if (url == null || !(url.scheme == 'http' || url.scheme == 'https') || url.host.isEmpty) {
      throw FormatException(tr('Enter an address that starts with https:// or webcal://'));
    }
    return url;
  }

  Future<IcsSource> _store(String? id, String name, IcsCalendar calendar, String content, String? url) async {
    final keptColor = id == null ? null : _sources.firstWhere((s) => s.id == id).color;
    final row = {
      'name': name,
      'color': keptColor ?? calendar.color,
      'url': url,
      'content': content,
      'event_count': calendar.events.length,
      'imported_at': _now().millisecondsSinceEpoch,
    };
    final newId = id ?? 'ics-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 20).toRadixString(36)}';
    if (id == null) {
      await _db.insert('ics_calendars', {'id': newId, ...row});
    } else {
      await _db.update('ics_calendars', row, where: 'id = ?', whereArgs: [id]);
    }
    _parsed[newId] = calendar;
    await load();
    _changed();
    return _sources.firstWhere((s) => s.id == newId);
  }

  /// Fetches a followed calendar again. A failure keeps what was there and is thrown.
  Future<void> refresh(String id) async {
    final source = _sources.where((s) => s.id == id).firstOrNull;
    if (source?.url == null) return;
    await addLink(source!.url!);
  }

  /// Fetches the followed calendars that have got old; quiet about failures.
  Future<void> refreshStale() async {
    for (final s in List.of(_sources)) {
      if (s.url == null || _now().difference(s.importedAt) < refreshAfter) continue;
      try {
        await refresh(s.id);
      } catch (e) {
        debugPrint('updating the calendar ${s.name} failed: $e');
      }
    }
  }

  Future<void> rename(String id, String name) async {
    if (name.trim().isEmpty) return;
    await _db.update('ics_calendars', {'name': name.trim()}, where: 'id = ?', whereArgs: [id]);
    await load();
    _changed();
  }

  Future<void> remove(String id) async {
    await _db.delete('ics_calendars', where: 'id = ?', whereArgs: [id]);
    _parsed.remove(id);
    await load();
    _changed();
  }

  // ---- reading -------------------------------------------------------------

  Future<IcsCalendar> _calendar(String id) async {
    final known = _parsed[id];
    if (known != null) return known;
    final rows = await _db.query('ics_calendars', columns: ['content'], where: 'id = ?', whereArgs: [id]);
    return _parsed[id] = parseIcs(rows.isEmpty ? '' : rows.single['content'] as String);
  }

  /// The calendars, for giving each its own look in the settings under Sharing and files.
  List<CalendarInfo> calendarInfos() => [for (final s in _sources) CalendarInfo(s.key, s.name, s.color)];

  /// Events of all imported calendars between [from] and [to]. A calendar that
  /// cannot be read is left out.
  Future<List<DayEvent>> events(DateTime from, DateTime to) async {
    if (_sources.isEmpty) return const [];
    final cacheKey = '${from.toIso8601String()}|${to.toIso8601String()}';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;
    final out = <DayEvent>[];
    for (final s in List.of(_sources)) {
      try {
        out.addAll(expandIcs(await _calendar(s.id), from, to, calendarName: s.name, key: s.key, color: s.color));
      } catch (e) {
        debugPrint('reading the calendar ${s.name} failed: $e');
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return _cache[cacheKey] = out;
  }
}
