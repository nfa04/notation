import 'dart:math' as math;
import 'dart:ui';

import '../algebra/checker.dart';
import '../algebra/truth_table.dart';
import '../data/note_data.dart';
import '../diagram/advanced.dart';
import '../diagram/diagram.dart';
import '../diagram/diagram_layout.dart';
import '../diagram/graph_layout.dart' show GraphHighlight;
import '../diagram/place_layout.dart';
import '../features/feature.dart';
import '../l10n/language.dart';
import '../models/canvas_models.dart';
import '../models/page_background.dart';
import '../models/rich_text.dart';

/// The note the intro offers to make: pages that show what the app does with real things, each made by the app's own code (the mind
/// map from an outline, the truth table and the marks from the checker, the state machine, the tree and the graph from a few
/// lines of text), for the tools the person has on and no others. Nothing is a trap: it is there to be written on, changed and thrown
/// away. Words are looked up when the note is made, so they follow the language then in use.
void fillWelcomeNote(NoteData note, Set<Feature> tools) {
  note.background = PageBackground.blank;
  bool on(Feature f) => tools.contains(f);
  final maths = on(Feature.checkMaths) || on(Feature.solve);
  final doc = StringBuffer()
    ..writeln('# ${tr('Welcome to Notation')}')
    ..writeln()
    ..writeln(tr('Everything in this note was made by the app. Write on it, change it, delete it: it is only here to try things on.'))
    ..writeln()
    ..writeln('[toc]')
    ..writeln()
    ..writeln('## ${tr('Write like a document')}')
    ..writeln()
    ..writeln(tr('This page is a written document: **bold**, *italic*, `code` and ==highlights== are just Markdown, and the bar at the side formats the text for you. Headings, the table of contents above, tables, pictures and footnotes[^1] all work, and it prints as pages.'))
    ..writeln()
    ..writeln('## ${tr('Write and draw')}')
    ..writeln()
    ..writeln(tr('Pick the pen in the drawing bar and write anywhere, with a stylus or a finger. Draw a ring round something with the lasso to move, copy or delete it. A note can hold both: the written document first, then pages to draw on.'))
    ..writeln();

  if (maths) {
    const steps = [r'2x + 3 = 11', r'2x = 8', r'x = 4'];
    final checks = checkLines(steps);
    final shown = [for (var i = 0; i < steps.length; i++) '${steps[i]}    ${checks[i].verdict == Verdict.right ? '✓' : ''}'.trimRight()];
    final product = answerFor(r'17 \cdot 24 =');
    doc
      ..writeln('## ${tr('Maths')}')
      ..writeln()
      ..writeln(tr('Write a worked solution by hand. A moment later each line gets a green check or a red cross; tap it to see what was checked. Like this:'))
      ..writeln()
      ..writeln(shown.map((l) => '> $l').join('\n'));
    if (product != null && RegExp(r'^\d+$').hasMatch(product)) {
      doc
        ..writeln()
        ..writeln(tr('End a calculation with = and the result appears:'))
        ..writeln()
        ..writeln('> 17 · 24 = $product');
    }
    doc.writeln();
  }

  if (on(Feature.tables)) {
    final line = parseFormulaText('(p and q) -> r');
    final table = line == null ? null : buildTruthTable(line.formulas);
    if (table != null) {
      final verdict = switch (table.kind()) {
        LogicKind.tautology => tr('true in every row'),
        LogicKind.contradiction => tr('false in every row'),
        LogicKind.contingent => tr('true in {n} of {rows} rows', {'n': table.trueRows(), 'rows': table.rows.length}),
      };
      doc
        ..writeln('## ${tr('Truth tables')}')
        ..writeln()
        ..writeln(tr('The grid button makes the truth table of a formula, with a column for every part of it. This is (p ∧ q) → r:'))
        ..writeln()
        ..writeln(table.markdown())
        ..writeln()
        ..writeln('${tr('It is')} $verdict.')
        ..writeln();
    }
  }

  if (on(Feature.diagrams)) {
    doc
      ..writeln('## ${tr('Diagrams from a few lines of text')}')
      ..writeln()
      ..writeln(tr('A mind map, a state machine, a search tree and a graph with its shortest ways: drawn from text, on the next page. The facts under each were worked out by the app.'))
      ..writeln();
  }

  final more = <String>[
    if (on(Feature.flashcards)) tr('Flashcards from your notes and your mistakes'),
    if (on(Feature.citations)) tr('Citations with [@key] and a list of sources'),
    if (on(Feature.pdf)) tr('PDFs to write on, and notes as PDF'),
    if (on(Feature.calendar)) tr('A calendar and tasks'),
    if (on(Feature.live)) tr('Notes written together, live'),
  ];
  doc
    ..writeln('## ${tr('And more')}')
    ..writeln();
  for (final m in more) {
    doc.writeln('- $m');
  }
  doc
    ..writeln()
    ..writeln(tr('The settings hold the tools you can switch on and off, the models to download and the switch for all the AI features.'))
    ..writeln()
    ..writeln('[^1]: ${tr('Like this one. The next page is a notebook page: draw on it.')}');
  note.documentText = doc.toString();

  // the pages to draw on: the diagrams, made by the app's own code
  if (on(Feature.diagrams)) {
    final w = _Writer(note, firstPage: 1);
    final outline = StringBuffer('- Notation\n')
      ..writeln('  - ${tr('Write and draw')}')
      ..writeln('    - ${tr('Pen and highlighter')}')
      ..writeln('    - ${tr('Lasso and layers')}');
    if (maths || on(Feature.plots)) {
      outline
        ..writeln('  - ${tr('Maths')}')
        ..writeln('    - ${tr('Check my working')}')
        ..writeln('    - ${tr('Solve and plot')}');
    }
    outline
      ..writeln('  - ${tr('Diagrams')}')
      ..writeln('    - ${tr('Mind maps')}')
      ..writeln('    - ${tr('Automata, trees, graphs')}');
    if (on(Feature.flashcards) || on(Feature.citations)) {
      outline
        ..writeln('  - ${tr('Study')}')
        ..writeln('    - ${tr('Flashcards')}')
        ..writeln('    - ${tr('Citations')}');
    }
    if (on(Feature.live)) {
      outline
        ..writeln('  - ${tr('Together')}')
        ..writeln('    - ${tr('Live sessions')}');
    }
    w.diagram(layoutDiagram(parseOutline(outline.toString())), maxHeight: 340);
    w.caption(tr('A mind map, made from a list with the diagram button.'));
    final a = buildAdvanced(DiagramMode.automaton, exampleFor(DiagramMode.automaton));
    final t = buildAdvanced(DiagramMode.tree, exampleFor(DiagramMode.tree));
    final g = buildAdvanced(DiagramMode.graph, exampleFor(DiagramMode.graph), options: const AdvancedOptions(highlight: GraphHighlight.shortest));
    w.diagramRow([
      (a.layout, _firstFacts(a, 2)),
      (t.layout, _firstFacts(t, 2)),
    ], maxHeight: 250);
    w.diagramRow([(g.layout, _firstFacts(g, 2))], maxHeight: 280);
    w.finish();
  }
}

