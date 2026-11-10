import 'package:flutter/material.dart' hide Text;

import '../diagram/advanced.dart';
import '../diagram/automaton.dart';
import '../diagram/diagram.dart';
import '../diagram/diagram_layout.dart';
import '../diagram/graph_layout.dart' show GraphHighlight;
import '../diagram/tree.dart' show parseTree;
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../style/platform_dialog.dart';

const _mindMapExample = '- Plants\n  - Roots\n    - Water\n    - Minerals\n  - Leaves\n    - Light\n  - Flowers';
const _flowExample = 'Start -> Read the input -> Valid?\nValid? -> Save the result : yes\nValid? -> Ask again : no\nAsk again -> Read the input\nSave the result -> Done';

/// What the dialog asks for: the text of a diagram, which kind it is, and how to show it.
class DiagramRequest {
  final DiagramMode mode;
  final String text;
  final AdvancedOptions options;

  const DiagramRequest(this.mode, this.text, [this.options = const AdvancedOptions()]);
}

/// Asks for a diagram: an outline for a mind map, or lines with arrows for a flowchart, or (in the advanced kinds) a state diagram, a tree or a
/// graph, with a preview that follows what is typed. [draft] writes an outline from the note (the assistant), null: not offered. The answer
/// is null when cancelled.
///
/// [mode] and [initial] start the dialog on a kind of diagram with its text (read from a drawing, say), and [note] says where it comes from.
Future<DiagramRequest?> askDiagram(
  BuildContext context, {
  String initial = '',
  String rootTitle = '',
  Future<String?> Function()? draft,
  DiagramMode mode = DiagramMode.simple,
  String? note,
}) =>
    showDialog<DiagramRequest>(
      context: context,
      builder: (context) => _DiagramDialog(initial: initial, rootTitle: rootTitle, draft: draft, mode: mode, note: note),
    );

class _DiagramDialog extends StatefulWidget {
  final String initial;
  final String rootTitle;
  final Future<String?> Function()? draft;
  final DiagramMode mode;
  final String? note;

  const _DiagramDialog({required this.initial, required this.rootTitle, this.draft, this.mode = DiagramMode.simple, this.note});

  @override
  State<_DiagramDialog> createState() => _DiagramDialogState();
}

class _DiagramDialogState extends State<_DiagramDialog> {
  late DiagramMode _mode = widget.mode;
  late final _texts = {
    for (final m in DiagramMode.values) m: TextEditingController(text: m == widget.mode ? widget.initial : ''),
  };
  final _word = TextEditingController();
  bool _drafting = false;
  String? _problem;
  GraphHighlight _highlight = GraphHighlight.none;
  bool _balance = false;
  final _variants = {for (final m in DiagramMode.values) m: 0};

