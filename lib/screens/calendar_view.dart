import 'dart:async';
import '../l10n/language.dart';

import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

import '../data/debounced_changes.dart';
import '../data/task_repository.dart';
import '../sync/caldav_remote.dart';
import '../sync/caldav_service.dart';
import '../sync/device_calendar_service.dart';
import '../sync/ics_service.dart';
import '../data/style_repository.dart';
import '../style/calendar_style.dart';
import '../style/style_dialog.dart';
import '../style/style_service.dart';
import '../style/styled_box.dart';
import 'calendar_customize_screen.dart';
import 'caldav_settings_screen.dart';
import 'week_view.dart';
import 'event_dialogs.dart';
import '../sync/task_calendar_mirror.dart';
import '../reminders/reminder.dart';
import '../reminders/reminder_service.dart';
import 'reminders_screen.dart';
import '../style/platform_dialog.dart';

/// Month calendar on the left, tasks on the right.
class CalendarView extends StatefulWidget {
  final TaskRepository repository;

  /// Optional: without it the calendar works on local tasks only.
  final CalDavService? caldav;

  /// Optional: events from the phone's own calendars (Android and iOS).
  final DeviceCalendarService? device;
  final IcsCalendarService? ics;

  /// Colours, borders and emoji; without it the calendar keeps the classic look.
  final StyleService? style;

  /// Puts tasks on a calendar as events; null: not offered.
  final TaskCalendarMirror? mirror;

  /// "Remind me" on a task (it can come back every day, week...); null: not offered.
  final ReminderService? reminders;

  const CalendarView({super.key, required this.repository, this.caldav, this.device, this.ics, this.style, this.mirror, this.reminders});

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _formatDay(DateTime d) => tr('{weekday}, {day} {month} {year}',
    {'weekday': tr(_weekdayNames[d.weekday - 1]), 'day': d.day, 'month': tr(_monthNames[d.month - 1]), 'year': d.year});

class _CalendarViewState extends State<CalendarView> {
  List<Task> _tasks = [];
  bool _loaded = false;
  late DateTime _month = DateTime(dayOf(DateTime.now()).year, dayOf(DateTime.now()).month);
  DateTime _selected = dayOf(DateTime.now());
  final _newTask = TextEditingController();

  List<DayEvent> _events = [];
  bool _weekMode = false;
  int _loadToken = 0;
  Timer? _syncTimer;
  DateTime? _seenSync;

  CalDavService? get _caldav => widget.caldav;

  late final StyleService _style = widget.style ?? StyleService.inMemory();

  TaskRepository get _repo => widget.repository;

  /// Loads the tasks again when they change under the list (an agent, a sync).
  StreamSubscription<void>? _live;

  @override
  void initState() {
    super.initState();
    _reload();
    _live = debouncedChanges([_repo.changes]).listen((_) {
      if (mounted) _reload();
    });
    _seenSync = _caldav?.lastSync;
    _caldav?.addListener(_onServiceChanged);
    widget.device?.addListener(_loadEvents);
    widget.ics?.addListener(_loadEvents);
    widget.ics?.refreshStale(); // followed calendars that got old
    _style.addListener(_onStyleChanged);
    if (_caldav?.isConnected == true) _caldav!.sync(); // catch up when the tab is opened
    _loadEvents(revalidate: true);
    widget.mirror?.addListener(_onStyleChanged);
    widget.mirror?.runSoon();
  }

  @override
  void dispose() {
    _live?.cancel();
    widget.mirror?.removeListener(_onStyleChanged);
    _syncTimer?.cancel();
    _caldav?.removeListener(_onServiceChanged);
    widget.device?.removeListener(_loadEvents);
    widget.ics?.removeListener(_loadEvents);
    _style.removeListener(_onStyleChanged);
    _newTask.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final tasks = await _repo.listTasks();
    if (mounted) {
      setState(() {
      _tasks = tasks;
      _loaded = true;
    });
    }
  }

