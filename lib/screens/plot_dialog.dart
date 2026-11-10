import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;
import '../l10n/text.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_math_fork/flutter_math.dart' show Math;

import '../algebra/plot.dart';
import '../algebra/plot_style.dart';
import '../l10n/language.dart';
import 'plot_painter.dart';
import 'plot_style_panel.dart';
import '../style/platform_dialog.dart';

export 'plot_painter.dart';

/// Shapes of a plot picture to choose from, width by height.
const plotShapes = {'Square': Size(420, 420), 'Standard': Size(480, 360), 'Wide': Size(560, 315)};

/// A screen this short has no room to keep the preview in view while the options scroll: the whole
/// dialog scrolls instead.
bool _isCompact(BuildContext context) => MediaQuery.of(context).size.height < 620;

/// How large the preview of a plot of [shape] is in the dialog: as wide as the dialog allows, but
/// at most [heightShare] of the screen high, so that the options below stay in reach.
Size _previewSize(BuildContext context, Size shape, {double heightShare = 0.36}) {
  final screen = MediaQuery.of(context).size;
  final width = math.min(shape.width, screen.width - 112);
  final w = math.min(width, screen.height * (_isCompact(context) ? 0.6 : heightShare) * shape.width / shape.height);
  return Size(w, w * shape.height / shape.width);
}

/// The [pinned] part stays in view while the [scrolling] options move below it; on a short screen
/// everything moves together.
Widget _dialogBody(BuildContext context, List<Widget> pinned, List<Widget> scrolling) {
  if (_isCompact(context)) {
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [...pinned, ...scrolling]));
  }
  return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    ...pinned,
    Flexible(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: scrolling))),
  ]);
}

Widget _shapeChips(Size current, ValueChanged<String> pick) => Wrap(spacing: 8, children: [
      for (final e in plotShapes.entries)
        ChoiceChip(
          key: ValueKey('plot-shape-${e.key}'),
          label: Text(e.key),
          selected: current == e.value,
          onSelected: (_) => pick(e.key),
        ),
    ]);

/// A plot to look at: drag to move, pinch or wheel to zoom, and options for how it looks. [onAdd]
/// puts the picture on the page.
class PlotDialog extends StatefulWidget {
  final PlotSpec spec;
  final Future<void> Function(Uint8List png, Size size)? onAdd;

  const PlotDialog({super.key, required this.spec, this.onAdd});

  @override
  State<PlotDialog> createState() => _PlotDialogState();
}

class _PlotDialogState extends State<PlotDialog> {
  Size _size = plotShapes['Standard']!;
  late PlotRange _range = autoRange(widget.spec, aspect: _size.width / _size.height);
  PlotStyle _style = const PlotStyle();
  PlotRange? _from;
  Offset? _start;
  bool _adding = false;

  PlotKind get _kind => widget.spec.isImplicit ? PlotKind.implicit : PlotKind.function;

  void _zoom(double factor, Offset local) {
    final px = _range.xmin + local.dx / _size.width * _range.width;
    final py = _range.ymax - local.dy / _size.height * _range.height;
    setState(() => _range = _range.zoomed(factor, px, py));
  }

  /// A new shape keeps how stretched the axes are against each other, so a circle stays round.
  void _reshape(Size size) {
    final stretch = _range.height / _range.width / (_size.height / _size.width);
    final height = _range.width * stretch * size.height / size.width;
    final centre = _range.center;
    setState(() {
      _size = size;
      _range = PlotRange(_range.xmin, _range.xmax, centre.dy - height / 2, centre.dy + height / 2);
    });
  }

  /// The same number of units per pixel along both axes.
  void _equalScale() {
    final height = _range.width * _size.height / _size.width;
    final centre = _range.center;
    setState(() => _range = PlotRange(_range.xmin, _range.xmax, centre.dy - height / 2, centre.dy + height / 2));
  }

  Future<void> _add() async {
    setState(() => _adding = true);
    final png = await renderPlotPng(widget.spec, _range, _size, style: _style);
    await widget.onAdd!(png, _size);
    if (mounted) Navigator.pop(context);
  }

