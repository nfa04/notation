import 'latex_parser.dart';

/// Propositional logic for the maths check: formulas in `\land \lor \neg \oplus \to \leftrightarrow` (also `∧ ∨ ¬ ⊕ → ↔`, `\overline{p}` and `p'`),
/// compared by their truth tables. Two formulas are equivalent when they agree in every row; one follows from another when no row makes the
/// first true and the second false.
///
/// Binding, strongest first: `¬`, `∧` (`↑`), `⊕`, `∨` (`↓`), `→` (to the right), `↔`.

sealed class Logic {
  const Logic();
}

final class LVar extends Logic {
  final String name;
  const LVar(this.name);
}

final class LConst extends Logic {
  final bool value;
  const LConst(this.value);
}

final class LNot extends Logic {
  final Logic a;
  const LNot(this.a);
}

enum LogicOp { and, or, xor, implies, iff, nand, nor }

final class LBinary extends Logic {
  final LogicOp op;
  final Logic a, b;
  const LBinary(this.op, this.a, this.b);
}

/// How one formula of a line is joined to the next: they are the same (`\equiv`, `\iff`, `=`), or the next follows (`\Rightarrow`).
enum LogicRelation { equivalent, implies }

/// A line of logic: formulas joined by [relations] (one fewer than [formulas]); [lead] is how a line that begins with a relation goes on
/// from the line above (`\equiv \neg p \lor q`).
class LogicLine {
  final List<Logic> formulas;
  final List<LogicRelation> relations;
  final LogicRelation? lead;
  const LogicLine(this.formulas, this.relations, this.lead);
}

/// What shows that a line is about logic and not about numbers. `\top` raised (`A^\top`, the transpose) is not one.
final _strong = RegExp(r'\\(?:land|lor|neg|lnot|oplus|veebar|bot)(?![a-zA-Z])|(?<!\^)(?<!\^\{)\\top(?![a-zA-Z])|[¬∧∨⊕⊤⊥]');

/// What makes `=`, `0` and `1` mean logic: a sign that is only logic (`x = 1 \lor x = 0` is not).
final _certain = RegExp(r'\\(?:neg|lnot|oplus|veebar|bot)(?![a-zA-Z])|(?<!\^)(?<!\^\{)\\top(?![a-zA-Z])|[¬⊕⊤⊥]');

/// `p \to q \equiv \neg p ...` with no sign of its own: a sign for "the same" and an arrow together.
final _sameSign = RegExp(r'\\(?:equiv|iff|Leftrightarrow|leftrightarrow)(?![a-zA-Z])|[⇔↔≡]');
final _arrowSign = RegExp(r'\\(?:to|rightarrow|Rightarrow|implies)(?![a-zA-Z])|[⇒→]');

bool looksLogical(String text) => _strong.hasMatch(text) || _sameSign.hasMatch(text) && _arrowSign.hasMatch(text);

/// [value] of a formula for the truth values in [row].
bool evalLogic(Logic f, Map<String, bool> row) => switch (f) {
      LVar v => row[v.name] ?? false,
      LConst c => c.value,
      LNot n => !evalLogic(n.a, row),
      LBinary b => _apply(b.op, evalLogic(b.a, row), evalLogic(b.b, row)),
    };

bool _apply(LogicOp op, bool a, bool b) => switch (op) {
      LogicOp.and => a && b,
      LogicOp.or => a || b,
      LogicOp.xor => a != b,
      LogicOp.implies => !a || b,
      LogicOp.iff => a == b,
      LogicOp.nand => !(a && b),
      LogicOp.nor => !(a || b),
    };

/// The letters of [fs], in order of appearance.
List<String> logicVariables(Iterable<Logic> fs) {
  final out = <String>[];
  void walk(Logic f) {
    switch (f) {
      case LVar v:
        if (!out.contains(v.name)) out.add(v.name);
      case LConst():
        break;
      case LNot n:
        walk(n.a);
      case LBinary b:
        walk(b.a);
        walk(b.b);
    }
  }

  fs.forEach(walk);
  return out;
}

// ---- reading ----

enum _Kind { atom, constant, not, and, or, xor, nand, nor, implies, iff, open, close, group, prime }

class _Token {
  final _Kind kind;
  final String text;
  final Logic? value;
  const _Token(this.kind, [this.text = '', this.value]);
}

const _greek = {'alpha', 'beta', 'gamma', 'delta', 'varphi', 'phi', 'psi', 'chi', 'theta', 'sigma', 'tau'};