  TextEditingController get _text => _texts[_mode]!;

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    _word.dispose();
    super.dispose();
  }

  AdvancedOptions get _options => AdvancedOptions(highlight: _highlight, balance: _balance);

  Future<void> _draft() async {
    setState(() {
      _drafting = true;
      _problem = null;
    });
    try {
      final text = await widget.draft!();
      if (!mounted) return;
      setState(() {
        _drafting = false;
        if (text != null && text.trim().isNotEmpty) {
          _text.text = text.trim();
        } else {
          _problem = tr('The assistant did not write an outline. Try again.');
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _drafting = false;
          _problem = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  void _example() {
    final v = _variants[_mode]!;
    setState(() {
      _text.text = exampleFor(_mode, variant: v);
      _variants[_mode] = v + 1;
    });
  }

  bool get _canInsert => _mode == DiagramMode.simple ? !parseDiagram(_text.text, rootTitle: widget.rootTitle).isEmpty : !buildAdvanced(_mode, _text.text, options: _options).isEmpty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PlatformAlertDialog(
      title: const Text('Mind map or diagram'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.note != null) ...[
              Text.verbatim(widget.note!, key: const ValueKey('diagram-note'), style: TextStyle(color: scheme.primary, fontSize: 13)),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<DiagramMode>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(value: DiagramMode.simple, label: Text('Outline or flowchart', key: const ValueKey('diagram-mode-simple'))),
                  ButtonSegment(value: DiagramMode.automaton, label: Text('Automaton', key: const ValueKey('diagram-mode-automaton'))),
                  ButtonSegment(value: DiagramMode.tree, label: Text('Tree', key: const ValueKey('diagram-mode-tree'))),
                  ButtonSegment(value: DiagramMode.graph, label: Text('Graph', key: const ValueKey('diagram-mode-graph'))),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() {
                  _mode = s.first;
                  _problem = null;
                }),
              ),
            ),
            const SizedBox(height: 8),
            Text(_help, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              if (_mode == DiagramMode.simple) ...[
                ActionChip(key: const ValueKey('diagram-example-mindmap'), label: const Text('Example: mind map'), onPressed: () => setState(() => _text.text = _mindMapExample)),
                ActionChip(key: const ValueKey('diagram-example-flow'), label: const Text('Example: flowchart'), onPressed: () => setState(() => _text.text = _flowExample)),
              ] else
                ActionChip(key: const ValueKey('diagram-example'), label: const Text('Show an example'), onPressed: _example),
              if (_mode == DiagramMode.simple && widget.draft != null)
                ActionChip(
                  key: const ValueKey('diagram-draft'),
                  avatar: _drafting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator.adaptive(strokeWidth: 2,)) : const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Draft from this note'),
                  onPressed: _drafting ? null : _draft,
                ),
            ]),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('diagram-text'),
              controller: _text,
              minLines: 6,
              maxLines: 10,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(border: OutlineInputBorder(), alignLabelWithHint: true),
            ),
            if (_problem != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text.verbatim(_problem!, key: const ValueKey('diagram-problem'), style: TextStyle(color: scheme.error))),
            if (_mode != DiagramMode.simple) ..._advanced(context),
            const SizedBox(height: 12),
            _mode == DiagramMode.simple ? _Preview(text: _text.text, rootTitle: widget.rootTitle) : _AdvancedPreview(diagram: buildAdvanced(_mode, _text.text, options: _options), mode: _mode),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('diagram-insert'),
          onPressed: _canInsert ? () => Navigator.pop(context, DiagramRequest(_mode, _text.text, _options)) : null,
          child: const Text('Insert'),
        ),
      ],
    );
  }

  String get _help => switch (_mode) {
        DiagramMode.simple => tr('Write an outline (a list, nested by indenting) for a mind map, or lines with arrows for a flowchart: Start -> Check -> Done. A line can be given a label after a colon.'),
        DiagramMode.automaton => tr('One line for each arrow: q0 -a-> q1 (q0 --a,b--> q1 for two symbols, -eps-> for the empty word). Say where it starts and which states accept: start: q0, accept: q2 (or >q0 and *q2).'),
        DiagramMode.tree => tr('Brackets: A(B(D,E),C), a gap for a missing child: 8(3,10(,14). Or numbers put into a search tree, bst: 8 3 10 1 (also avl:, minheap:, maxheap:, array: 1 3 2 4). Lines after that: insert 7, delete 3.'),
        DiagramMode.graph => tr('One line for each edge: A - B, an arrow A -> B, a weight A -3- B (or A - B : 3), a chain A - B - C. A node on its own gets a line of its own. start: A says where the searches begin.'),
      };

  /// What goes with the advanced kinds: the options, what could not be read, what is worth telling.
  List<Widget> _advanced(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diagram = buildAdvanced(_mode, _text.text, options: _options);
    final auto = _mode == DiagramMode.automaton ? parseAutomaton(_text.text).automaton : null;
    return [
      if (_mode == DiagramMode.graph) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 6, children: [
          for (final (h, label) in [
            (GraphHighlight.none, 'Plain'),
            (GraphHighlight.shortest, 'Shortest paths'),
            (GraphHighlight.spanning, 'Spanning tree'),
            (GraphHighlight.breadthFirst, 'Breadth first'),
            (GraphHighlight.depthFirst, 'Depth first'),
          ])
            ChoiceChip(
              key: ValueKey('graph-highlight-${h.name}'),
              visualDensity: VisualDensity.compact,
              label: Text(label),
              selected: _highlight == h,
              onSelected: (_) => setState(() => _highlight = h),
            ),
        ]),
      ],
      if (_mode == DiagramMode.tree && _isSearchTree)
        CheckboxListTile.adaptive(
          key: const ValueKey('tree-balance'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _balance,
          onChanged: (v) => setState(() => _balance = v ?? false),
          title: const Text('Show the balance factors'),
        ),
      if (auto != null && !auto.isEmpty) ..._automatonTools(context, auto),
      if (diagram.problems.isNotEmpty) ...[
        const SizedBox(height: 8),
        Column(key: const ValueKey('diagram-problems'), crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final p in diagram.problems) Text.verbatim('⚠ ${_problemText(p)}', style: TextStyle(color: scheme.error, fontSize: 12)),
        ]),
      ],
      if (diagram.facts.isNotEmpty) ...[
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('diagram-facts'),
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (name, value) in diagram.facts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 130, child: Text.verbatim(tr(name), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12))),
                  Expanded(child: SelectableText(_factValue(name, value), style: const TextStyle(fontSize: 13))),
                ]),
              ),
          ]),
        ),
      ],
    ];
  }

  bool get _isSearchTree {
    final kind = RegExp(r'^\s*(bst|avl)\s*:', caseSensitive: false).hasMatch(_text.text);
    return kind && !parseTree(_text.text).tree.isEmpty;
  }

  static String _problemText(String p) {
    final m = RegExp(r'^line (\d+): (.*)$').firstMatch(p);
    if (m != null) return tr('Line {n} is not understood: {text}', {'n': m[1], 'text': m[2]});
    return tr(p);
  }

  static const _translatedValues = {'Kind', 'Shape', 'Search tree', 'Balanced (AVL)', 'Min-heap', 'Max-heap', 'Has a cycle', 'Bipartite', 'Complete', 'Order'};

  static String _factValue(String name, String value) {
    if (!_translatedValues.contains(name)) {
      return value == '—' || value.startsWith('none') || value == 'not for negative weights' ? tr(value) : value;
    }
    return value.split(', ').map(tr).join(', ');
  }

  /// A word to try on the automaton, and the buttons that make it deterministic or small.
  List<Widget> _automatonTools(BuildContext context, Automaton auto) {
    final scheme = Theme.of(context).colorScheme;
    final run = auto.start == null ? null : runWord(auto, _word.text);
    String path(AutomatonRun r) {
      final deterministic = r.sets.every((s) => s.length <= 1);
      String one(Set<String> s) => deterministic ? (s.isEmpty ? '∅' : s.first) : '{${s.join(',')}}';
      return r.sets.map(one).join(' → ');
    }

    return [
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('automaton-word'),
            controller: _word,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(labelText: tr('Try a word'), isDense: true, border: const OutlineInputBorder()),
          ),
        ),
        const SizedBox(width: 8),
        if (run != null)
          Chip(
            key: const ValueKey('automaton-result'),
            visualDensity: VisualDensity.compact,
            label: Text.verbatim(run.accepted ? tr('accepted') : tr('rejected')),
            backgroundColor: (run.accepted ? Colors.green : Colors.red).withValues(alpha: 0.15),
          ),
      ]),
      if (run != null && _word.text.isNotEmpty || run != null && _word.text.trim().isEmpty && false)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.verbatim(
            run.stuckAfter == null ? path(run) : '${path(run)}  (${tr('stuck after {n} symbols', {'n': run.stuckAfter})})',
            key: const ValueKey('automaton-path'),
            style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        OutlinedButton(
          key: const ValueKey('automaton-dfa'),
          onPressed: auto.start == null || auto.isDeterministic ? null : () => setState(() => _text.text = toDeterministic(auto).toText()),
          child: const Text('Make it deterministic'),
        ),
        OutlinedButton(
          key: const ValueKey('automaton-minimize'),
          onPressed: auto.start == null ? null : () => setState(() => _text.text = minimize(auto).toText()),
          child: const Text('Make it smallest'),
        ),
      ]),
    ];
  }
}

