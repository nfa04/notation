/// What a model writes, made into the Markdown the app draws: models write formulas as `\( x \)` and `\[ x \]` as often as with
/// dollars, and a displayed formula over several lines, where the app wants `$x$` and a `$$x$$` line of its own.
String chatMarkdown(String text) {
  var out = text.replaceAll('\r\n', '\n');
  String oneLine(String tex) => tex.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
  // displayed: \[ ... \] and $$ ... $$ over lines, each on a line of its own
  out = out.replaceAllMapped(RegExp(r'\\\[([\s\S]+?)\\\]'), (m) => '\n\$\$${oneLine(m[1]!)}\$\$\n');
  out = out.replaceAllMapped(RegExp(r'\$\$([\s\S]+?)\$\$'), (m) {
    final tex = oneLine(m[1]!);
    // (one that stands in a sentence stays there)
    final before = out.substring(0, m.start), after = out.substring(m.end);
    final alone = (before.isEmpty || before.endsWith('\n')) && (after.isEmpty || after.startsWith('\n'));
    return alone || m[1]!.contains('\n') ? '\n\$\$$tex\$\$\n' : '\$\$$tex\$\$';
  });
  // in the line: \( ... \)
  out = out.replaceAllMapped(RegExp(r'\\\((.+?)\\\)', dotAll: true), (m) => '\$${oneLine(m[1]!)}\$');
  // (the lines added around a displayed formula are not doubled, and the text does not start or end with them)
  return out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
