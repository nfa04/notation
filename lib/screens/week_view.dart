import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';

import '../data/task_repository.dart';
import '../sync/caldav_remote.dart';
import '../style/style_service.dart';
import '../style/styled_box.dart';
import 'week_layout.dart';
import '../l10n/language.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Seven days with a time grid: all-day events and tasks above, timed events
/// placed by their time below.
class WeekView extends StatefulWidget {
  /// The Monday of the week shown.
  final DateTime weekStart;
  final DateTime selected;
  final DateTime today;
  final List<DayEvent> events;
  final List<Task> tasks;
  final ValueChanged<DateTime> onSelectDay;
  final void Function(Task task, bool done) onToggleTask;
  final ValueChanged<Task> onEditTask;

  /// Colours, borders and emoji; long press / right click styles an item.
  final StyleService style;
  final ValueChanged<DayEvent> onStyleEvent;
  final ValueChanged<Task> onStyleTask;
  final ValueChanged<DateTime> onStyleDay;

  const WeekView({
    super.key,
    required this.weekStart,
    required this.selected,
    required this.today,
    required this.events,
    required this.tasks,
    required this.onSelectDay,
    required this.onToggleTask,
    required this.onEditTask,
    required this.style,
    required this.onStyleEvent,
    required this.onStyleTask,
    required this.onStyleDay,
  });

