import 'package:flutter/widgets.dart' show TextEditingValue, TextSelection;

import 'calculator.dart';
import 'latex_parser.dart' show looksLikeEquation;

/// The equation in some Markdown text that "Solve" should work on, and where
/// the answer goes (the end of the line holding it).
typedef EquationTarget = ({String latex, int insertAt});

final _math = RegExp(r'\$\$(.+?)\$\$|\$(.+?)\$', dotAll: true);

/// Picks the selected text if there is a selection, else the formula under the
/// cursor, else the first formula that is an equation, else the cursor's line.
EquationTarget? equationTarget(TextEditingValue value) {
  final text = value.text;
  final sel = value.selection;
  int lineEnd(int from) {
    final n = text.indexOf('\n', from);
    return n < 0 ? text.length : n;
  }

  if (sel.isValid && !sel.isCollapsed) {
    final picked = text.substring(sel.start, sel.end).replaceAll(r'$', '').trim();
    return picked.isEmpty ? null : (latex: picked, insertAt: lineEnd(sel.end));
  }
  final runs = _math.allMatches(text).toList();
  final cursor = sel.isValid ? sel.baseOffset : 0;
  for (final m in runs) {
    if (cursor >= m.start && cursor <= m.end) return (latex: m.group(1) ?? m.group(2)!, insertAt: lineEnd(m.end));
  }
  for (final wantEquation in [true, false]) {
    for (final m in runs) {
      final latex = m.group(1) ?? m.group(2)!;
      if ((!wantEquation || looksLikeEquation(latex)) && canCalculate(latex)) {
        return (latex: latex, insertAt: lineEnd(m.end));
      }
    }
  }
  if (text.isEmpty) return null;
  final at = cursor.clamp(0, text.length);
  final start = text.lastIndexOf('\n', at == 0 ? 0 : at - 1) + 1;
  final end = lineEnd(at);
  final line = text.substring(start, end).trim();
  return line.isEmpty ? null : (latex: line, insertAt: end);
}

/// [value] with the answer `$latex$` added in a paragraph after [target].
TextEditingValue withSolution(TextEditingValue value, EquationTarget target, String latex) {
  final insert = '\n\n\$$latex\$';
  final text = value.text.replaceRange(target.insertAt, target.insertAt, insert);
  return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: target.insertAt + insert.length));
}
