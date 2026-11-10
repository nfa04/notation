import 'package:highlight/highlight.dart' as hl;

/// A stretch of code with the kind of thing it is (the class of the highlighter: keyword, string, comment, number...), or null.
class CodeToken {
  final String text;
  final String? kind;
  const CodeToken(this.text, this.kind);
}

/// Other names people give a language after the opening fence, for the name the highlighter knows it by.
const _aliases = {
  'shell': 'bash',
  'console': 'bash',
  'terminal': 'bash',
  'tsx': 'typescript',
  'jsonc': 'json',
  'json5': 'json',
  'latex': 'tex',
  'objective-c': 'objectivec',
  'objc': 'objectivec',
  'c#': 'cs',
  'csharp': 'cs',
  'f#': 'fsharp',
  'node': 'javascript',
  'nodejs': 'javascript',
  'python3': 'python',
  'py3': 'python',
  'golang': 'go',
  'rust-lang': 'rust',
  'vb': 'vbnet',
  'plain': 'plaintext',
  'text': 'plaintext',
  'txt': 'plaintext',
  'yml': 'yaml',
  'html5': 'xml',
  'svg': 'xml',
  'jsp': 'java',
  'ps': 'powershell',
  'ps1': 'powershell',
  'kt': 'kotlin',
  'rs': 'rust',
  'rb': 'ruby',
  'cxx': 'cpp',
  'hpp': 'cpp',
  'hh': 'cpp',
  'sol': 'solidity',
};

/// The name of a language as written after the fence (` ```python `, ` ```{.python}`, ` ```Python title="x" `) made into the name the
/// highlighter knows; empty when there is none.
String normalizeLang(String info) {
  var name = info.trim().split(RegExp(r'\s+')).first.toLowerCase();
  name = name.replaceAll(RegExp(r'^[{.]+|[}]+$'), '').replaceAll(RegExp(r'^language-'), '');
  return _aliases[name] ?? name;
}

/// An opening fence of a block of code: three backticks or tildes (or more), then the language and maybe more words.
class FenceOpen {
  final String char;
  final int length;
  final String lang;
  const FenceOpen(this.char, this.length, this.lang);
}

final _fenceOpenRe = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*([^\n]*)$');

/// The fence a line opens, or null. (After backticks the rest may not hold a backtick: that is inline code.)
FenceOpen? matchFenceOpen(String line) {
  final m = _fenceOpenRe.firstMatch(line);
  if (m == null) return null;
  final fence = m.group(1)!, rest = m.group(2)!;
  if (fence.startsWith('`') && rest.contains('`')) return null;
  return FenceOpen(fence[0], fence.length, normalizeLang(rest));
}

/// Whether [line] closes the block [open] opened: the same sort of fence, at least as long, and nothing else on the line.
bool fenceCloses(String line, FenceOpen open) {
  final m = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*$').firstMatch(line);
  return m != null && m.group(1)![0] == open.char && m.group(1)!.length >= open.length;
}

/// The line that ends the block opened at line [open] of [lines]: by the rules, a fence of the same sort at least as long; when there
/// is none, the first fence of the same sort of any length (typing ` ````` ` to open and ` ```` ` to close is a slip, not a block
/// that never ends). Null when the block is never closed.
int? findFenceEnd(List<String> lines, int open, FenceOpen fence) {
  for (var k = open + 1; k < lines.length; k++) {
    if (fenceCloses(lines[k], fence)) return k;
  }
  final loose = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*$');
  for (var k = open + 1; k < lines.length; k++) {
    final m = loose.firstMatch(lines[k]);
    if (m != null && m.group(1)![0] == fence.char) return k;
  }
  return null;
}

/// A block of code in a text: the characters from the opening fence to the end of the closing one ([start], [end]), the code itself
/// ([bodyStart], [bodyEnd]) and the language.
class CodeBlockSpan {
  final int start, end, bodyStart, bodyEnd;
  final String lang;
  const CodeBlockSpan(this.start, this.end, this.bodyStart, this.bodyEnd, this.lang);
}