List<_Token>? _tokens(String s, {required bool certain}) {
  final out = <_Token>[];
  var i = 0;
  String? braced(int at) {
    if (at >= s.length) return null;
    if (s[at] != '{') return s[at];
    var depth = 0;
    for (var j = at; j < s.length; j++) {
      if (s[j] == '{') depth++;
      if (s[j] == '}' && --depth == 0) return s.substring(at, j + 1);
    }
    return null;
  }

  while (i < s.length) {
    final c = s[i];
    if (c == ' ') {
      i++;
      continue;
    }
    if (c == '\\') {
      var j = i + 1;
      while (j < s.length && RegExp(r'[a-zA-Z]').hasMatch(s[j])) {
        j++;
      }
      final name = s.substring(i + 1, j);
      i = j;
      switch (name) {
        case 'neg' || 'lnot' || 'sim':
          out.add(const _Token(_Kind.not));
        case 'land' || 'wedge':
          out.add(const _Token(_Kind.and));
        case 'lor' || 'vee':
          out.add(const _Token(_Kind.or));
        case 'oplus' || 'veebar':
          out.add(const _Token(_Kind.xor));
        case 'uparrow':
          out.add(const _Token(_Kind.nand));
        case 'downarrow':
          out.add(const _Token(_Kind.nor));
        case 'to' || 'rightarrow' || 'Rightarrow' || 'implies' || 'longrightarrow' || 'Longrightarrow':
          out.add(const _Token(_Kind.implies));
        case 'iff' || 'leftrightarrow' || 'Leftrightarrow' || 'longleftrightarrow' || 'Longleftrightarrow':
          out.add(const _Token(_Kind.iff, 'sign'));
        case 'equiv':
          out.add(const _Token(_Kind.iff, 'same'));
        case 'top':
          out.add(const _Token(_Kind.constant, '1'));
        case 'bot':
          out.add(const _Token(_Kind.constant, '0'));
        case 'overline' || 'bar':
          // the bar over something is its negation
          while (i < s.length && s[i] == ' ') {
            i++;
          }
          final group = braced(i);
          if (group == null) return null;
          i += group.length;
          final inner = group.startsWith('{') ? group.substring(1, group.length - 1) : group;
          final f = _formulaOf(inner, certain: certain);
          if (f == null) return null;
          out.add(_Token(_Kind.group, '', LNot(f)));
        default:
          if (!_greek.contains(name)) return null;
          out.add(_Token(_Kind.atom, '\\$name'));
      }
      continue;
    }
    i++;
    switch (c) {
      case '(' || '[':
        out.add(const _Token(_Kind.open));
      case ')' || ']':
        out.add(const _Token(_Kind.close));
      case '¬' || '~' || '!':
        out.add(const _Token(_Kind.not));
      case '∧':
        out.add(const _Token(_Kind.and));
      case '∨':
        out.add(const _Token(_Kind.or));
      case '⊕' || '⊻':
        out.add(const _Token(_Kind.xor));
      case '↑':
        out.add(const _Token(_Kind.nand));
      case '↓':
        out.add(const _Token(_Kind.nor));
      case '→' || '⇒' || '⟹' || '⟶':
        out.add(const _Token(_Kind.implies));
      case '↔' || '⇔' || '⟺':
        out.add(const _Token(_Kind.iff, 'sign'));
      case '≡':
        out.add(const _Token(_Kind.iff, 'same'));
      case '⊤':
        out.add(const _Token(_Kind.constant, '1'));
      case '⊥':
        out.add(const _Token(_Kind.constant, '0'));
      case "'":
        out.add(const _Token(_Kind.prime));
      case '=':
        // (`x = a \lor x = b` is a list of solutions: `=` is logic only where something else says so)
        if (!certain) return null;
        out.add(const _Token(_Kind.iff, 'same'));
      case '0' || '1':
        if (!certain) return null;
        out.add(_Token(_Kind.constant, c));
      default:
        if (!RegExp(r'[a-zA-Z]').hasMatch(c)) return null;
        var name = c;
        final sub = RegExp(r'\s*_\s*(?:\{\s*([^{}]*?)\s*\}|([A-Za-z0-9]))').matchAsPrefix(s, i);
        if (sub != null) {
          name = '${c}_{${sub.group(1) ?? sub.group(2)}}';
          i = sub.end;
        }
        out.add(_Token(_Kind.atom, name));
    }
  }
  return out;
}

class _FormulaParser {
  final List<_Token> t;
  int i = 0;
  _FormulaParser(this.t);

  bool get done => i >= t.length;
  _Kind? get peek => done ? null : t[i].kind;

  Logic? iff() {
    var left = implies();
    while (left != null && peek == _Kind.iff) {
      i++;
      final right = implies();
      left = right == null ? null : LBinary(LogicOp.iff, left, right);
    }
    return left;
  }

  Logic? implies() {
    final left = or();
    if (left != null && peek == _Kind.implies) {
      i++;
      final right = implies();
      return right == null ? null : LBinary(LogicOp.implies, left, right);
    }
    return left;
  }

