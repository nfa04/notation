import 'package:flutter/material.dart' hide Text;

import '../algebra/plot_style.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// What the options of a plot offer, depending on what is plotted.
enum PlotKind {
  /// `y = f(x)`: the curve can be filled, marked and differentiated.
  function,

  /// `f(x, y) = 0`: a curve, but no function of x.
  implicit,

  /// Axes and a grid only.
  blank,
}

/// The options for how a plot looks: curve, grid, axes and page. [onChanged] gets the new style
/// with every change, so a preview can follow.
class PlotStylePanel extends StatefulWidget {
  final PlotStyle style;
  final ValueChanged<PlotStyle> onChanged;
  final PlotKind kind;

  /// The formula as plain text, to offer as the title.
  final String formula;

  const PlotStylePanel({super.key, required this.style, required this.onChanged, required this.kind, this.formula = ''});

  @override
  State<PlotStylePanel> createState() => _PlotStylePanelState();
}

class _PlotStylePanelState extends State<PlotStylePanel> {
  late final _title = TextEditingController(text: widget.style.title);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  PlotStyle get _s => widget.style;

  void _set(PlotStyle s) => widget.onChanged(s);

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary,)),
          const SizedBox(height: 6),
          ...children,
        ]),
      );

  Widget _chips(List<Widget> chips) => Wrap(spacing: 8, runSpacing: 4, children: chips);

  /// A choice among [values], one chip each.
  Widget _choice<T>(String key, List<T> values, T current, String Function(T) name, ValueChanged<T> pick) => _chips([
        for (final v in values)
          ChoiceChip(
            key: ValueKey('plot-$key-${(v as Enum).name}'),
            label: Text(name(v)),
            selected: current == v,
            onSelected: (_) => pick(v),
          ),
      ]);

  Widget _toggle(String key, String label, bool on, ValueChanged<bool> change) => FilterChip(
        key: ValueKey('plot-$key'),
        label: Text(label),
        selected: on,
        onSelected: change,
      );

  Widget _slider(String key, String label, double value, double min, double max, ValueChanged<double> change) => Row(children: [
        SizedBox(width: 88, child: Text(label)),
        Expanded(child: Slider.adaptive(key: ValueKey('plot-$key'), value: value.clamp(min, max), min: min, max: max, onChanged: change)),
      ]);

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final curve = kind != PlotKind.blank;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (curve)
        _section('Curve', [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < plotCurveColors.length; i++)
              InkResponse(
                key: ValueKey('plot-color-$i'),
                onTap: () => _set(_s.copyWith(curve: plotCurveColors[i])),
                radius: 20,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: plotCurveColors[i],
                    shape: BoxShape.circle,
                    border: Border.all(color: _s.curve == plotCurveColors[i] ? Theme.of(context).colorScheme.onSurface : Colors.transparent, width: 3),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          _choice('line', PlotLine.values, _s.line, (l) => switch (l) { PlotLine.solid => 'Solid', PlotLine.dashed => 'Dashed', PlotLine.dotted => 'Dotted' }, (l) => _set(_s.copyWith(line: l))),
          _slider('width', 'Thickness', _s.lineWidth, 1, 6, (v) => _set(_s.copyWith(lineWidth: v))),
          if (kind == PlotKind.function) ...[
            _chips([
              _toggle('fill', 'Fill under the curve', _s.fillUnder, (v) => _set(_s.copyWith(fillUnder: v))),
              _toggle('derivative', 'Show the slope', _s.derivative, (v) => _set(_s.copyWith(derivative: v))),
            ]),
            const SizedBox(height: 4),
            _chips([
              _toggle('zeros', 'Zeros', _s.zeros, (v) => _set(_s.copyWith(zeros: v))),
              _toggle('intercept', 'y-intercept', _s.intercept, (v) => _set(_s.copyWith(intercept: v))),
              _toggle('extrema', 'Highs and lows', _s.extrema, (v) => _set(_s.copyWith(extrema: v))),
              if (_s.hasMarks) _toggle('mark-labels', 'Label the points', _s.markLabels, (v) => _set(_s.copyWith(markLabels: v))),
            ]),
          ],
        ]),
      _section('Grid', [
        _choice('grid', PlotGrid.values, _s.grid, (g) => switch (g) { PlotGrid.none => 'No grid', PlotGrid.major => 'Lines', PlotGrid.fine => 'Fine' }, (g) => _set(_s.copyWith(grid: g))),
        const SizedBox(height: 4),
        _choice('density', PlotDensity.values, _s.density, (d) => switch (d) { PlotDensity.sparse => 'Few lines', PlotDensity.normal => 'Normal', PlotDensity.dense => 'Many lines' }, (d) => _set(_s.copyWith(density: d))),
      ]),
      _section('Axes', [
        _choice('axes', PlotAxes.values, _s.axes, (a) => switch (a) { PlotAxes.cross => 'Through zero', PlotAxes.edges => 'At the edges', PlotAxes.hidden => 'Hidden' }, (a) => _set(_s.copyWith(axes: a))),
        const SizedBox(height: 4),
        _chips([
          _toggle('numbers', 'Numbers', _s.numbers, (v) => _set(_s.copyWith(numbers: v))),
          _toggle('ticks', 'Tick marks', _s.ticks, (v) => _set(_s.copyWith(ticks: v))),
          _toggle('names', 'Axis names', _s.names, (v) => _set(_s.copyWith(names: v))),
          _toggle('arrows', 'Arrows', _s.arrows, (v) => _set(_s.copyWith(arrows: v))),
          _toggle('pi', 'x in multiples of π', _s.piLabels, (v) => _set(_s.copyWith(piLabels: v))),
        ]),
        _slider('label-size', 'Text size', _s.labelScale, 0.7, 1.8, (v) => _set(_s.copyWith(labelScale: v))),
      ]),
      _section('Page', [
        _choice(
            'bg',
            PlotBackground.values,
            _s.background,
            (b) => switch (b) { PlotBackground.white => 'White', PlotBackground.paper => 'Paper', PlotBackground.grey => 'Grey', PlotBackground.dark => 'Dark', PlotBackground.transparent => 'Transparent' },
            (b) => _set(_s.copyWith(background: b))),
        const SizedBox(height: 4),
        _chips([_toggle('border', 'Border', _s.border, (v) => _set(_s.copyWith(border: v)))]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('plot-title'),
              controller: _title,
              onChanged: (v) => _set(_s.copyWith(title: v)),
              decoration: InputDecoration(labelText: tr('Title'), isDense: true, border: const OutlineInputBorder()),
            ),
          ),
          if (widget.formula.isNotEmpty)
            TextButton(
              key: const ValueKey('plot-title-formula'),
              onPressed: () {
                _title.text = widget.formula;
                _set(_s.copyWith(title: widget.formula));
              },
              child: const Text('Use the formula'),
            ),
        ]),
      ]),
    ]);
  }
}
