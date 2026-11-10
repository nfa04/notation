import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../data/brush_library.dart';
import '../export/file_dialogs.dart';
import '../l10n/language.dart';
import '../models/brush.dart';
import '../models/brush_desc.dart';
import '../models/canvas_models.dart';
import '../painters/canvas_painters.dart' show paintBrushShape;
import '../painters/soft_strokes.dart';
import '../style/platform_dialog.dart';

/// Opens the brush designer: make a brush from numbers, keep it, share it as a `.strokedesc` file, take one in. Answers with the id of
/// the brush the person saved and wants to draw with, or null.
Future<String?> showBrushDesigner(BuildContext context, BrushLibrary library) =>
    showDialog<String>(context: context, builder: (_) => BrushDesigner(library: library));

class BrushDesigner extends StatefulWidget {
  final BrushLibrary library;

  const BrushDesigner({super.key, required this.library});

  @override
  State<BrushDesigner> createState() => _BrushDesignerState();
}

class _BrushDesignerState extends State<BrushDesigner> {
  final _name = TextEditingController();
  final _raster = SoftRaster(budget: 8 * 1024 * 1024, entries: 8);
  late BrushDesc _draft;
  late Brush _brush;
  List<LibraryBrush> _items = const [];

  /// The brush of the library that is being changed (null: a new one).
  String? _editing;
  String? _message;
  bool _problem = false;

  /// The line the preview shows: a wave with the pressure rising and falling, so that every number of every kind shows.
  static final DrawingStroke _stroke = () {
    const n = 70;
    return DrawingStroke(
      id: 'brush-preview',
      color: const Color(0xFF000000),
      width: 1,
      points: [for (var i = 0; i < n; i++) Offset(14 + i * 5.2, 46 + 20 * math.sin(i / 9) * (1 - i / (n * 1.6)))],
      pressures: [for (var i = 0; i < n; i++) (60 + 190 * math.sin(math.pi * i / (n - 1))).round().clamp(0, 255)],
    );
  }();

  @override
  void initState() {
    super.initState();
    _draft = BrushDesc(BrushKind.ink, tr('My brush'));
    _name.text = _draft.name;
    _brush = _draft.build();
    _reload();
  }

  @override
  void dispose() {
    _name.dispose();
    _raster.clear();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await widget.library.load();
    if (mounted) setState(() => _items = items);
  }

  void _set(BrushDesc d) => setState(() {
        _draft = d;
        _brush = d.build();
        _message = null;
      });

  /// The design with the name that is in the field.
  BrushDesc get _named => _draft.named(_name.text);

  void _say(String text, {bool problem = false}) => setState(() {
        _message = text;
        _problem = problem;
      });

  void _edit(LibraryBrush b) {
    _editing = b.desc.id;
    _name.text = b.desc.name;
    _set(b.desc);
    // (a brush with advanced numbers opens them, so that what makes it what it is can be seen)
    if (_advancedUsed(b.desc) && !_advanced.isExpanded) _advanced.expand();
  }

  void _startNew() {
    _editing = null;
    _name.text = tr('My brush');
    _set(BrushDesc(_draft.kind, _name.text));
  }

  Future<void> _saveAndUse() async {
    final desc = _named;
    final old = _editing;
    await widget.library.save(desc);
    // (the brush it was made from stays in the library, out of the menu: notes may be drawn with it)
    if (old != null && old != desc.id) await widget.library.setListed(old, false);
    if (mounted) Navigator.pop(context, desc.id);
  }

  /// Keeps the design as a brush of its own and leaves the one it was made from in the menu (saving it and using it unlists that one).
  Future<void> _saveCopy() async {
    final desc = _named;
    if (_editing == desc.id) {
      _say(tr('Change a number first: a copy with the same numbers is the same brush.'), problem: true);
      return;
    }
    await widget.library.save(desc);
    _editing = desc.id;
    await _reload();
    if (mounted) _say(tr('Saved "{name}" as a brush of its own.', {'name': desc.name}));
  }

  /// Puts the brush on the clipboard as a line of text that can be sent in a message.
  Future<void> _copyCode() async {
    final desc = _named;
    await Clipboard.setData(ClipboardData(text: desc.toCode()));
    if (mounted) _say(tr('Copied the brush "{name}" as text. Paste it in the designer on another device.', {'name': desc.name}));
  }