  Logic? or() {
    var left = xor();
    while (left != null && (peek == _Kind.or || peek == _Kind.nor)) {
      final op = peek == _Kind.or ? LogicOp.or : LogicOp.nor;
      i++;
      final right = xor();
      left = right == null ? null : LBinary(op, left, right);
    }
    return left;
  }

  Logic? xor() {
    var left = and();
    while (left != null && peek == _Kind.xor) {
      i++;
      final right = and();
      left = right == null ? null : LBinary(LogicOp.xor, left, right);
    }
    return left;
  }

  Logic? and() {
    var left = unary();
    while (left != null && (peek == _Kind.and || peek == _Kind.nand)) {
      final op = peek == _Kind.and ? LogicOp.and : LogicOp.nand;
      i++;
      final right = unary();
      left = right == null ? null : LBinary(op, left, right);
    }
    return left;
  }

  Logic? unary() {
    if (peek == _Kind.not) {
      i++;
      final a = unary();
      return a == null ? null : LNot(a);
    }
    var a = atom();
    while (a != null && peek == _Kind.prime) {
      i++;
      a = LNot(a);
    }
    return a;
  }

  Logic? atom() {
    if (done) return null;
    final tok = t[i];
    switch (tok.kind) {
      case _Kind.atom:
        i++;
        return LVar(tok.text);
      case _Kind.constant:
        i++;
        return LConst(tok.text == '1');
      case _Kind.group:
        i++;
        return tok.value;
      case _Kind.open:
        i++;
        final inner = iff();
        if (inner == null || peek != _Kind.close) return null;
        i++;
        return inner;
      default:
        return null;
    }
  }
}

Logic? _formulaOf(String text, {required bool certain}) {
  final tokens = _tokens(text, certain: certain);
  if (tokens == null || tokens.isEmpty) return null;
  final p = _FormulaParser(tokens);
  final f = p.iff();
  return f == null || !p.done ? null : f;
}

/// [text] as one formula, arrows and all (`p \to q`, `p \leftrightarrow q`): null when it is not one.
Logic? parseLogicFormula(String text) => _formulaOf(cleanLatex(text), certain: true);

/// [text] (one line of LaTeX, already normalised) as logic; null when it is not.
LogicLine? parseLogicLine(String text) {
  final clean = cleanLatex(text);
  final certain = _certain.hasMatch(clean);
  final tokens = _tokens(clean, certain: certain);
  if (tokens == null || tokens.isEmpty) return null;

  // the signs that stand between formulas: `\equiv` and `=` say "the same" for the line, and then `\leftrightarrow`, `\iff` and the arrows are
  // signs inside the formulas (`p \leftrightarrow q \equiv (p \to q) \land (q \to p)`); without them `\iff` is the sign of the line, and without
  // that an arrow says "so" and splits like the others
  final iffs = _topLevel(tokens, _Kind.iff);
  final hasSame = iffs.any((k) => tokens[k].text == 'same');
  final hasSign = iffs.isNotEmpty;
  bool splits(_Token k) {
    if (k.kind == _Kind.iff) return hasSame ? k.text == 'same' : true;
    return k.kind == _Kind.implies && !hasSign;
  }

  final pieces = <List<_Token>>[[]];
  final relations = <LogicRelation>[];
  var depth = 0;
  for (final k in tokens) {
    if (k.kind == _Kind.open) depth++;
    if (k.kind == _Kind.close) depth--;
    if (depth < 0) return null;
    if (depth == 0 && splits(k)) {
      relations.add(k.kind == _Kind.iff ? LogicRelation.equivalent : LogicRelation.implies);
      pieces.add([]);
    } else {
      pieces.last.add(k);
    }
  }
  if (depth != 0) return null;
  LogicRelation? lead;
  if (pieces.first.isEmpty && relations.isNotEmpty) {
    pieces.removeAt(0);
    lead = relations.removeAt(0);
  }
  if (pieces.isEmpty || pieces.any((p) => p.isEmpty)) return null;
  final formulas = <Logic>[];
  for (final p in pieces) {
    final parser = _FormulaParser(p);
    final f = parser.iff();
    if (f == null || !parser.done) return null;
    formulas.add(f);
  }
  return LogicLine(formulas, relations, lead);
}

List<int> _topLevel(List<_Token> tokens, _Kind kind) {
  final out = <int>[];
  var depth = 0;
  for (var i = 0; i < tokens.length; i++) {
    if (tokens[i].kind == _Kind.open) depth++;
    if (tokens[i].kind == _Kind.close) depth--;
    if (depth == 0 && tokens[i].kind == kind) out.add(i);
  }
  return out;
}
