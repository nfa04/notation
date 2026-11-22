import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/study_planner.dart';
import '../review/study_progress.dart';
import '../review/study_schedule.dart';

/// A bar with two layers: [value] in the full colour on top of [behind] in a light one (for a part: what was gone over on top of what was
/// learnt), and an optional tick at [marker] (where the plan says the person should be by now).
class LayeredBar extends StatelessWidget {
  final double value;
  final double behind;
  final double? marker;
  final double height;

  const LayeredBar({super.key, required this.value, this.behind = 0, this.marker, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(height / 2);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      Widget layer(double v, Color color) => Align(alignment: Alignment.centerLeft, child: Container(width: w * v.clamp(0.0, 1.0), height: height, color: color));
      return SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(children: [
            Container(color: scheme.surfaceContainerHighest),
            layer(behind, scheme.primary.withValues(alpha: 0.35)),
            layer(value, scheme.primary),
            if (marker != null && marker! > 0 && marker! < 1)
              Positioned(left: (w * marker!).clamp(0.0, w - 2), top: 0, bottom: 0, child: Container(width: 2, color: scheme.onSurface.withValues(alpha: 0.55))),
          ]),
        ),
      );
    });
  }
}

/// How a plan stands: how ready the person is, and whether that is where the sessions that are over promised.
class PlanProgressBlock extends StatelessWidget {
  final PlanProgress progress;
  final double barHeight;

  const PlanProgressBlock({super.key, required this.progress, this.barHeight = 8});

  static String paceText(PlanProgress p) => switch (p.pace) {
        PlanPace.onTrack => tr('On track'),
        PlanPace.ahead => tr('Ahead of the plan'),
        PlanPace.behind => p.missed > 0
            ? trCount(p.missed, 'Behind: {n} session to catch up', 'Behind: {n} sessions to catch up')
            : tr('A little behind the plan'),
      };

  @override
  Widget build(BuildContext context) {
    if (!progress.hasParts) return const SizedBox();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = switch (progress.pace) { PlanPace.behind => scheme.tertiary, _ => scheme.primary };
    final icon = switch (progress.pace) { PlanPace.onTrack => Icons.check_circle_outline, PlanPace.ahead => Icons.trending_up, PlanPace.behind => Icons.flag_outlined };
    return Column(key: const ValueKey('plan-progress'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text.verbatim('${(progress.readiness * 100).round()} %', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        Text('ready for the exam', style: theme.textTheme.bodyMedium),
      ]),
      const SizedBox(height: 6),
      LayeredBar(value: progress.readiness, marker: progress.planned, height: barHeight),
      const SizedBox(height: 6),
      Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Flexible(child: Text.verbatim(paceText(progress), key: const ValueKey('plan-pace'), style: theme.textTheme.bodySmall?.copyWith(color: color))),
      ]),
    ]);
  }
}

/// The readiness of a plan over the days to the exam: the line the sessions promise (dashed) and the line of what was done. A box that
/// follows the pointer (or the finger) says, for the day it is at, how ready the plan is then and, for a day to come, what is still to
/// learn by then; for a day that is over, what was learnt since.
class ProgressDiagram extends StatefulWidget {
  final List<ProgressPoint> points;
  final DateTime today, exam;

  /// The work around a day (see [workAround]).
  final ({bool ahead, List<PartWork> work}) Function(DateTime day) workAt;

  const ProgressDiagram({super.key, required this.points, required this.today, required this.exam, required this.workAt});

  @override
  State<ProgressDiagram> createState() => _ProgressDiagramState();
}

class _ProgressDiagramState extends State<ProgressDiagram> {
  final _overlay = OverlayPortalController();
  int? _at;
  Offset _pointer = Offset.zero;

  static const _left = 36.0, _right = 10.0, _top = 18.0, _bottom = 24.0, _height = 220.0, _tipWidth = 250.0;

  int _index(double dx, double width) {
    final w = width - _left - _right;
    return ((dx - _left) / w * (widget.points.length - 1)).round().clamp(0, widget.points.length - 1);
  }

  void _point(Offset local, Offset global, double width) {
    setState(() {
      _at = _index(local.dx, width);
      _pointer = global;
    });
    if (!_overlay.isShowing) _overlay.show();
  }

