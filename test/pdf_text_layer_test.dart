import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/models/pdf_models.dart';
import 'package:notes/pdf/pdf_text_layer.dart';

PdfTextLine _line(String text, double y) {
  final words = <PdfTextWord>[];
  var x = 10.0, at = 0;
  for (final w in text.split(' ')) {
    words.add(PdfTextWord(xMin: x, yMin: y, xMax: x + w.length * 10, yMax: y + 12, text: w, startIndex: at, endIndex: at + w.length));
    x += (w.length + 1) * 10;
    at += w.length + 1;
  }
  return PdfTextLine(xMin: 10, yMin: y, xMax: x - 10, yMax: y + 12, text: text, words: words);
}

void main() {
  final page = PdfPageWords(pageWidth: 400, pageHeight: 400, lines: [_line('alpha beta gamma', 20), _line('delta epsilon', 60)]);

  Future<void> show(WidgetTester tester, ValueChanged<String?> onChanged) => tester.pumpWidget(MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SelectionArea(
            onSelectionChanged: (c) => onChanged(c?.plainText),
            child: PdfTextLayer(page: page, width: 400, height: 400),
          ),
        ),
      ));

  testWidgets('the words are found where the page has them', (tester) async {
    await show(tester, (_) {});
    final r = tester.renderObject<RenderPdfTextLayer>(find.byType(PdfTextLayer));
    expect(r.wordRects('beta').single.center.dx, closeTo(10 + 6 * 10 + 20, 1));
    expect(r.wordRects('epsilon').single.top, closeTo(60, 0.1));
    expect(r.wordRects('nothing'), isEmpty);
  });

  testWidgets('a long press selects the word, a drag across lines the text between', (tester) async {
    String? selected;
    await show(tester, (s) => selected = s);
    await tester.longPressAt(const Offset(10 + 7 * 10, 26)); // in "beta"
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected, 'beta');
    final r = tester.renderObject<RenderPdfTextLayer>(find.byType(PdfTextLayer));
    expect(r.selectedSpans.single.$1.text, 'alpha beta gamma');

    // the mouse: from the start of "gamma" down to the end of "delta"
    await tester.tapAt(const Offset(300, 300));
    await tester.pump();
    final g = await tester.startGesture(const Offset(10 + 11 * 10 + 1, 26), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
    await g.moveTo(const Offset(10 + 5 * 10, 66));
    await g.up();
    await tester.pump();
    expect(selected, 'gamma\ndelta');
  });

  testWidgets('select all takes the page text, and the area keeps its select-all for the words of another page', (tester) async {
    String? selected;
    await show(tester, (s) => selected = s);
    final state = tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    state.selectAll();
    await tester.pump();
    expect(selected, 'alpha beta gamma\ndelta epsilon');
    await tester.pumpWidget(MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SelectionArea(child: PdfTextLayer(page: PdfPageWords(pageWidth: 400, pageHeight: 400, lines: [_line('one two', 20)]), width: 400, height: 400)),
      ),
    ));
    // (the area applies its select-all to what is new in it: the other page's 'one two')
    expect(tester.renderObject<RenderPdfTextLayer>(find.byType(PdfTextLayer)).selection, (0, 7));
  });
}
