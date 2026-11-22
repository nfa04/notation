import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../review/study_planner.dart';
import '../review/study_progress.dart';

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

/// The readiness of a plan over the days to the exam: the line the sessions promise (dashed) and the line of what was done.
class ProgressDiagram extends StatelessWidget {
  final List<ProgressPoint> points;
  final DateTime today;

  const ProgressDiagram({super.key, required this.points, required this.today});

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) return const SizedBox();
    final theme = Theme.of(context);
    final l = MaterialLocalizations.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall;
    return Column(key: const ValueKey('plan-diagram'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 16, children: [
        _key(context, scheme.outline, tr('Planned'), dashed: true),
        _key(context, scheme.primary, tr('Done')),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        height: 160,
        child: CustomPaint(
          size: Size.infinite,
          painter: _DiagramPainter(points: points, today: today, planned: scheme.outline, actual: scheme.primary, grid: scheme.outlineVariant, label: scheme.onSurfaceVariant, style: style),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 32, top: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text.verbatim(l.formatShortDate(points.first.day), style: style),
          Text.verbatim(l.formatShortDate(points.last.day), style: style),
        ]),
      ),
    ]);
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
  final DateTime today;
  final Color planned, actual, grid, label;
  final TextStyle? style;

  _DiagramPainter({required this.points, required this.today, required this.planned, required this.actual, required this.grid, required this.label, required this.style});

  @override
  void paint(Canvas canvas, Size size) {
    const left = 32.0, pad = 6.0;
    final w = size.width - left - pad, h = size.height - 2 * pad;
    double x(int i) => left + w * i / (points.length - 1);
    double y(double v) => pad + h * (1 - v.clamp(0.0, 1.0));
    final gridPaint = Paint()..color = grid..strokeWidth = 1;
    for (final v in [0.0, 0.5, 1.0]) {
      canvas.drawLine(Offset(left, y(v)), Offset(size.width - pad, y(v)), gridPaint);
      final t = TextPainter(text: TextSpan(text: '${(v * 100).round()} %', style: style?.copyWith(color: label)), textDirection: TextDirection.ltr)..layout();
      t.paint(canvas, Offset(left - t.width - 4, y(v) - t.height / 2));
    }
    // the planned line, dashed
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
    // what was done, up to today, with the area under it
    final done = [for (final (i, p) in points.indexed) if (p.actual != null) (i, p.actual!)];
    if (done.isNotEmpty) {
      final line = Path()..moveTo(x(done.first.$1), y(done.first.$2));
      for (var k = 1; k < done.length; k++) {
        line.lineTo(x(done[k].$1), y(done[k - 1].$2));
        line.lineTo(x(done[k].$1), y(done[k].$2));
      }
      final area = Path.from(line)..lineTo(x(done.last.$1), y(0))..lineTo(x(done.first.$1), y(0))..close();
      canvas.drawPath(area, Paint()..color = actual.withValues(alpha: 0.15));
      canvas.drawPath(line, Paint()..color = actual..strokeWidth = 3..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round);
      canvas.drawCircle(Offset(x(done.last.$1), y(done.last.$2)), 4.5, Paint()..color = actual);
    }
    final ti = points.indexWhere((p) => !p.day.isBefore(today));
    if (ti > 0 && ti < points.length - 1) {
      canvas.drawLine(Offset(x(ti), pad), Offset(x(ti), size.height - pad), Paint()..color = label.withValues(alpha: 0.5)..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(_DiagramPainter old) => old.points != points || old.today != today || old.planned != planned || old.actual != actual;
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