  @override
  State<WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends State<WeekView> {
  static const double hourHeight = 52;
  static const double labelWidth = 48;

  final _scroll = ScrollController();

  List<DateTime> get _days =>
      [for (var i = 0; i < 7; i++) DateTime(widget.weekStart.year, widget.weekStart.month, widget.weekStart.day + i)];

  @override
  void initState() {
    super.initState();
    // start at the morning, or just before now when the week contains today
    final now = DateTime.now();
    final showsToday = _days.contains(widget.today);
    final hour = showsToday ? (now.hour - 1).clamp(0, 16) : 7;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo((hour * hourHeight).clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _stylable(VoidCallback onStyle, Widget child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: onStyle,
        onSecondaryTap: onStyle,
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final days = _days;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // day headers
        Row(children: [
          const SizedBox(width: labelWidth),
          for (final day in days) Expanded(child: _header(day, scheme)),
        ]),
        // all-day events and tasks
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 150),
          child: SingleChildScrollView(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(width: labelWidth),
              for (final day in days) Expanded(child: _allDay(day, scheme)),
            ]),
          ),
        ),
        const Divider(height: 1),
        // time grid
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: SizedBox(
              height: 24 * hourHeight,
              child: Row(children: [
                SizedBox(
                  width: labelWidth,
                  child: Stack(children: [
                    for (var h = 1; h < 24; h++)
                      Positioned(
                        top: h * hourHeight - 7,
                        right: 6,
                        child: Text.verbatim('${h.toString().padLeft(2, '0')}:00',
                            style: TextStyle(fontSize: 10, color: Theme.of(context,).colorScheme.onSurfaceVariant)),
                      ),
                  ]),
                ),
                for (final day in days) Expanded(child: _dayColumn(day, scheme)),
              ]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(DateTime day, ColorScheme scheme) {
    final isToday = day == widget.today;
    final isSelected = day == widget.selected;
    final look = widget.style.dayStyle(day);
    return _stylable(
      () => widget.onStyleDay(day),
      InkWell(
        onTap: () => widget.onSelectDay(day),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? scheme.primaryContainer : look?.color?.withValues(alpha: 0.3),
            border: Border(left: BorderSide(color: Colors.grey.withValues(alpha: 0.2))),
          ),
          child: Column(children: [
            Text.verbatim(tr(_weekdays[day.weekday - 1]), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: isToday ? scheme.primary : Colors.transparent,
                child: Text.verbatim('${day.day}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isToday ? FontWeight.bold : null,
                      color: isToday ? scheme.onPrimary : null,
                    )),
              ),
              if (look?.emoji != null) ...[const SizedBox(width: 3), Text.verbatim(look!.emoji!, style: const TextStyle(fontSize: 14))],
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _allDay(DateTime day, ColorScheme scheme) {
    final events = widget.events.where((e) => e.allDay && e.occursOn(day));
    final tasks = widget.tasks.where((t) => t.dueDate == day);
    final look = widget.style.dayStyle(day);
    return Container(
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: day == widget.selected ? scheme.primaryContainer.withValues(alpha: 0.35) : look?.color?.withValues(alpha: 0.15),
        border: Border(left: BorderSide(color: Colors.grey.withValues(alpha: 0.2))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final e in events)
          _stylable(
            () => widget.onStyleEvent(e),
            Tooltip(
              message: '${e.title}\n${e.calendarName}',
              child: Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: StyledBox(
                  style: widget.style.resolveEvent(e),
                  child: Text.verbatim(widget.style.resolveEvent(e).label(e.title),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                ),
              ),
            ),
          ),
        for (final t in tasks) _taskRow(t),
      ]),
    );
  }

  Widget _taskRow(Task t) {
    final st = widget.style.resolveTask(t);
    return _stylable(
      () => widget.onStyleTask(t),
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: StyledBox(
          style: st,
          fillOpacity: t.done ? 0.1 : 0.24,
          padding: EdgeInsets.zero,
          child: InkWell(
            onTap: () => widget.onEditTask(t),
            child: Row(children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox.adaptive(
                  value: t.done,
                  activeColor: st.color,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => widget.onToggleTask(t, v ?? false),
                ),
              ),
              Expanded(
                child: Text.verbatim(
                  st.label(t.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    decoration: t.done ? TextDecoration.lineThrough : null,
                    color: t.done ? Colors.grey : null,
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _dayColumn(DateTime day, ColorScheme scheme) {
    final placed = layoutDay(widget.events, day);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onSelectDay(day),
      child: LayoutBuilder(builder: (context, box) {
        return Container(
          decoration: BoxDecoration(
            color: day == widget.selected
                ? scheme.primaryContainer.withValues(alpha: 0.2)
                : widget.style.dayStyle(day)?.color?.withValues(alpha: 0.12),
            border: Border(left: BorderSide(color: Colors.grey.withValues(alpha: 0.2))),
          ),
          child: Stack(clipBehavior: Clip.hardEdge, children: [
            Positioned.fill(child: CustomPaint(painter: _HourLines(Colors.grey.withValues(alpha: 0.2)))),
            for (final p in placed)
              Positioned(
                left: box.maxWidth * p.lane / p.lanes + 1,
                width: box.maxWidth / p.lanes - 3,
                top: p.startMinute / 60 * hourHeight,
                height: (p.endMinute - p.startMinute) / 60 * hourHeight - 1,
                child: Tooltip(
                  message: '${p.event.title}\n'
                      '${two(p.event.start.hour)}:${two(p.event.start.minute)}'
                      '${p.event.end == null ? '' : ' - ${two(p.event.end!.hour)}:${two(p.event.end!.minute)}'}\n'
                      '${p.event.calendarName}',
                  child: _stylable(() => widget.onStyleEvent(p.event), _eventBlock(p, scheme)),
                ),
              ),
            if (day == widget.today)
              Positioned(
                left: 0,
                right: 0,
                top: (now.hour * 60 + now.minute) / 60 * hourHeight,
                child: Container(height: 2, color: scheme.error),
              ),
          ]),
        );
      }),
    );
  }

  Widget _eventBlock(PlacedEvent p, ColorScheme scheme) {
    final st = widget.style.resolveEvent(p.event);
    String two(int n) => n.toString().padLeft(2, '0');
    final tall = p.endMinute - p.startMinute >= 45;
    return StyledBox(
      style: st,
      padding: const EdgeInsets.fromLTRB(5, 2, 3, 2),
      child: ClipRect(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.verbatim(st.label(p.event.title),
              maxLines: tall ? 2 : 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, height: 1.1)),
          if (tall)
            Text.verbatim('${two(p.event.start.hour)}:${two(p.event.start.minute)}',
                style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _HourLines extends CustomPainter {
  final Color color;

  _HourLines(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var h = 1; h < 24; h++) {
      final y = h * _WeekViewState.hourHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_HourLines old) => old.color != color;
}