  /// Takes in a brush from the text on the clipboard (a copied brush, or the text of a .strokedesc).
  Future<void> _pasteCode() async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      final desc = BrushDesc.fromCode(text);
      await widget.library.save(desc);
      await _reload();
      final taken = _items.where((b) => b.desc.id == desc.id).firstOrNull;
      if (taken != null) _edit(taken);
      _say(tr('Took in the brush "{name}"; it is in the brush menu.', {'name': desc.name}));
    } on BrushDescException catch (e) {
      _say(tr(e.message), problem: true);
    }
  }

  Future<void> _export() async {
    final desc = _named;
    final safe = desc.name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    try {
      final where = await saveWithDialog(dialogTitle: tr('Save the brush'), fileName: '$safe.$strokeDescExtension', bytes: desc.toBytes(), extension: strokeDescExtension);
      if (where != null) _say(tr('Saved the brush "{name}".', {'name': desc.name}));
    } catch (e) {
      _say(tr('The brush could not be saved: {error}', {'error': '$e'}), problem: true);
    }
  }

  Future<void> _import() async {
    try {
      final computer = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
      // (a phone does not know the kind of file by its extension, so it offers every file; what is not a brush is turned away below)
      final files = await FilePicker.pickFiles(type: computer || kIsWeb ? FileType.custom : FileType.any, allowedExtensions: computer || kIsWeb ? const [strokeDescExtension] : null);
      if (files.isEmpty) return;
      final taken = <BrushDesc>[];
      final failed = <String>[];
      for (final f in files) {
        try {
          taken.add(BrushDesc.fromBytes(await f.readAsBytes()));
        } on BrushDescException catch (e) {
          failed.add('${f.name}: ${tr(e.message)}');
        }
      }
      for (final d in taken) {
        await widget.library.save(d);
      }
      await _reload();
      if (taken.isNotEmpty) {
        final first = _items.where((b) => b.desc.id == taken.first.id).firstOrNull;
        if (first != null) _edit(first);
      }
      _say(
        [
          if (taken.isNotEmpty) trCount(taken.length, 'Took in {n} brush; it is in the brush menu.', 'Took in {n} brushes; they are in the brush menu.'),
          ...failed,
        ].join('\n'),
        problem: failed.isNotEmpty,
      );
    } catch (e) {
      _say(tr('The file could not be read: {error}', {'error': '$e'}), problem: true);
    }
  }

  /// Asked once before a brush is deleted: lines drawn with it would be drawn with the pen.
  bool _askDelete = false;

  Future<void> _delete() async {
    final id = _editing;
    if (id == null) return;
    await widget.library.delete(id);
    _askDelete = false;
    _editing = null;
    await _reload();
    if (mounted) _say(tr('The brush was deleted'));
  }

  Future<void> _toggleListed(String id, bool listed) async {
    await widget.library.setListed(id, listed);
    await _reload();
  }

  Widget _chip(LibraryBrush b) => ChoiceChip(
        key: ValueKey('brush-design-${b.desc.id}'),
        label: Text.rich(TextSpan(text: b.desc.name)),
        selected: _editing == b.desc.id,
        onSelected: (_) {
          _askDelete = false;
          _edit(b);
        },
      );

  Widget _slider(BrushKnob k) {
    final value = _draft[k.key] ?? k.standard;
    final choices = k.choices;
    return Row(children: [
      SizedBox(width: 130, child: Text(tr(k.label), overflow: TextOverflow.ellipsis)),
      Expanded(
        child: Slider(
          key: ValueKey('brush-knob-${k.key}'),
          value: value.clamp(k.min, k.max),
          min: k.min,
          max: k.max,
          divisions: choices == null ? null : choices.length - 1,
          onChanged: (v) => _set(_draft.withValue(k.key, v)),
        ),
      ),
      if (choices != null)
        SizedBox(width: 76, child: Text(tr(k.show(value)), textAlign: TextAlign.end, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall))
      else
        _NumberBox(key: ValueKey('brush-knob-${k.key}-value'), value: value, text: k.show(value), onEntered: (v) => _set(_draft.withValue(k.key, v))),
    ]);
  }

  /// What the switch of a number that can be off says.
  static const _switchLabels = {
    'nibAngle': 'Flat nib (like a calligraphy pen)',
    'startTaper': 'A start of its own',
    'endTaper': 'An end of its own',
  };

  /// The order the headings of the advanced numbers come in (numbers with no heading come last).
  static const _groupOrder = ['Pen response', 'Shape', 'Colour', 'Line style', 'Blending'];

  /// The curves a kind can have, by the start of the names of their numbers, with what the curve is called, what is on the way in
  /// (left to right) and the switch that turns it on; and the numbers it takes the place of.
  static const _curves = {
    'pressure': (title: 'Pressure curve', x: 'Light touch → hard press', replaces: ['pressure', 'pressureCurve']),
    'speed': (title: 'Speed curve', x: 'Slow → fast', replaces: ['speedThin']),
  };

  /// The controls of the numbers of the kind, the usual ones and the advanced ones.
  (List<Widget>, List<Widget>) _knobs() {
    final usual = <Widget>[];
    final byGroup = <String?, List<Widget>>{};
    final knobs = BrushDesc.knobsOf(_draft.kind);
    final hidden = <String>{
      for (final e in _curves.entries)
        if (_draft['${e.key}At0'] != null) ...e.value.replaces,
    };
    for (final k in knobs) {
      if (k.own || hidden.contains(k.key)) continue;
      if (k.key == 'nibFlatness' && _draft['nibAngle'] == null) continue;
      if (k.key == 'dashGap' && (_draft['dash'] ?? 0) <= 0) continue;
      if (k.key == 'shadowDistance' && (_draft['shadow'] ?? 0) <= 0) continue;
      if (k.key == 'shadowBlur' && (_draft['shadow'] ?? 0) <= 0) continue;
      if (k.key == 'glowHue' && (_draft['glow'] ?? 0) <= 0) continue;
      if (k.key == 'outlineTone' && (_draft['outline'] ?? 0) <= 0) continue;
      final out = k.advanced ? (byGroup[k.group] ??= <Widget>[]) : usual;
      if (k.optional) {
        final on = _draft[k.key] != null;
        out.add(SwitchListTile(
          key: ValueKey('brush-knob-${k.key}-on'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(tr(_switchLabels[k.key] ?? k.label)),
          value: on,
          onChanged: (v) => _set(_draft.withValue(k.key, v ? k.standard : null)),
        ));
        if (on) out.add(_slider(k));
      } else {
        out.add(_slider(k));
      }
    }
    // (the curves go with the pen: they are shown when the kind has the numbers of them)
    for (final e in _curves.entries) {
      if (knobs.any((k) => k.key == '${e.key}At0')) (byGroup['Pen response'] ??= <Widget>[]).add(_curveControl(e.key, e.value.title, e.value.x));
    }
    final advanced = <Widget>[];
    for (final g in [..._groupOrder, null]) {
      final widgets = byGroup[g];
      if (widgets == null || widgets.isEmpty) continue;
      if (g != null) {
        advanced.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Text(tr(g), key: ValueKey('brush-group-$g'), style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
        ));
      }
      advanced.addAll(widgets);
    }
    return (usual, advanced);
  }

  /// A curve for the pen (see [BrushParams.pressurePoints]): a switch, and when it is on five points to drag.
  Widget _curveControl(String prefix, String title, String xLabel) {
    final keys = [for (final step in BrushDesc.curveSteps) '${prefix}At$step'];
    final on = _draft[keys.first] != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        key: ValueKey('brush-curve-$prefix-on'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(tr('Draw the response as a curve ({name})', {'name': tr(title)})),
        value: on,
        onChanged: (v) => _set(_draft.withValues({for (var i = 0; i < keys.length; i++) keys[i]: v ? _curveStart(prefix, i / (keys.length - 1)) : null})),
      ),
      if (on)
        _CurveEditor(
          key: ValueKey('brush-curve-$prefix'),
          values: [for (final k in keys) _draft[k] ?? 1.0],
          min: 0.1,
          max: 2,
          caption: tr(xLabel),
          onChanged: (v) => _set(_draft.withValues({for (var i = 0; i < keys.length; i++) keys[i]: v[i]})),
        ),
    ]);
  }

  /// Where the curve begins when it is turned on: what the numbers it takes the place of give at [x] (0 to 1), so that the line looks as it did.
  double _curveStart(String prefix, double x) {
    final double v;
    if (prefix == 'pressure') {
      v = pressureFactor(math.pow(x, _draft['pressureCurve'] ?? 1).toDouble(), _draft['pressure'] ?? 0);
    } else {
      v = (1 - (_draft['speedThin'] ?? 0) * 0.35 * (x * 2 - 1).clamp(-1.0, 2.0)).clamp(0.3, 1.6);
    }
    return (v.clamp(0.1, 2.0) * 100).round() / 100;
  }

  final _advanced = ExpansibleController();

  /// Whether any advanced number of the design is not what it is when nothing is said (then the advanced part is open).
  bool _advancedUsed(BrushDesc d) => [for (final k in BrushDesc.knobsOf(d.kind)) if (k.advanced) k].any((k) => d[k.key] != null && (k.optional || d[k.key] != k.standard));

  List<Widget> _knobsSection() {
    final (usual, advanced) = _knobs();
    return [
      if (_draft.kind == BrushKind.mix) ..._partsSection(),
      ...usual,
      if (advanced.isNotEmpty)
        ExpansionTile(
          key: const ValueKey('brush-advanced'),
          controller: _advanced,
          tilePadding: EdgeInsets.zero,
          dense: true,
          initiallyExpanded: _advancedUsed(_draft),
          title: Text(tr('Advanced')),
          children: advanced,
        ),
    ];
  }

  /// The two brushes a mix is made of, each chosen from the brushes of the library and the ones to start from (a mix cannot be a part).
  List<Widget> _partsSection() {
    final choices = <String, BrushDesc>{};
    for (final d in [for (final b in _items) b.desc, ...BrushDesc.starting, ..._draft.parts]) {
      if (d.kind != BrushKind.mix) choices.putIfAbsent(d.id, () => d);
    }
    Widget pick(int index, String label) => Row(children: [
          SizedBox(width: 130, child: Text(tr(label), overflow: TextOverflow.ellipsis)),
          Expanded(
            child: DropdownButton<String>(
              key: ValueKey('brush-part-$index'),
              isExpanded: true,
              value: _draft.parts[index].id,
              items: [
                for (final e in choices.entries)
                  DropdownMenuItem(value: e.key, child: Text.rich(TextSpan(text: '${tr(e.value.name)} (${tr(_kindLabel(e.value.kind))})'), overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (id) {
                final d = choices[id];
                if (d != null) _set(_draft.withPart(index, d));
              },
            ),
          ),
        ]);
    return [pick(0, 'First brush'), pick(1, 'Second brush')];
  }

  static String _kindLabel(BrushKind k) => switch (k) {
        BrushKind.ink => 'Ink',
        BrushKind.roller => 'Roller',
        BrushKind.soft => 'Soft',
        BrushKind.charcoal => 'Charcoal',
        BrushKind.stamp => 'Stamp',
        BrushKind.mix => 'Mix',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final listed = _items.where((b) => b.listed).toList();
    final fromNotes = _items.where((b) => !b.listed).toList();
    final editingListed = _editing == null ? null : _items.where((b) => b.desc.id == _editing).firstOrNull?.listed;
    return PlatformAlertDialog(
      title: Text(tr('Design a brush')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              key: const ValueKey('brush-preview'),
              height: 96,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
              child: CustomPaint(size: Size.infinite, painter: _PreviewPainter(_brush, scheme.onSurface, _raster)),
            ),
            const SizedBox(height: 12),
            if (listed.isNotEmpty) ...[
              Text(tr('Your brushes'), style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [for (final b in listed) _chip(b)]),
              const SizedBox(height: 8),
            ],
            if (fromNotes.isNotEmpty)
              ExpansionTile(
                key: const ValueKey('brush-from-notes'),
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: Text(tr('Brushes that came with notes ({n})', {'n': fromNotes.length})),
                children: [Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 6, runSpacing: 4, children: [for (final b in fromNotes) _chip(b)]))],
              ),
            const Divider(),
            TextField(
              key: const ValueKey('brush-name'),
              controller: _name,
              maxLength: BrushDesc.maxName,
              decoration: InputDecoration(labelText: tr('Name'), border: const OutlineInputBorder(), counterText: ''),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Wrap(key: const ValueKey('brush-kind'), spacing: 6, runSpacing: 4, children: [
                  for (final k in BrushKind.values)
                    ChoiceChip(
                      key: ValueKey('brush-kind-${k.name}'),
                      label: Text(tr(_kindLabel(k))),
                      selected: _draft.kind == k,
                      onSelected: (_) => _set(BrushDesc(k, _name.text)),
                    ),
                ]),
              ),
              PopupMenuButton<BrushDesc>(
                key: const ValueKey('brush-start-from'),
                tooltip: tr('Start from the look of a brush'),
                icon: const Icon(Icons.auto_fix_high_outlined),
                onSelected: (d) => _set(d.named(_name.text)),
                itemBuilder: (_) => [for (final d in BrushDesc.starting) PopupMenuItem(value: d, child: Text(tr(d.name)))],
              ),
            ]),
            const SizedBox(height: 4),
            ..._knobsSection(),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_message!, key: const ValueKey('brush-message'), style: TextStyle(color: _problem ? scheme.error : scheme.onSurfaceVariant)),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              OutlinedButton.icon(key: const ValueKey('brush-import'), onPressed: _import, icon: const Icon(Icons.file_open_outlined), label: Text(tr('Import .strokedesc'))),
              OutlinedButton.icon(key: const ValueKey('brush-export'), onPressed: _export, icon: const Icon(Icons.ios_share), label: Text(tr('Export .strokedesc'))),
              OutlinedButton.icon(key: const ValueKey('brush-copy-code'), onPressed: _copyCode, icon: const Icon(Icons.copy_outlined), label: Text(tr('Copy as text'))),
              OutlinedButton.icon(key: const ValueKey('brush-paste-code'), onPressed: _pasteCode, icon: const Icon(Icons.content_paste_outlined), label: Text(tr('Paste from text'))),
              if (_editing != null) OutlinedButton.icon(key: const ValueKey('brush-save-copy'), onPressed: _saveCopy, icon: const Icon(Icons.copy_all_outlined), label: Text(tr('Save as a copy'))),
              if (_editing != null && editingListed != null)
                TextButton(
                  key: const ValueKey('brush-toggle-listed'),
                  onPressed: () => _toggleListed(_editing!, !editingListed),
                  child: Text(tr(editingListed ? 'Remove from the menu' : 'Add to the menu')),
                ),
              if (_editing != null) TextButton(key: const ValueKey('brush-new'), onPressed: _startNew, child: Text(tr('New brush'))),
              if (_editing != null && editingListed != null && !_askDelete)
                TextButton(
                  key: const ValueKey('brush-delete'),
                  onPressed: () => setState(() => _askDelete = true),
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: Text(tr('Delete')),
                ),
            ]),
            if (_askDelete && _editing != null)
              Container(
                key: const ValueKey('brush-delete-ask'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(8)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Delete this brush? Lines in your notes that are drawn with it are drawn with the pen from then on, unless a note file that has the brush is opened again.'), style: TextStyle(color: scheme.onErrorContainer)),
                  Wrap(spacing: 8, children: [
                    TextButton(key: const ValueKey('brush-delete-yes'), onPressed: _delete, child: Text(tr('Delete the brush'))),
                    TextButton(key: const ValueKey('brush-delete-no'), onPressed: () => setState(() => _askDelete = false), child: Text(tr('Keep it'))),
                  ]),
                ]),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(key: const ValueKey('brush-close'), onPressed: () => Navigator.pop(context), child: Text(tr('Close'))),
        FilledButton(key: const ValueKey('brush-save'), onPressed: _saveAndUse, child: Text(tr('Save and use'))),
      ],
    );
  }
}