class _AdvancedPreview extends StatelessWidget {
  final AdvancedDiagram diagram;
  final DiagramMode mode;

  const _AdvancedPreview({required this.diagram, required this.mode});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = switch (mode) {
      DiagramMode.automaton => tr('Automaton'),
      DiagramMode.tree => tr('Tree'),
      _ => tr('Graph'),
    };
    return Container(
      height: 260,
      width: double.infinity,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: diagram.isEmpty
          ? Center(child: Text('The picture appears here.', style: TextStyle(color: scheme.onSurfaceVariant)))
          : Stack(children: [
              Positioned.fill(child: Padding(padding: const EdgeInsets.all(8), child: CustomPaint(key: const ValueKey('diagram-preview'), painter: DiagramPainter(diagram.layout, scheme.onSurface)))),
              Positioned(right: 8, top: 4, child: Text.verbatim(tr('{kind}: {n} boxes', {'kind': kind, 'n': diagram.layout.boxes.length}), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
            ]),
    );
  }
}

class _Preview extends StatelessWidget {
  final String text;
  final String rootTitle;

  const _Preview({required this.text, required this.rootTitle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diagram = parseDiagram(text, rootTitle: rootTitle);
    final kind = diagram.kind == DiagramKind.flow ? tr('Flowchart') : tr('Mind map');
    return Container(
      height: 200,
      width: double.infinity,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: diagram.isEmpty
          ? Center(child: Text('The picture appears here.', style: TextStyle(color: scheme.onSurfaceVariant)))
          : Stack(children: [
              Positioned.fill(child: Padding(padding: const EdgeInsets.all(8), child: CustomPaint(key: const ValueKey('diagram-preview'), painter: DiagramPainter(layoutDiagram(diagram), scheme.onSurface)))),
              Positioned(right: 8, top: 4, child: Text.verbatim(tr('{kind}: {n} boxes', {'kind': kind, 'n': diagram.nodes.length}), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
            ]),
    );
  }
}

/// Draws a laid-out diagram, scaled to fit the space it is given.
class DiagramPainter extends CustomPainter {
  final DiagramLayout layout;
  final Color textColor;

  DiagramPainter(this.layout, this.textColor);

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.isEmpty || layout.size.isEmpty) return;
    final k = (size.width / layout.size.width).clamp(0.05, 1.0) < (size.height / layout.size.height).clamp(0.05, 1.0)
        ? (size.width / layout.size.width).clamp(0.05, 1.0)
        : (size.height / layout.size.height).clamp(0.05, 1.0);
    canvas
      ..save()
      ..translate((size.width - layout.size.width * k) / 2, (size.height - layout.size.height * k) / 2)
      ..scale(k);
    for (final line in layout.lines) {
      final path = Path()..moveTo(line.points.first.dx, line.points.first.dy);
      for (final p in line.points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, Paint()..color = line.color..style = PaintingStyle.stroke..strokeWidth = line.width..strokeJoin = StrokeJoin.round);
    }
    for (final b in layout.boxes) {
      final r = RRect.fromRectAndRadius(b.rect, Radius.circular(b.radius));
      canvas.drawRRect(r, Paint()..color = b.fill);
      canvas.drawRRect(r, Paint()..color = b.border..style = PaintingStyle.stroke..strokeWidth = 2);
      final tp = TextPainter(
        text: TextSpan(text: wrapLabel(b.text, 22).join('\n'), style: TextStyle(color: b.fill.computeLuminance() < 0.3 ? Colors.white : Colors.black87, fontSize: b.fontSize, fontWeight: b.bold ? FontWeight.bold : FontWeight.normal)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: b.rect.width);
      tp.paint(canvas, b.rect.center - Offset(tp.width / 2, tp.height / 2));
    }
    for (final l in layout.labels) {
      final tp = TextPainter(text: TextSpan(text: l.text, style: TextStyle(color: textColor, fontSize: 13)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, l.center - Offset(tp.width / 2, tp.height / 2));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DiagramPainter old) => old.layout != layout || old.textColor != textColor;
}