String _firstFacts(AdvancedDiagram d, int n) => [for (final f in d.facts.take(n)) '${tr(f.$1)}: ${tr(f.$2)}'].join('\n');

/// Lays things out one under the other, and on to the next page when a page is full.
class _Writer {
  static const left = 30.0, width = 740.0, gap = 14.0, pageHeight = 1131.0, bottom = 40.0;

  final NoteData note;
  final Map<int, List<TextBoxWidgetModel>> boxes = {};
  final Map<int, List<DrawingStroke>> strokes = {};
  int page;
  double y = 30;
  int _ids = 0;

  _Writer(this.note, {int firstPage = 0}) : page = firstPage;

  void _room(double height) {
    if (y + height > pageHeight - bottom && y > 60) {
      page++;
      y = 30;
    }
  }

  TextBoxWidgetModel _make(String text, Offset at, Size size, double fontSize, TextBoxStyle style, {bool bold = false}) {
    final box = TextBoxWidgetModel(id: 'welcome${++_ids}', position: at, size: size, initialText: text, fontSize: fontSize, style: style);
    if (bold) box.controller.attributes.add(TextSpanAttribute(start: 0, end: text.length, type: AttributeType.bold));
    return box;
  }

  void box(String text, {required double height, double fontSize = 15, bool bold = false, TextBoxStyle style = _plain}) {
    _room(height);
    boxes.putIfAbsent(page, () => []).add(_make(text, Offset(left, y), Size(width, height), fontSize, style, bold: bold));
    y += height + gap;
  }