  void _leave() {
    if (_overlay.isShowing) _overlay.hide();
    setState(() => _at = null);
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    if (points.length < 2) return const SizedBox();
    final theme = Theme.of(context);
    final l = MaterialLocalizations.of(context);
    final scheme = theme.colorScheme;
    // about six dates under the diagram
    final every = (points.length / 6).ceil().clamp(1, 1000);
    final dates = {for (var i = 0; i < points.length; i += every) i: l.formatShortDate(points[i].day)};
    if (every > 1 && points.length - 1 - (points.length - 1) ~/ every * every >= every ~/ 2 + 1) dates[points.length - 1] = l.formatShortDate(points.last.day);
    return Column(key: const ValueKey('plan-diagram'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('How ready you are, day by day', style: theme.textTheme.titleSmall),
      const SizedBox(height: 6),
      Wrap(spacing: 16, children: [
        _key(context, scheme.outline, tr('Planned'), dashed: true),
        _key(context, scheme.primary, tr('Done')),
      ]),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, c) {
        return OverlayPortal(
          controller: _overlay,
          overlayChildBuilder: _tooltip,
          child: MouseRegion(
            onHover: (e) => _point(e.localPosition, e.position, c.maxWidth),
            onExit: (_) => _leave(),
            child: GestureDetector(
              key: const ValueKey('plan-diagram-area'),
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _point(d.localPosition, d.globalPosition, c.maxWidth),
              onHorizontalDragUpdate: (d) => _point(d.localPosition, d.globalPosition, c.maxWidth),
              child: SizedBox(
                height: _height,
                width: double.infinity,
                child: CustomPaint(
                  painter: _DiagramPainter(
                    points: points,
                    today: widget.today,
                    exam: widget.exam,
                    at: _at,
                    dates: dates,
                    planned: scheme.outline,
                    actual: scheme.primary,
                    behind: scheme.tertiary,
                    grid: scheme.outlineVariant,
                    label: scheme.onSurfaceVariant,
                    style: theme.textTheme.labelSmall,
                    todayLabel: tr('Today'),
                    examLabel: tr('Exam'),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    ]);
  }

  String _kind(PartWork w) => switch (w.kind) {
        WorkKind.learn => tr('Learn'),
        WorkKind.review => tr('Go over'),
        WorkKind.quiz => tr('Quiz'),
        WorkKind.mistakes => tr('Mistakes'),
        _ => '',
      };

  Widget _tooltip(BuildContext context) {
    final i = _at;
    if (i == null) return const SizedBox();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = widget.points[i];
    final w = widget.workAt(p.day);
    final isToday = DateUtils.isSameDay(p.day, widget.today);
    final isExam = DateUtils.isSameDay(p.day, widget.exam);
    final lines = [
      for (final x in w.work)
        if (_kind(x).isNotEmpty) '${x.unit?.title ?? tr('A part that was taken out of the plan')}: ${_kind(x)}${x.share < 0.995 ? ' (${(x.share * 100).round()} %)' : ''}',
    ];
    const most = 5;
    final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox;
    final at = overlayBox.globalToLocal(_pointer);
    final size = overlayBox.size;
    final width = _tipWidth.clamp(0.0, size.width - 16);
    final x = (at.dx + 16 + width > size.width - 8 ? at.dx - 16 - width : at.dx + 16).clamp(8.0, size.width - width - 8);
    final above = at.dy > 240;
    final delta = p.actual == null ? null : ((p.actual! - p.planned) * 100).round();
    final label = theme.textTheme.bodySmall;
    final tip = Material(
      key: const ValueKey('plan-diagram-tip'),
      elevation: 6,
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.verbatim(
            '${MaterialLocalizations.of(context).formatFullDate(p.day)}${isToday ? ' · ${tr('Today')}' : isExam ? ' · ${tr('Exam')}' : ''}',
            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Icon(Icons.horizontal_rule, size: 16, color: scheme.outline),
            const SizedBox(width: 4),
            Expanded(child: Text.verbatim(tr('Planned: {n} % ready', {'n': (p.planned * 100).round()}), key: const ValueKey('plan-diagram-percent'), style: label)),
          ]),
          if (p.actual != null)
            Row(children: [
              Icon(Icons.circle, size: 10, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(child: Text.verbatim(tr('Done: {m} % ready', {'m': (p.actual! * 100).round()}), style: label)),
              if (delta != null && delta != 0)
                Text.verbatim('${delta > 0 ? '+' : '−'}${delta.abs()} %', style: label?.copyWith(color: delta > 0 ? scheme.primary : scheme.tertiary, fontWeight: FontWeight.w600)),
            ]),
          if (!isToday) ...[
            const Divider(height: 16),
            Text.verbatim(w.ahead ? tr('Still to learn by then:') : tr('Learnt since then:'), style: theme.textTheme.labelMedium),
            const SizedBox(height: 2),
            if (lines.isEmpty) Text(w.ahead ? 'Nothing: all of it is done or planned for later.' : 'Nothing was learnt since then.', style: label),
            for (final t in lines.take(most)) Text.verbatim('• $t', style: label),
            if (lines.length > most) Text.verbatim(tr('and {n} more', {'n': lines.length - most}), style: label?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
    return Positioned(
      left: x,
      top: above ? null : at.dy + 18,
      bottom: above ? size.height - at.dy + 14 : null,
      child: IgnorePointer(child: tip),
    );
  }

  Widget _key(BuildContext context, Color color, String text, {bool dashed = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 22, height: 3, child: CustomPaint(painter: _KeyPainter(color, dashed))),
        const SizedBox(width: 6),
        Text.verbatim(text, style: Theme.of(context).textTheme.labelSmall),
      ]);
}

class _KeyPainter extends CustomPainter {
  final Color color;
  final bool dashed;
  _KeyPainter(this.color, this.dashed);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 2.5..strokeCap = StrokeCap.round;
    if (!dashed) {
      canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), paint);
      return;
    }
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, size.height / 2), Offset((x + 4).clamp(0, size.width), size.height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_KeyPainter old) => old.color != color || old.dashed != dashed;
}

class _DiagramPainter extends CustomPainter {
  final List<ProgressPoint> points;
  final DateTime today, exam;
  final int? at;
  final Map<int, String> dates;
  final Color planned, actual, behind, grid, label;
  final TextStyle? style;
  final String todayLabel, examLabel;

  _DiagramPainter({
    required this.points,
    required this.today,
    required this.exam,
    required this.at,
    required this.dates,
    required this.planned,
    required this.actual,
    required this.behind,
    required this.grid,
    required this.label,
    required this.style,
    required this.todayLabel,
    required this.examLabel,
  });

  void _text(Canvas canvas, String t, Offset o, {Color? color, bool centre = false, bool right = false, bool middle = false}) {
    final p = TextPainter(text: TextSpan(text: t, style: style?.copyWith(color: color ?? label)), textDirection: TextDirection.ltr)..layout();
    canvas.drawPartialText(p, o, centre: centre, right: right, middle: middle);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = _ProgressDiagramState._left, right = _ProgressDiagramState._right, top = _ProgressDiagramState._top, bottom = _ProgressDiagramState._bottom;
    final w = size.width - left - right, h = size.height - top - bottom;
    double x(int i) => left + w * i / (points.length - 1);
    double y(double v) => top + h * (1 - v.clamp(0.0, 1.0));
    final gridPaint = Paint()..color = grid.withValues(alpha: 0.7)..strokeWidth = 1;
    for (final v in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      canvas.drawLine(Offset(left, y(v)), Offset(size.width - right, y(v)), gridPaint);
      _text(canvas, '${(v * 100).round()} %', Offset(left - 6, y(v)), right: true, middle: true);
    }
    for (final e in dates.entries) {
      _text(canvas, e.value, Offset(x(e.key).clamp(left + 14, size.width - right - 14), size.height - bottom + 6), centre: true);
    }
    // the planned line, a step for each day, dashed
    final plan = Paint()..color = planned..strokeWidth = 2..style = PaintingStyle.stroke;
    final path = Path()..moveTo(x(0), y(points.first.planned));
    for (var i = 1; i < points.length; i++) {
      path.lineTo(x(i), y(points[i - 1].planned));
      path.lineTo(x(i), y(points[i].planned));
    }
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 8) {
        canvas.drawPath(m.extractPath(d, (d + 5).clamp(0, m.length)), plan);
      }
    }
    // what was done, up to today: its line, the area under it, and where it is against the plan (the gap in a colour)
    final done = [for (final (i, p) in points.indexed) if (p.actual != null) (i, p.actual!)];
    if (done.isNotEmpty) {
      final line = Path()..moveTo(x(done.first.$1), y(done.first.$2));
      for (var k = 1; k < done.length; k++) {
        line.lineTo(x(done[k].$1), y(done[k - 1].$2));
        line.lineTo(x(done[k].$1), y(done[k].$2));
      }
      final area = Path.from(line)..lineTo(x(done.last.$1), y(0))..lineTo(x(done.first.$1), y(0))..close();
      canvas.drawPath(area, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [actual.withValues(alpha: 0.28), actual.withValues(alpha: 0.02)]).createShader(Rect.fromLTWH(left, top, w, h)));
      canvas.drawPath(line, Paint()..color = actual..strokeWidth = 3..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round);
      final last = done.last;
      final gap = last.$2 - points[last.$1].planned;
      if (gap.abs() > 0.01) {
        canvas.drawLine(Offset(x(last.$1), y(last.$2)), Offset(x(last.$1), y(points[last.$1].planned)), Paint()..color = (gap < 0 ? behind : actual)..strokeWidth = 2);
      }
      canvas.drawCircle(Offset(x(last.$1), y(last.$2)), 5, Paint()..color = actual);
      canvas.drawCircle(Offset(x(last.$1), y(last.$2)), 5, Paint()..color = label.withValues(alpha: 0)..style = PaintingStyle.stroke);
    }
    // today and the exam
    final ti = points.indexWhere((p) => !p.day.isBefore(today));
    if (ti >= 0 && ti < points.length - 1) {
      canvas.drawLine(Offset(x(ti), top), Offset(x(ti), top + h), Paint()..color = label.withValues(alpha: 0.35)..strokeWidth = 1);
      _text(canvas, todayLabel, Offset(x(ti), top - 4), centre: true, color: label);
    }
    final ei = points.indexWhere((p) => !p.day.isBefore(exam));
    if (ei >= 0) {
      canvas.drawLine(Offset(x(ei), top), Offset(x(ei), top + h), Paint()..color = planned.withValues(alpha: 0.6)..strokeWidth = 1.5);
      _text(canvas, examLabel, Offset(x(ei), top - 4), right: ei == points.length - 1, centre: ei != points.length - 1, color: planned);
    }
    // the day that is pointed at
    final a = at;
    if (a != null) {
      canvas.drawLine(Offset(x(a), top), Offset(x(a), top + h), Paint()..color = label..strokeWidth = 1.5);
      canvas.drawCircle(Offset(x(a), y(points[a].planned)), 5, Paint()..color = planned);
      canvas.drawCircle(Offset(x(a), y(points[a].planned)), 5, Paint()..color = grid..style = PaintingStyle.stroke..strokeWidth = 1.5);
      final act = points[a].actual;
      if (act != null) canvas.drawCircle(Offset(x(a), y(act)), 6, Paint()..color = actual);
    }
  }

  @override
  bool shouldRepaint(_DiagramPainter old) => old.points != points || old.today != today || old.at != at || old.planned != planned || old.actual != actual || old.label != label;
}

extension on Canvas {
  /// Draws [p] with its anchor at [o]: left/top by default, centred horizontally, right-aligned, or centred vertically.
  void drawPartialText(TextPainter p, Offset o, {bool centre = false, bool right = false, bool middle = false}) {
    final dx = centre ? o.dx - p.width / 2 : (right ? o.dx - p.width : o.dx);
    final dy = middle ? o.dy - p.height / 2 : (o.dy - (centre && !right ? p.height : 0));
    p.paint(this, Offset(dx, dy));
  }
}

/// The seven days of the week of [today]: a mark for each day with sessions (all done, some done, missed, to come), a dot for today.
class WeekStrip extends StatelessWidget {
  final List<BookedSession> sessions;
  final DateTime today;

  const WeekStrip({super.key, required this.sessions, required this.today});

  @override
  Widget build(BuildContext context) {
    final l = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final monday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
    return Row(key: const ValueKey('plan-week'), children: [
      for (var i = 0; i < 7; i++)
        Expanded(
          child: Builder(builder: (context) {
            final d = DateTime(monday.year, monday.month, monday.day + i);
            final of = [for (final s in sessions) if (!s.gone && !s.skipped || s.credited) if (DateUtils.isSameDay(s.session.start, d)) s];
            final done = of.where((s) => s.credited).length;
            final isToday = DateUtils.isSameDay(d, today);
            final (IconData?, Color) mark = of.isEmpty
                ? (null, scheme.outlineVariant)
                : done == of.length
                    ? (Icons.check_circle, scheme.primary)
                    : done > 0
                        ? (Icons.timelapse, scheme.primary)
                        : d.isBefore(today)
                            ? (Icons.circle_outlined, scheme.tertiary)
                            : (Icons.radio_button_unchecked, scheme.outline);
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Text.verbatim(l.narrowWeekdays[d.weekday % 7], style: theme.textTheme.labelSmall),
              const SizedBox(height: 4),
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: isToday ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: scheme.primary, width: 2)) : null,
                child: mark.$1 == null ? Text.verbatim('${d.day}', style: theme.textTheme.labelSmall) : Icon(mark.$1, size: 20, color: mark.$2),
              ),
            ]);
          }),
        ),
    ]);
  }
}