/// Draws the sample line with the brush that is being designed, as the page draws a line of it.
class _PreviewPainter extends CustomPainter {
  final Brush brush;
  final Color color;
  final SoftRaster raster;

  _PreviewPainter(this.brush, this.color, this.raster);

  @override
  void paint(Canvas canvas, Size size) {
    // (the sample line is stretched over the whole strip; a width of 4 in the bar, as the brush makes it: the roller is five times that)
    final sample = _BrushDesignerState._stroke;
    final first = sample.points.first.dx;
    final k = (size.width - 28) / (sample.points.last.dx - first);
    final stroke = DrawingStroke(
      id: sample.id,
      color: color,
      width: 4 * brush.widthScale,
      points: [for (final p in sample.points) Offset(14 + (p.dx - first) * k, p.dy)],
      pressures: sample.pressures,
    );
    final shape = brush.shape(stroke);
    if (shape == null) return;
    paintBrushShape(canvas, stroke, shape, identityHashCode(brush), raster: raster);
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter old) => !identical(old.brush, brush) || old.color != color;
}

/// A small field that shows a number and takes another: what is typed is used when it is sent from the keyboard (or the field is left), and
/// brought into the range of the knob by the brush.
class _NumberBox extends StatefulWidget {
  final double value;
  final String text;
  final ValueChanged<double> onEntered;
  const _NumberBox({super.key, required this.value, required this.text, required this.onEntered});