  /// A paragraph without a frame.
  void text(String text) => box(text, height: boxHeight(text, width), style: const TextBoxStyle(opacity: 0, borderWidth: 0));

  void caption(String text, {bool close = true}) {
    if (close) y -= gap - 2;
    box(text, height: boxHeight(text, width) - 6, fontSize: 13, style: const TextBoxStyle(opacity: 0, borderWidth: 0, textColor: Color(0xFF616161)));
  }

  /// A heading; it goes to the next page with the [keepWith] units of what follows it, if they do not fit under it.
  void sectionTitle(String title, {double keepWith = 80}) {
    _room(keepWith);
    boxes.putIfAbsent(page, () => []).add(_make(title, Offset(left, y), const Size(width, 34), 20, const TextBoxStyle(opacity: 0, borderWidth: 0), bold: true));
    y += 34 + 6;
  }

  /// A framed block: a bold title line, then [body].
  void section(String title, String body) {
    final text = '**$title**\n$body';
    box(text, height: boxHeight(text, width), style: _framed);
  }

  /// Framed blocks side by side (one alone takes the whole width).
  void row(List<String> bodies) {
    if (bodies.isEmpty) return;
    final each = (width - (bodies.length - 1) * 20) / bodies.length;
    final height = bodies.map((b) => boxHeight(b, each)).fold<double>(0, math.max);
    _room(height);
    for (var i = 0; i < bodies.length; i++) {
      boxes.putIfAbsent(page, () => []).add(_make(bodies[i], Offset(left + i * (each + 20), y), Size(each, height), 15, _framed));
    }
    y += height + gap;
  }

  void diagram(DiagramLayout layout, {required double maxHeight}) {
    final fit = _fit(layout, width, maxHeight);
    _room(fit.size.height);
    final origin = Offset(left + (width - fit.size.width) / 2, y);
    _add(placeLayout(fit, origin));
    y += fit.size.height + gap;
  }

  /// Diagrams side by side, each with its facts under it.
  void diagramRow(List<(DiagramLayout, String)> items, {required double maxHeight}) {
    final each = (width - (items.length - 1) * 20) / items.length;
    final fits = [for (final i in items) _fit(i.$1, each, maxHeight)];
    final tallest = fits.fold<double>(0, (m, f) => math.max(m, f.size.height));
    final factLines = items.map((i) => '\n'.allMatches(i.$2).length + 1).fold<int>(0, math.max);
    final total = tallest + 8 + factLines * 20 + 10;
    _room(total);
    for (var i = 0; i < items.length; i++) {
      final x = left + i * (each + 20);
      final fit = fits[i];
      _add(placeLayout(fit, Offset(x + (each - fit.size.width) / 2, y + (tallest - fit.size.height) / 2)));
      if (items[i].$2.isNotEmpty) {
        boxes.putIfAbsent(page, () => []).add(_make(items[i].$2, Offset(x, y + tallest + 8), Size(each, factLines * 20 + 10), 13, const TextBoxStyle(opacity: 0, borderWidth: 0, textColor: Color(0xFF424242))));
      }
    }
    y += total + gap;
  }

  void _add(({List<TextBoxWidgetModel> boxes, List<DrawingStroke> strokes}) placed) {
    boxes.putIfAbsent(page, () => []).addAll(placed.boxes);
    strokes.putIfAbsent(page, () => []).addAll(placed.strokes);
  }

  void finish() {
    note.textBoxes = boxes;
    note.strokes = strokes;
  }

  static DiagramLayout _fit(DiagramLayout l, double w, double h) {
    var out = l.fitted(w, minScale: 0.3);
    if (out.size.height > h) out = out.fitted(math.max(60, out.size.width * h / out.size.height), minScale: 0.25);
    return out;
  }

  static const _plain = TextBoxStyle(opacity: 0, borderWidth: 0);
  static const _framed = TextBoxStyle(background: Color(0xFFFFFFFF), opacity: 0, borderWidth: 1, borderColor: Color(0xFFBDBDBD), radius: 8);
}

/// About how tall a text box has to be for [text] at the usual size: a line is about 85 letters wide at 740 units, a table row is a line.
double boxHeight(String text, double width) {
  final perLine = width / 8.8;
  var lines = 0;
  for (final line in text.split('\n')) {
    lines += math.max(1, (line.length / perLine).ceil());
  }
  return lines * 22.0 + 24;
}
