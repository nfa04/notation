import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/settings_repository.dart';
import '../data/style_repository.dart';
import '../data/task_repository.dart';
import '../sync/caldav_remote.dart';
import 'app_theme.dart';
import 'calendar_style.dart';

/// Everything needed to draw one item, after the levels were combined.
class ResolvedStyle {
  final Color color;
  final BorderKind border;
  final double borderWidth;
  final double radius;
  final String? emoji;

  const ResolvedStyle({
    required this.color,
    required this.border,
    required this.borderWidth,
    required this.radius,
    this.emoji,
  });

  /// "🌸 Title" when there is an emoji.
  String label(String title) => emoji == null || emoji!.isEmpty ? title : '$emoji $title';
}

/// Holds the theme and the looks of individual items and combines them.
///
/// An item's own look wins over its calendar's, which wins over the theme.
/// All of it stays on this device: nothing here is sent to a server.
class StyleService extends ChangeNotifier {
  static const _kTheme = 'calendar_theme';

  final StyleRepository? _repo;
  final SettingsRepository? _settings;

  /// Tasks without a colour of their own take the app's accent.
  final AppTheme app;

  StyleService(StyleRepository this._repo, SettingsRepository this._settings, this.app) {
    app.addListener(notifyListeners); // the accent changed: tasks change colour
  }

  /// Keeps everything in memory only: for previews and tests.
  StyleService.inMemory([AppTheme? app])
      : _repo = null,
        _settings = null,
        app = app ?? AppTheme.inMemory() {
    this.app.addListener(notifyListeners);
  }

  @override
  void dispose() {
    app.removeListener(notifyListeners);
    super.dispose();
  }

  CalendarTheme _theme = CalendarTheme.standard;
  CalendarTheme get theme => _theme;

  Map<StyleScope, Map<String, ItemStyle>> _items = {for (final s in StyleScope.values) s: {}};

  Future<void> load() async {
    if (_repo == null) return;
    final saved = await _settings!.get(_kTheme);
    if (saved != null) {
      try {
        _theme = CalendarTheme.fromJson((jsonDecode(saved) as Map).cast<String, Object?>());
      } catch (_) {
        _theme = CalendarTheme.standard; // unreadable: start over rather than not start
      }
    }
    _items = await _repo.loadAll();
  }

  /// The page background to use: the chosen tint, darkened in dark mode so
  /// that light text stays readable. Null = the app's usual background.
  Color? backgroundFor(Brightness brightness) {
    final bg = _theme.background;
    if (bg == null) return null;
    return brightness == Brightness.dark ? Color.lerp(bg, Colors.black, 0.86) : bg;
  }

  Future<void> setTheme(CalendarTheme theme) async {
    if (theme == _theme) return;
    _theme = theme;
    notifyListeners();
    await _settings?.set(_kTheme, jsonEncode(theme.toJson()));
  }

  // ---- individual looks ------------------------------------------------------

  ItemStyle? styleOf(StyleScope scope, String key) => _items[scope]![key];

  Future<void> setStyle(StyleScope scope, String key, ItemStyle? style) async {
    if (style == null || style.isEmpty) {
      _items[scope]!.remove(key);
    } else {
      _items[scope]![key] = style;
    }
    notifyListeners();
    await _repo?.save(scope, key, style);
  }

  /// Removes all customisation (the theme stays).
  Future<void> resetItems() async {
    for (final s in StyleScope.values) {
      _items[s]!.clear();
      await _repo?.clearScope(s);
    }
    notifyListeners();
  }

  // ---- resolving -------------------------------------------------------------

  static String eventKey(DayEvent e) => '${e.calendarKey}|${e.uid}';

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The colour a calendar gets when nobody chose one: from the theme's
  /// palette, always the same one for the same calendar.
  Color paletteColor(String key) => _theme.palette[stableHash(key) % _theme.palette.length];

  Color _calendarColor(String key, String? serverColor, {bool own = true}) {
    final chosen = own ? styleOf(StyleScope.calendar, key)?.color : null;
    if (chosen != null) return chosen;
    final server = parseCalendarColor(serverColor);
    return _theme.paletteOverridesServerColors || server == null ? paletteColor(key) : server;
  }

  /// [ownLook] false leaves out what the user chose for the calendar itself:
  /// the fallback that the style dialog shows.
  ResolvedStyle resolveCalendar(String key, {String? serverColor, bool ownLook = true}) {
    final cal = ownLook ? styleOf(StyleScope.calendar, key) : null;
    return ResolvedStyle(
      color: _calendarColor(key, serverColor, own: ownLook),
      border: cal?.border ?? _theme.border,
      borderWidth: _theme.borderWidth,
      radius: _theme.radius,
      emoji: cal?.emoji,
    );
  }

  ResolvedStyle resolveEvent(DayEvent e) {
    final cal = resolveCalendar(e.calendarKey, serverColor: e.color);
    final own = styleOf(StyleScope.event, eventKey(e));
    return ResolvedStyle(
      color: own?.color ?? cal.color,
      border: own?.border ?? cal.border,
      borderWidth: cal.borderWidth,
      radius: cal.radius,
      emoji: (own?.emoji != null && own!.emoji!.isNotEmpty) ? own.emoji : cal.emoji,
    );
  }

  /// An event without its own look (the calendar's still applies).
  ResolvedStyle defaultEventStyle(DayEvent e) => resolveCalendar(e.calendarKey, serverColor: e.color);

  /// A task or day without its own look.
  ResolvedStyle get defaultItemStyle => ResolvedStyle(
        color: app.accent,
        border: _theme.border,
        borderWidth: _theme.borderWidth,
        radius: _theme.radius,
      );

  ResolvedStyle resolveTask(Task t) {
    final own = styleOf(StyleScope.task, t.id);
    return ResolvedStyle(
      color: own?.color ?? app.accent,
      border: own?.border ?? _theme.border,
      borderWidth: _theme.borderWidth,
      radius: _theme.radius,
      emoji: own?.emoji,
    );
  }

  /// The look given to [day] itself (a sticker and a tint), if any.
  ItemStyle? dayStyle(DateTime day) => styleOf(StyleScope.day, dayKey(day));
}