  void _onStyleChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openCustomize() => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => CalendarCustomizeScreen(style: _style, caldav: _caldav, device: widget.device, ics: widget.ics)));

  // ---- custom looks ----------------------------------------------------------

  Future<void> _styleEvent(DayEvent e) async {
    if (e.uid.isEmpty) return;
    final key = StyleService.eventKey(e);
    final result = await showStyleDialog(
      context,
      title: 'Style this event',
      sample: e.title,
      initial: _style.styleOf(StyleScope.event, key) ?? const ItemStyle(),
      base: _style.defaultEventStyle(e),
    );
    if (result != null) await _style.setStyle(StyleScope.event, key, result);
  }

  Future<void> _styleTask(Task t) async {
    final result = await showStyleDialog(
      context,
      title: 'Style this task',
      sample: t.title,
      initial: _style.styleOf(StyleScope.task, t.id) ?? const ItemStyle(),
      base: _style.defaultItemStyle,
    );
    if (result != null) await _style.setStyle(StyleScope.task, t.id, result);
  }

  Future<void> _styleDay(DateTime day) async {
    final key = StyleService.dayKey(day);
    final result = await showStyleDialog(
      context,
      title: 'Decorate this day',
      sample: _formatDay(day),
      initial: _style.styleOf(StyleScope.day, key) ?? const ItemStyle(),
      base: _style.defaultItemStyle,
      showBorder: false,
    );
    if (result != null) await _style.setStyle(StyleScope.day, key, result);
  }

  /// Long press (touch) or right click (mouse) opens the style dialog.
  Widget _stylable(VoidCallback onStyle, Widget child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: onStyle,
        onSecondaryTap: onStyle,
        child: child,
      );

  /// A sync finished (or the account changed): show what it brought.
  void _onServiceChanged() {
    if (!mounted) return;
    final sync = _caldav!.lastSync;
    if (sync != _seenSync || !_caldav!.isConnected) {
      _seenSync = sync;
      _reload();
      _loadEvents();
    }
    setState(() {});
  }

  /// The Monday of the week that contains the selected day.
  DateTime get _weekStart => DateTime(_selected.year, _selected.month, _selected.day - (_selected.weekday - 1));

  /// The days the current view shows: the month grid or the week.
  (DateTime, DateTime) get _visibleRange {
    if (_weekMode) {
      final start = _weekStart;
      return (start, DateTime(start.year, start.month, start.day + 7));
    }
    final days = monthGrid(_month);
    return (days.first, days.last.add(const Duration(days: 1)));
  }

  /// Calendars that events can be added to (server and phone), as far as known.
  List<CalendarInfo> _writable = [];

  /// Loads the events of the days shown. What the server answered last time comes first, from the database, so that the
  /// calendar is not empty while the server is asked; the answer then replaces it ([revalidate]: whatever was kept in memory is not trusted).
  Future<void> _loadEvents({bool revalidate = false}) async {
    final caldav = _caldav?.isConnected == true ? _caldav : null;
    final device = widget.device;
    final (from, to) = _visibleRange;
    final token = ++_loadToken; // a newer request makes this answer obsolete
    final others = Future.wait([
      if (device != null) device.events(from, to),
      if (widget.ics != null) widget.ics!.events(from, to),
    ]);
    List<DayEvent> merge(List<DayEvent> served, List<List<DayEvent>> rest) =>
        [...served, for (final l in rest) ...l]..sort((a, b) => a.start.compareTo(b.start));
    if (caldav != null && (revalidate || _events.isEmpty)) {
      final kept = await caldav.cachedEvents(from, to);
      if (kept != null) {
        final rest = await others;
        if (mounted && token == _loadToken) setState(() => _events = merge(kept, rest));
      }
    }
    final fresh = caldav == null ? const <DayEvent>[] : await caldav.events(from, to, fresh: revalidate);
    final events = merge(fresh, await others);
    if (mounted && token == _loadToken) setState(() => _events = [for (final e in events) if (!_isMirrorOf(e)) e]);
    _loadWritable();
  }

  Future<void> _loadWritable() async {
    final caldav = _caldav?.isConnected == true ? _caldav : null;
    final list = [
      ...?await caldav?.writableCalendars(),
      ...?await widget.device?.writableCalendars(),
    ];
    if (mounted && (list.length != _writable.length || [for (final c in list) c.key].join() != [for (final c in _writable) c.key].join())) {
      setState(() => _writable = list);
    }
  }

  Future<void> _newEvent() async {
    final added = await newEventDialog(context, day: _selected, targets: _writable, save: (target, event) async {
      if (target.key.startsWith('phone:')) {
        await widget.device!.createEvent(target.key.substring('phone:'.length), event);
      } else {
        await _caldav!.createEvent(target.key, event);
      }
    });
    if (added) _loadEvents(revalidate: true);
  }

  /// Events that only show a task that was put on a calendar are not shown twice: the task is shown.
  bool _isMirrorOf(DayEvent e) {
    final target = widget.mirror?.target;
    if (target == null || !e.allDay) return false;
    final here = e.calendarKey.startsWith('phone:') ? e.calendarKey : 'caldav:${e.calendarKey}';
    if (here != target) return false;
    return _tasks.any((t) => !t.done && t.title == e.title && t.dueDate != null && t.dueDate == dayOf(e.start));
  }

  void _setWeekMode(bool week) {
    setState(() {
      _weekMode = week;
      // the month grid follows the selected day
      _month = DateTime(_selected.year, _selected.month);
    });
    _loadEvents();
  }

  /// Moves the selected day by whole weeks.
  void _goToWeek(int weeks) {
    setState(() {
      _selected = DateTime(_selected.year, _selected.month, _selected.day + 7 * weeks);
      _month = DateTime(_selected.year, _selected.month);
    });
    _loadEvents();
  }

  String get _weekTitle {
    final start = _weekStart;
    final end = DateTime(start.year, start.month, start.day + 6);
    final startMonth = tr(_monthNames[start.month - 1]);
    final endMonth = tr(_monthNames[end.month - 1]);
    if (start.month == end.month) return tr('{d1} - {d2} {m2} {y2}', {'d1': start.day, 'd2': end.day, 'm2': endMonth, 'y2': end.year});
    String short(String m) => m.substring(0, 3);
    return start.year == end.year
        ? tr('{d1} {m1} - {d2} {m2} {y2}',
            {'d1': start.day, 'm1': short(startMonth), 'd2': end.day, 'm2': short(endMonth), 'y2': end.year})
        : tr('{d1} {m1} {y1} - {d2} {m2} {y2}', {
            'd1': start.day, 'm1': short(startMonth), 'y1': start.year, 'd2': end.day, 'm2': short(endMonth), 'y2': end.year});
  }

  void _goToMonth(DateTime month) {
    setState(() => _month = DateTime(month.year, month.month));
    _loadEvents();
  }

  /// Local changes reach the server a moment after the last edit.
  void _scheduleSync() {
    if (_caldav?.isConnected != true) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(seconds: 2), () => _caldav?.sync());
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => CalDavSettingsScreen(device: widget.device, ics: widget.ics)));
    _onServiceChanged();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context,).showSnackBar(SnackBar(content: Text.verbatim('$e')));
    }
    await _reload();
    _scheduleSync();
  }

  Future<void> _add() async {
    final title = _newTask.text.trim();
    if (title.isEmpty) return;
    _newTask.clear();
    await _run(() => _repo.createTask(title, dueDate: _selected));
  }

  Future<void> _edit(Task t) async {
    final title = TextEditingController(text: t.title);
    var due = t.dueDate;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => PlatformAlertDialog(
          title: const Text('Edit task'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, autofocus: true, decoration: InputDecoration(labelText: tr('Task'))),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: Text(due == null ? 'No due date' : _formatDay(due!))),
              TextButton(
                child: const Text('Pick date'),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: due ?? _selected,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) setLocal(() => due = dayOf(d));
                },
              ),
              if (due != null) IconButton(icon: const Icon(Icons.clear), tooltip: tr('No date'), onPressed: () => setLocal(() => due = null)),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    final newTitle = title.text.trim();
    title.dispose();
    if (saved == true && newTitle.isNotEmpty) {
      await _run(() => _repo.updateTask(t.id, title: newTitle, dueDate: due));
    }
  }

  // ---- derived data --------------------------------------------------------

  List<Task> _on(DateTime day) => _tasks.where((t) => t.dueDate == day).toList();

  List<Task> get _overdue {
    final today = dayOf(DateTime.now());
    return _tasks.where((t) => !t.done && t.dueDate != null && t.dueDate!.isBefore(today)).toList();
  }

  List<Task> get _undated => _tasks.where((t) => t.dueDate == null).toList();

  // ---- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator.adaptive());
    return Scaffold(
      backgroundColor: _style.backgroundFor(Theme.of(context).brightness),
      appBar: AppBar(
        title: const Text('Calendar', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _style.backgroundFor(Theme.of(context).brightness),
        actions: _narrow ? _compactActions() : [
          if (_writable.isNotEmpty)
            IconButton(
              key: const ValueKey('new-event'),
              icon: const Icon(Icons.event_available_outlined),
              tooltip: tr('New event'),
              onPressed: _newEvent,
            ),
          if (widget.mirror != null)
            IconButton(
              key: const ValueKey('tasks-on-calendar'),
              icon: Icon(widget.mirror!.target == null ? Icons.event_repeat_outlined : Icons.event_repeat),
              tooltip: tr('Put tasks on a calendar'),
              onPressed: () => mirrorDialog(context, widget.mirror!),
            ),
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: tr('Make it cute'),
            onPressed: _openCustomize,
          ),
          if (_caldav != null) ...[
            if (_caldav!.isConnected)
              _caldav!.syncing
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))),
                    )
                  : IconButton(
                      icon: Icon(_caldav!.lastSyncFailed ? Icons.sync_problem : Icons.sync,
                          color: _caldav!.lastSyncFailed ? Theme.of(context).colorScheme.error : null),
                      tooltip: tr('Sync now'),
                      onPressed: _caldav!.sync,
                    ),
            IconButton(
              icon: const Icon(Icons.cloud_outlined),
              tooltip: tr('Calendar sync settings'),
              onPressed: _openSettings,
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: _narrow
          // a phone: the day's list sits under the calendar instead of beside it
          ? Column(
              children: [
                Expanded(flex: 11, child: _buildCalendar()),
                const Divider(height: 1, thickness: 1),
                Expanded(flex: 9, child: _buildTaskPanel()),
              ],
            )
          : Row(
              children: [
                Expanded(child: _buildCalendar()),
                const VerticalDivider(width: 1, thickness: 1),
                SizedBox(width: 380, child: _buildTaskPanel()),
              ],
            ),
    );
  }

  /// A phone's app bar has room for the new-event button, a sync button and a menu with the rest.
  List<Widget> _compactActions() => [
        if (_writable.isNotEmpty) IconButton(key: const ValueKey('new-event'), icon: const Icon(Icons.event_available_outlined), tooltip: tr('New event'), onPressed: _newEvent),
        if (_caldav?.isConnected == true)
          _caldav!.syncing
              ? const Padding(padding: EdgeInsets.symmetric(horizontal: 14), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator.adaptive(strokeWidth: 2))))
              : IconButton(
                  icon: Icon(_caldav!.lastSyncFailed ? Icons.sync_problem : Icons.sync, color: _caldav!.lastSyncFailed ? Theme.of(context).colorScheme.error : null),
                  tooltip: tr('Sync now'),
                  onPressed: _caldav!.sync,
                ),
        PopupMenuButton<VoidCallback>(
          onSelected: (action) => action(),
          itemBuilder: (_) => [
            if (widget.mirror != null) PopupMenuItem(value: () => mirrorDialog(context, widget.mirror!), child: Text(tr('Put tasks on a calendar'))),
            PopupMenuItem(value: _openCustomize, child: Text(tr('Make it cute'))),
            if (_caldav != null) PopupMenuItem(value: _openSettings, child: Text(tr('Calendar sync settings'))),
          ],
        ),
      ];

  bool get _narrow => MediaQuery.sizeOf(context).width < 700;

  Widget _calendarTitle() => Text(
        _weekMode ? _weekTitle : '${tr(_monthNames[_month.month - 1])} ${_month.year}',
        overflow: TextOverflow.ellipsis,
        style: (_narrow ? Theme.of(context).textTheme.titleLarge : Theme.of(context).textTheme.headlineSmall)?.copyWith(fontWeight: FontWeight.bold),
      );

  Widget _modeSwitch() => SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: false, label: Text('Month')),
          ButtonSegment(value: true, label: Text('Week')),
        ],
        selected: {_weekMode},
        onSelectionChanged: (v) => _setWeekMode(v.first),
      );

  List<Widget> _navButtons(DateTime today) => [
        IconButton(
          tooltip: tr(_weekMode ? 'Previous week' : 'Previous month'),
          icon: const Icon(Icons.chevron_left),
          onPressed: () => _weekMode ? _goToWeek(-1) : _goToMonth(DateTime(_month.year, _month.month - 1)),
        ),
        TextButton(
          onPressed: () {
            setState(() => _selected = today);
            _goToMonth(today);
          },
          child: const Text('Today'),
        ),
        IconButton(
          tooltip: tr(_weekMode ? 'Next week' : 'Next month'),
          icon: const Icon(Icons.chevron_right),
          onPressed: () => _weekMode ? _goToWeek(1) : _goToMonth(DateTime(_month.year, _month.month + 1)),
        ),
      ];

  Widget _buildCalendar() {
    final today = dayOf(DateTime.now());
    final days = monthGrid(_month);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.all(_narrow ? 8 : 24),
      child: Column(
        children: [
          if (_narrow) ...[
            Row(children: [
              Expanded(child: _calendarTitle()),
              _modeSwitch(),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: _navButtons(today)),
          ] else
            Row(children: [
              Expanded(child: _calendarTitle()),
              _modeSwitch(),
              const SizedBox(width: 8),
              ..._navButtons(today),
            ]),
          const SizedBox(height: 8),
          if (_weekMode)
            Expanded(
              child: WeekView(
                weekStart: _weekStart,
                selected: _selected,
                today: today,
                events: _events,
                tasks: _tasks,
                onSelectDay: (day) => setState(() => _selected = day),
                onToggleTask: (task, done) => _run(() => _repo.setDone(task.id, done)),
                onEditTask: _edit,
                style: _style,
                onStyleEvent: _styleEvent,
                onStyleTask: _styleTask,
                onStyleDay: _styleDay,
              ),
            )
          else ...[
            Row(children: [
              for (final n in _weekdayNames)
                Expanded(child: Center(child: Text.verbatim(tr(n), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)))),
            ]),
            const SizedBox(height: 4),
            Expanded(
              child: Column(children: [
                for (var week = 0; week < 6; week++)
                  Expanded(
                    child: Row(children: [
                      for (var i = 0; i < 7; i++) Expanded(child: _dayCell(days[week * 7 + i], today, scheme)),
                    ]),
                  ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _dayCell(DateTime day, DateTime today, ColorScheme scheme) {
    final inMonth = day.month == _month.month;
    final isSelected = day == _selected;
    final isToday = day == today;
    final look = _style.dayStyle(day);
    final radius = (_style.theme.radius * 1.2).clamp(4.0, 20.0);

    // what to show in the cell: all-day events, timed events, then tasks
    final events = _events.where((e) => e.occursOn(day)).toList()
      ..sort((a, b) => a.allDay == b.allDay ? a.start.compareTo(b.start) : (a.allDay ? -1 : 1));
    final tasks = _on(day);
    final total = events.length + tasks.length;

    return Padding(
      padding: const EdgeInsets.all(2),
      child: _stylable(
        () => _styleDay(day),
        InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: () {
            setState(() => _selected = day);
            if (!inMonth) _goToMonth(day);
          },
          child: Container(
            padding: EdgeInsets.all(_narrow ? 3 : 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              color: isSelected ? scheme.primaryContainer : look?.color?.withValues(alpha: 0.3),
              border: Border.all(color: isToday ? scheme.primary : Colors.grey.withValues(alpha: 0.2), width: isToday ? 2 : 1),
            ),
            child: _narrow
                // too small for the chips: the day number and a dot for each thing planned
                ? ClipRect(
                    child: Stack(children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        child: Text.verbatim('${day.day}',
                            style: TextStyle(fontSize: 13, height: 1, fontWeight: isToday ? FontWeight.bold : null, color: inMonth ? null : Colors.grey)),
                      ),
                      if (look?.emoji != null) Positioned(right: 0, top: 0, child: Text.verbatim(look!.emoji!, style: const TextStyle(fontSize: 10, height: 1))),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          for (var i = 0; i < total.clamp(0, 4); i++)
                            Container(
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: i < events.length ? scheme.tertiary : scheme.primary),
                            ),
                        ]),
                      ),
                    ]),
                  )
                : LayoutBuilder(builder: (context, box) {
              const header = 20.0, chipHeight = 19.0;
              final fit = ((box.maxHeight - header) / chipHeight).floor();
              // when not everything fits, the last slot says how many more there are
              final shown = total <= fit ? total : (fit - 1).clamp(0, total);
              final items = <Widget>[];
              for (var i = 0; i < shown; i++) {
                items.add(i < events.length ? _eventChip(events[i]) : _taskChip(tasks[i - events.length]));
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: header,
                    child: Row(children: [
                      Text.verbatim('${day.day}',
                          style: TextStyle(
                            fontWeight: isToday ? FontWeight.bold : null,
                            color: inMonth ? null : Colors.grey,
                          )),
                      const Spacer(),
                      if (look?.emoji != null) Text.verbatim(look!.emoji!, style: const TextStyle(fontSize: 14)),
                    ]),
                  ),
                  ...items,
                  if (shown < total)
                    Text(fit >= 1 ? tr('+{n} more', {'n': total - shown}) : '$total', style: TextStyle(fontSize: 10, color: Theme.of(context,).colorScheme.onSurfaceVariant)),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _eventChip(DayEvent e) {
    final st = _style.resolveEvent(e);
    return _stylable(
      () => _styleEvent(e),
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Tooltip(
          message: '${e.title}\n${e.calendarName}',
          child: StyledBox(
            style: st,
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            child: Text.verbatim(st.label(e.title), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, height: 1.25)),
          ),
        ),
      ),
    );
  }

  Widget _taskChip(Task t) {
    final st = _style.resolveTask(t);
    return _stylable(
      () => _styleTask(t),
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: StyledBox(
          style: st,
          fillOpacity: t.done ? 0.12 : 0.28,
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          child: Row(children: [
            Icon(t.done ? Icons.check_circle : Icons.radio_button_unchecked, size: 10, color: st.color),
            const SizedBox(width: 3),
            Expanded(
              child: Text.verbatim(
                st.label(t.title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.25,
                  decoration: t.done ? TextDecoration.lineThrough : null,
                  color: t.done ? Colors.grey : null,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildTaskPanel() {
    final selected = _on(_selected);
    final dayEvents = _events.where((e) => e.occursOn(_selected)).toList();
    final overdue = _overdue.where((t) => t.dueDate != _selected).toList();
    final undated = _undated;

    return ListView(
      padding: EdgeInsets.all(_narrow ? 12 : 20),
      children: [
        Row(children: [
          if (_style.dayStyle(_selected)?.emoji != null) ...[
            Text.verbatim(_style.dayStyle(_selected)!.emoji!, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(_formatDay(_selected), style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            tooltip: tr('Decorate this day'),
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: () => _styleDay(_selected),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _newTask,
          decoration: InputDecoration(
            hintText: tr('Add a task for this day'),
            prefixIcon: const Icon(Icons.add_task),
            suffixIcon: IconButton(icon: const Icon(Icons.send_rounded), tooltip: tr('Add'), onPressed: _add),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onSubmitted: (_) => _add(),
        ),
        const SizedBox(height: 8),
        if (dayEvents.isNotEmpty) ...[
          _sectionTitle('Events'),
          for (final e in dayEvents) _eventTile(e),
          _sectionTitle('Tasks'),
        ],
        if (selected.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Nothing planned.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        for (final t in selected) _taskTile(t),
        if (overdue.isNotEmpty) ...[
          _sectionTitle('Overdue', color: Theme.of(context).colorScheme.error),
          for (final t in overdue) _taskTile(t, showDate: true),
        ],
        if (undated.isNotEmpty) ...[
          _sectionTitle('No due date'),
          for (final t in undated) _taskTile(t),
        ],
        if (_caldav?.isConnected == true && _caldav!.lastMessage != null) ...[
          const SizedBox(height: 24),
          Text(
            _caldav!.lastMessage!,
            style: TextStyle(
              fontSize: 12,
              color: _caldav!.lastSyncFailed ? Theme.of(context).colorScheme.error : Colors.grey[600],
            ),
          ),
        ],
      ],
    );
  }

  Widget _eventTile(DayEvent e) {
    String two(int n) => n.toString().padLeft(2, '0');
    final time = e.allDay ? tr('All day') : '${two(e.start.hour)}:${two(e.start.minute)}';
    final st = _style.resolveEvent(e);
    return _stylable(
      () => _styleEvent(e),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: StyledBox(
          style: st,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.verbatim(st.label(e.title), style: const TextStyle(fontWeight: FontWeight.w600)),
            Text.verbatim('$time  -  ${e.calendarName}${e.repeats ? '  -  ${tr('repeats')}' : ''}',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, {Color? color}) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
      );

  Widget _taskTile(Task t, {bool showDate = false}) {
    final st = _style.resolveTask(t);
    return _stylable(
      () => _styleTask(t),
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: StyledBox(
          style: st,
          fillOpacity: t.done ? 0.1 : 0.22,
          padding: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(st.radius),
            onTap: () => _edit(t),
            child: Row(children: [
              Checkbox.adaptive(
                value: t.done,
                activeColor: st.color,
                onChanged: (v) => _run(() => _repo.setDone(t.id, v ?? false)),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.verbatim(
                    st.label(t.title),
                    style: t.done ? TextStyle(decoration: TextDecoration.lineThrough, color: Theme.of(context,).colorScheme.onSurfaceVariant) : null,
                  ),
                  if (showDate && t.dueDate != null)
                    Text.verbatim(_formatDay(t.dueDate!), style: TextStyle(fontSize: 12, color: Theme.of(context,).colorScheme.onSurfaceVariant)),
                ]),
              ),
              if (widget.reminders != null && !t.done)
                IconButton(
                  key: ValueKey('remind-task-${t.id}'),
                  icon: const Icon(Icons.add_alert_outlined, size: 20),
                  tooltip: tr('Remind me'),
                  onPressed: () => showRemindDialog(context, widget.reminders!, kind: ReminderKind.task, refId: t.id, title: t.title),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: tr('Delete'),
                onPressed: () => _run(() => _repo.deleteTask(t.id)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