  @override
  State<_NumberBox> createState() => _NumberBoxState();
}

class _NumberBoxState extends State<_NumberBox> {
  late final TextEditingController _controller = TextEditingController(text: widget.text);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _send();
    });
  }

  @override
  void didUpdateWidget(covariant _NumberBox old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _controller.text != widget.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final v = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (v != null && v.isFinite && v != widget.value) {
      widget.onEntered(v);
    } else {
      _controller.text = widget.text;
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 64,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          textAlign: TextAlign.end,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: Theme.of(context).textTheme.bodySmall,
          decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
          onSubmitted: (_) => _send(),
        ),
      );
}

/// A curve of five points spaced evenly along the way in (a pen's pressure, a hand's speed), each dragged up or down: how thick the line
/// is there compared to the width that is set. The line across the picture is the width as it is set (1).
class _CurveEditor extends StatefulWidget {
  final List<double> values;
  final double min, max;
  final String caption;
  final ValueChanged<List<double>> onChanged;

  const _CurveEditor({super.key, required this.values, required this.min, required this.max, required this.caption, required this.onChanged});

  static const _height = 110.0, _pad = 14.0;

  @override
  State<_CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<_CurveEditor> {
  /// The point that is being dragged.
  int _active = 0;

  double _value(double y) => (widget.min + (1 - (y - _CurveEditor._pad) / (_CurveEditor._height - 2 * _CurveEditor._pad)) * (widget.max - widget.min)).clamp(widget.min, widget.max);

  void _set(double y) {
    final next = List.of(widget.values);
    next[_active] = (_value(y) * 100).round() / 100;
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LayoutBuilder(
        builder: (context, box) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          // (dragging up and down only: a drag that is free would lose to the scrolling of the dialog, which is up and down as well)
          onVerticalDragDown: (d) {
            final step = (box.maxWidth - 2 * _CurveEditor._pad) / (widget.values.length - 1);
            _active = ((d.localPosition.dx - _CurveEditor._pad) / step).round().clamp(0, widget.values.length - 1);
            _set(d.localPosition.dy);
          },
          onVerticalDragUpdate: (d) => _set(d.localPosition.dy),
          child: SizedBox(
            height: _CurveEditor._height,
            width: double.infinity,
            child: CustomPaint(painter: _CurvePainter(widget.values, widget.min, widget.max, scheme.primary, scheme.outlineVariant, scheme.surfaceContainerHighest)),
          ),
        ),
      ),
      Text(widget.caption, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _CurvePainter extends CustomPainter {
  final List<double> values;
  final double min, max;
  final Color line, grid, fill;

  _CurvePainter(this.values, this.min, this.max, this.line, this.grid, this.fill);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)), Paint()..color = fill);
    final w = size.width - 2 * _CurveEditor._pad;
    double y(double v) => _CurveEditor._pad + (1 - (v - min) / (max - min)) * (size.height - 2 * _CurveEditor._pad);
    // (the width that is set is the line across the middle)
    final set = y(1);
    canvas.drawLine(Offset(_CurveEditor._pad, set), Offset(size.width - _CurveEditor._pad, set), Paint()..color = grid);
    final points = [for (var i = 0; i < values.length; i++) Offset(_CurveEditor._pad + w * i / (values.length - 1), y(values[i]))];
    canvas.drawPath(Path()..addPolygon(points, false), Paint()..color = line..style = PaintingStyle.stroke..strokeWidth = 2);
    for (final p in points) {
      canvas.drawCircle(p, 6, Paint()..color = line);
    }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) => !listEquals(old.values, values) || old.line != line;
}
