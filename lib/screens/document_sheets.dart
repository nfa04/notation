import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../markdown/live_markdown.dart' show LivePieceKey;

/// Where the sheets of a written document end, down from the top of its text. [lineBottoms] are the bottoms of its lines, [total] the
/// height of all of it, [marks] where its page breaks end and [room] the height of the text on a sheet (the sheet without its margins).
/// A sheet ends at the end of the last line that fits, at a page break when one comes sooner, and where it is full when a single line
/// is taller than it. Empty when everything fits on one sheet; otherwise one end for every sheet but the last.
List<double> sheetBreaks(List<double> lineBottoms, double total, List<double> marks, double room) {
  if (room < 50) return const [];
  const slack = 0.5;
  final ends = <double>[];
  var top = 0.0;
  while (ends.length < 500) {
    final limit = top + room;
    final earlier = marks.where((y) => y > top + 1 && y <= limit + slack).firstOrNull;
    // (the text of a page break is the last thing on its page: with nothing after it, there is no next page)
    if (earlier == null && total <= limit + slack) break;
    final end = earlier ?? _lastLineEnd(lineBottoms, top + 1, limit + slack) ?? limit;
    if (end >= total - slack) break;
    ends.add(end);
    top = end;
  }
  return ends;
}

/// The last of [sorted] that is more than [above] and not more than [upTo].
double? _lastLineEnd(List<double> sorted, double above, double upTo) {
  var lo = 0, hi = sorted.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid] <= upTo) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo > 0 && sorted[lo - 1] > above ? sorted[lo - 1] : null;
}

/// [sheetBreaks] for the text that [view] (a `LiveMarkdownView`, built in [context]) has laid out, and where each of its pieces begins.
///
/// [known] keeps what was found of each piece: a document that is measured as it comes in is not gone through again for each of its pieces.
({List<double> breaks, List<double> pieceTops}) documentSheetBreaks(RenderBox view, BuildContext context, double room, Map<InlineSpan, List<double>> known) {
  final texts = <int, RenderParagraph>{};
  final marks = <double>[];
  void look(Element e) {
    if (e.widget.key == const ValueKey('live-page-break')) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize) marks.add(box.localToGlobal(Offset(0, box.size.height), ancestor: view).dy);
      return;
    }
    if (e.widget.key case LivePieceKey(:final value) when e.renderObject is RenderParagraph) texts[value] = e.renderObject as RenderParagraph;
    e.visitChildren(look);
  }

  (context as Element).visitChildren(look);
  if (texts.isEmpty || texts.values.any((t) => !t.hasSize)) return (breaks: const [], pieceTops: const []);
  final bottoms = <double>{};
  final tops = <double>[];
  final kept = Map<InlineSpan, List<double>>.identity();
  for (final piece in texts.keys.toList()..sort()) {
    final paragraph = texts[piece]!;
    final top = paragraph.localToGlobal(Offset.zero, ancestor: view).dy;
    tops.add(top);
    // (the boxes of the whole text, each as tall as its line: where the lines end)
    final lines = kept[paragraph.text] = known[paragraph.text] ??
        [
          for (final b in paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: paragraph.text.toPlainText().length),
            boxHeightStyle: BoxHeightStyle.max,
          ))
            b.bottom,
        ];
    bottoms.addAll([for (final b in lines) ((b + top) * 10).round() / 10]);
  }
  known
    ..clear()
    ..addAll(kept);
  marks.sort();
  return (breaks: sheetBreaks(bottoms.toList()..sort(), view.size.height, marks, room), pieceTops: tops);
}