/// The blocks of code in [text] (a block that is never closed is not one).
List<CodeBlockSpan> codeBlockSpans(String text) {
  final out = <CodeBlockSpan>[];
  if (!text.contains('```') && !text.contains('~~~')) return out;
  final lines = text.split('\n');
  final starts = <int>[];
  var at = 0;
  for (final l in lines) {
    starts.add(at);
    at += l.length + 1;
  }
  for (var n = 0; n < lines.length; n++) {
    final open = matchFenceOpen(lines[n]);
    if (open == null) continue;
    final end = findFenceEnd(lines, n, open);
    if (end == null) continue;
    final bodyStart = n + 1 < lines.length ? starts[n + 1] : text.length;
    final bodyEnd = end > n + 1 ? starts[end] - 1 : bodyStart;
    out.add(CodeBlockSpan(starts[n], starts[end] + lines[end].length, bodyStart, bodyEnd < bodyStart ? bodyStart : bodyEnd, open.lang));
    n = end;
  }
  return out;
}

/// The languages a block with no language named is tried as, the likeliest first (a tie goes to the first).
const _candidates = ['javascript', 'typescript', 'python', 'java', 'cpp', 'c', 'cs', 'go', 'rust', 'ruby', 'php', 'bash', 'sql', 'json', 'xml', 'css', 'dart', 'kotlin', 'swift', 'yaml'];

/// What language a block with none named is, when it clearly is code: it has the marks of code (brackets, semicolons, equal signs) and one
/// of the common languages reads it well. Null for text, and for what cannot be told.
String? detectLanguage(String code) {
  final marks = {for (final c in code.split('')) if ('(){};=[]<>'.contains(c)) c};
  if (code.trim().length < 6 || marks.length < 2) return null;
  String? best;
  var bestScore = 1;
  for (final name in _candidates) {
    try {
      final score = hl.highlight.parse(code, language: name).relevance ?? 0;
      if (score > bestScore) {
        best = name;
        bestScore = score;
      }
    } catch (_) {
      continue;
    }
  }
  return best;
}

/// The code split into tokens for the language [lang] (a name or alias like `dart`, `py`, `js`, `c++`); one token with no kind
/// when the language is not known or there is none.
List<CodeToken> highlightCode(String code, String? lang) {
  var name = lang == null ? null : _aliases[lang.trim().toLowerCase()] ?? lang.trim().toLowerCase();
  if (name == null || name.isEmpty) name = detectLanguage(code);
  if (name == null) return [CodeToken(code, null)];
  try {
    final out = <CodeToken>[];
    void walk(List<hl.Node> nodes, String? kind) {
      for (final n in nodes) {
        final k = n.className ?? kind;
        if (n.value != null) {
          if (out.isNotEmpty && out.last.kind == k) {
            out[out.length - 1] = CodeToken(out.last.text + n.value!, k);
          } else {
            out.add(CodeToken(n.value!, k));
          }
        }
        if (n.children != null) walk(n.children!, k);
      }
    }

    walk(hl.highlight.parse(code, language: name).nodes ?? const [], null);
    return out.isEmpty ? [CodeToken(code, null)] : out;
  } catch (_) {
    return [CodeToken(code, null)];
  }
}

/// The colour (ARGB) for a token kind on a light or a dark background; null for plain code.
int? codeColor(String? kind, {required bool dark}) {
  if (kind == null) return null;
  int pick(int light, int darkColor) => dark ? darkColor : light;
  switch (kind) {
    case 'keyword':
    case 'selector-tag':
    case 'doctag':
      return pick(0xFF8250DF, 0xFFD2A8FF);
    case 'built_in':
    case 'type':
    case 'class':
    case 'title':
    case 'section':
    case 'function':
      return pick(0xFF0A69DA, 0xFF79C0FF);
    case 'string':
    case 'regexp':
    case 'template-variable':
    case 'symbol':
      return pick(0xFF0A7D3E, 0xFFA5D6A7);
    case 'number':
    case 'literal':
    case 'bullet':
      return pick(0xFFB35900, 0xFFFFB86C);
    case 'comment':
    case 'quote':
      return pick(0xFF6E7781, 0xFF8B949E);
    case 'meta':
    case 'meta-keyword':
    case 'attr':
    case 'attribute':
    case 'variable':
    case 'params':
      return pick(0xFFC2185B, 0xFFFF9CAC);
    default:
      return null;
  }
}