  Widget _preview(Size shown) {
    final k = _size.width / shown.width; // screen pixels to plot pixels
    return Center(
      child: SizedBox(
        width: shown.width,
        height: shown.height,
        child: Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              GestureBinding.instance.pointerSignalResolver.register(e, (_) {
                _zoom(e.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15, e.localPosition * k);
              });
            }
          },
          child: GestureDetector(
            key: const ValueKey('plot-area'),
            onScaleStart: (d) {
              _from = _range;
              _start = d.localFocalPoint;
            },
            onScaleUpdate: (d) {
              final from = _from, start = _start;
              if (from == null || start == null) return;
              final f0 = start * k, f1 = d.localFocalPoint * k;
              // the point of the plane under the first touch stays under the fingers
              final p0 = Offset(from.xmin + f0.dx / _size.width * from.width, from.ymax - f0.dy / _size.height * from.height);
              final zoomed = from.zoomed(d.scale, p0.dx, p0.dy);
              final q = Offset(zoomed.xmin + f1.dx / _size.width * zoomed.width, zoomed.ymax - f1.dy / _size.height * zoomed.height);
              setState(() => _range = zoomed.shifted(p0.dx - q.dx, p0.dy - q.dy));
            },
            child: ClipRect(
              child: CustomPaint(painter: PlotPainter(widget.spec, _range, style: _style), size: Size.infinite),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(_size.width, MediaQuery.of(context).size.width - 112);
    return PlatformAlertDialog(
      title: const Text('Plot'),
      content: SizedBox(
        width: width,
        child: _dialogBody(context, [
          Math.tex(widget.spec.latex, textStyle: const TextStyle(fontSize: 18), onErrorFallback: (_) => Text.verbatim(widget.spec.latex)),
          const SizedBox(height: 8),
          _preview(_previewSize(context, _size)),
          Wrap(children: [
            TextButton(onPressed: () => setState(() => _range = autoRange(widget.spec, aspect: _size.width / _size.height)), child: const Text('Reset view')),
            TextButton(key: const ValueKey('plot-equal'), onPressed: _equalScale, child: const Text('Equal scale')),
          ]),
        ], [
          _shapeChips(_size, (name) => _reshape(plotShapes[name]!)),
          PlotStylePanel(style: _style, kind: _kind, formula: plainFormula(widget.spec.latex), onChanged: (s) => setState(() => _style = s)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (widget.onAdd != null)
          FilledButton(
            key: const ValueKey('add-plot'),
            onPressed: _adding ? null : _add,
            child: const Text('Add to page'),
          ),
      ],
    );
  }
}

/// An empty coordinate system to place on the page and draw into by hand: the
/// ranges of x and y are chosen here, with a preview that follows them.
/// [onAdd] puts it on the note.
class EmptyPlotDialog extends StatefulWidget {
  final Future<void> Function(Uint8List png, Size size) onAdd;

  const EmptyPlotDialog({super.key, required this.onAdd});

  @override
  State<EmptyPlotDialog> createState() => _EmptyPlotDialogState();
}

class _EmptyPlotDialogState extends State<EmptyPlotDialog> {
  final _xFrom = TextEditingController(text: '-5');
  final _xTo = TextEditingController(text: '5');
  final _yFrom = TextEditingController(text: '-5');
  final _yTo = TextEditingController(text: '5');
  bool _adding = false;
  String _shape = 'Standard';
  PlotStyle _style = const PlotStyle();

  @override
  void dispose() {
    _xFrom.dispose();
    _xTo.dispose();
    _yFrom.dispose();
    _yTo.dispose();
    super.dispose();
  }

  static double? _number(String text) {
    final v = double.tryParse(text.trim().replaceAll(',', '.'));
    return v != null && v.isFinite ? v : null; // ("NaN" and "1e999" are numbers to tryParse)
  }

  /// What is wrong with the numbers (null when they make a plot).
  ({String? x, String? y}) get _problems {
    String? check(TextEditingController from, TextEditingController to, String axis) {
      final a = _number(from.text), b = _number(to.text);
      if (a == null || b == null) return tr('Enter numbers for {axis}', {'axis': axis});
      if (a >= b) return tr('{axis} must go from a smaller to a larger number', {'axis': axis});
      if (b - a > 1e9) return tr('That range is too large');
      return null;
    }

    return (x: check(_xFrom, _xTo, 'x'), y: check(_yFrom, _yTo, 'y'));
  }

  PlotRange? get _range {
    final p = _problems;
    if (p.x != null || p.y != null) return null;
    return PlotRange(_number(_xFrom.text)!, _number(_xTo.text)!, _number(_yFrom.text)!, _number(_yTo.text)!);
  }

  Future<void> _add() async {
    final range = _range;
    if (range == null || _adding) return;
    setState(() => _adding = true);
    final size = plotShapes[_shape]!;
    final png = await renderPlotPng(const PlotSpec.blank(), range, size, style: _style);
    await widget.onAdd(png, size);
    if (mounted) Navigator.pop(context);
  }

  Widget _field(String key, String label, TextEditingController c) => Expanded(
        child: TextField(
          key: ValueKey(key),
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-eE+]'))],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: tr(label), isDense: true, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final problems = _problems;
    final size = plotShapes[_shape]!;
    final shown = _previewSize(context, size, heightShare: 0.32);
    return PlatformAlertDialog(
      title: const Text('Empty plot'),
      content: SizedBox(
        width: 440,
        child: _dialogBody(context, [
          const Text('Axes and a grid to draw into by hand. Choose what part of the plane it shows.'),
          const SizedBox(height: 12),
          Center(
            child: SizedBox(
              width: shown.width,
              height: shown.height,
              child: range == null ? const SizedBox() : CustomPaint(key: const ValueKey('plot-preview'), painter: PlotPainter(const PlotSpec.blank(), range, style: _style)),
            ),
          ),
          const SizedBox(height: 12),
        ], [
          Row(children: [
            _field('plot-x-from', 'x from', _xFrom),
            const SizedBox(width: 8),
            _field('plot-x-to', 'x to', _xTo),
          ]),
          if (problems.x != null) Text(problems.x!, key: const ValueKey('plot-x-problem'), style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          const SizedBox(height: 10),
          Row(children: [
            _field('plot-y-from', 'y from', _yFrom),
            const SizedBox(width: 8),
            _field('plot-y-to', 'y to', _yTo),
          ]),
          if (problems.y != null) Text(problems.y!, key: const ValueKey('plot-y-problem'), style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          const SizedBox(height: 10),
          _shapeChips(size, (name) => setState(() => _shape = name)),
          PlotStylePanel(style: _style, kind: PlotKind.blank, onChanged: (s) => setState(() => _style = s)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('plot-place'),
          onPressed: range == null || _adding ? null : _add,
          child: const Text('Place on the page'),
        ),
      ],
    );
  }
}
