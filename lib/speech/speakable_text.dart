/// Turns the text of a note into what is worth hearing: the footnote marks, citations, links, formulas, Markdown signs and
/// page numbers a reader's eye skips over are taken out, because a voice would read every one of them aloud.
String speakableText(String text) {
  var t = text.replaceAll('\r\n', '\n');

  // the written document's own marks: how a paragraph is laid out, the settings of its pages, the contents and page breaks,
  // tracked changes (read as accepted), comments, and the names and references of headings and captions
  t = t.replaceAll(RegExp(r'^\{(?:align|indent|spacing)=[^}\n]*\}', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\[(?:header|footer|columns|style-[a-z0-9]+)\]:.*$', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*(?:\[toc\]|\\pagebreak|\\newpage)\s*$', multiLine: true, caseSensitive: false), '');
  t = t.replaceAllMapped(RegExp(r'\{\+\+(.*?)\+\+\}'), (m) => m[1]!).replaceAll(RegExp(r'\{--.*?--\}'), '');
  t = t.replaceAll(RegExp(r'\{>>.*?<<\}'), '').replaceAllMapped(RegExp(r'\{==(.*?)==\}'), (m) => m[1]!);
  t = t.replaceAll(RegExp(r'\s?\{[#@][\w:.\-]+\}'), '');

  // a list of references at the end is not read (only when it comes after some text of its own)
  final refs = RegExp(r'^\s*#{0,6}\s*(references|bibliography|sources|works cited|literature|literatur|literaturverzeichnis|quellen|quellenverzeichnis)\s*:?\s*$',
      caseSensitive: false, multiLine: true);
  final cut = refs.firstMatch(t);
  if (cut != null && cut.start > 200) t = t.substring(0, cut.start);

  // code blocks and formulas cannot be spoken
  t = t.replaceAll(RegExp(r'```[\s\S]*?```'), '\n');
  t = t.replaceAll(RegExp(r'\$\$[\s\S]*?\$\$'), ' ');
  t = t.replaceAll(RegExp(r'\\\[[\s\S]*?\\\]'), ' ');
  t = t.replaceAll(RegExp(r'\\\([\s\S]*?\\\)'), ' ');
  t = t.replaceAll(RegExp(r'\$[^$\n]{1,200}\$'), ' ');

  // whole lines
  final lines = <String>[];
  for (var line in t.split('\n')) {
    final s = line.trim();
    if (s.isEmpty) {
      lines.add('');
      continue;
    }
    if (RegExp(r'^\[\^?[\w-]{1,6}\]:?\s').hasMatch(s) && !s.startsWith('[ ]') && !s.startsWith('[x]')) continue; // a footnote text: "[1] Smith, 2020."
    if (RegExp(r'^\^?\d{1,3}[:.)]\s').hasMatch(s) && s.startsWith('^')) continue; // "^1: text"
    if (RegExp(r'^[*†‡§¹²³⁴⁵⁶⁷⁸⁹⁰]+\s*\S').hasMatch(s) && RegExp(r'^[*†‡§]').hasMatch(s) && s.length < 200 && !s.startsWith('* ') && !s.startsWith('*')) continue; // "† note"
    if (RegExp(r'^[\s\-–—_=*·.]{3,}$').hasMatch(s)) continue; // rules
    if (RegExp(r'^(page|seite|p\.|s\.)?\s*\d{1,4}(\s*(/|of|von)\s*\d{1,4})?$', caseSensitive: false).hasMatch(s)) continue; // page numbers
    if (RegExp(r'^(https?://|www\.)\S+$').hasMatch(s)) continue;
    // Markdown signs at the start: headings, quotes, list marks, tick boxes
    line = s.replaceFirst(RegExp(r'^(#{1,6}\s+|>\s*|[-*+•]\s+(\[[ xX]\]\s+)?)'), '');
    lines.add(line);
  }
  t = lines.join('\n');

  // inline
  t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' '); // pictures
  t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!); // a link says its words, not its address
  t = t.replaceAll(RegExp(r'(https?://|www\.)\S+'), ' ');
  t = t.replaceAll(RegExp(r'<[^>\n]{1,80}>'), ' ');
  t = t.replaceAllMapped(RegExp(r'(\*\*|__|\*|_|~~|`)(?=\S)([^*_~`\n]+?)(?<=\S)\1'), (m) => m[2]!);
  // footnote marks: [1], [1, 2], [3-5], [a], [^1], superscripts, ^1, ^{12}, and a star or dagger after a word
  t = t.replaceAll(RegExp(r'\s?\[\^?(\d{1,3}|[a-z])([,;–\-\s]+\d{1,3})*\]'), '');
  t = t.replaceAll(RegExp(r'[⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁽⁾]+'), '');
  t = t.replaceAll(RegExp(r'\^\{[^}]{1,6}\}|\^\d{1,3}'), '');
  t = t.replaceAll(RegExp(r'(?<=[A-Za-zÄÖÜäöüß.,;:!?)])[*†‡§]+(?=\s|$)'), '');
  // citations in brackets: (Smith, 2020), (Smith et al., 2019; Jones 2020), (Müller & Co 1999, p. 4)
  t = t.replaceAll(RegExp(r'\s?\((?:[A-ZÄÖÜ][\p{L}\-]+(?:\s+(?:et al\.?|&|and|und)\s*[\p{L}\-]*)?,?\s+\d{4}[a-z]?(?:,\s*(?:pp?\.|S\.)\s*[\d\-–]+)?(?:;\s*)?)+\)', unicode: true), '');
  // a word split at the end of a line
  t = t.replaceAllMapped(RegExp(r'(\p{L})-\n(\p{Ll})', unicode: true), (m) => '${m[1]}${m[2]}');

  // tidy up
  t = t.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r' ?\n ?'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
  t = t.replaceAll(RegExp(r'\s+([,.;:!?])'), r'$1');
  return t.trim();
}
