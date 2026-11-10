/// Units written after numbers (`9.81 m/s^2`, `0.5\,\mathrm{kg}`, `4.81 N`): what they are worth in SI units, and what they are
/// made of, so that the checker can work with the numbers (a length of 5 cm is 0.05 m) and tell when the units do not fit.
///
/// A letter after a number is only read as a unit when that is likely: `0.5 m v^2` is a mass times a speed squared, `0.5 m + 3 m` and
/// `0.5 kg \cdot 3 m` are lengths. The rules are in [readUnits].
library;

/// The exponents of the SI base units that matter here, in this order: kg, m, s, A, K, mol.
const unitBases = ['kg', 'm', 's', 'A', 'K', 'mol'];

/// A quantity's unit: a power of ten to multiply a number written in it by to get the SI unit, and the exponents of the base units.
class UnitValue {
  final int e10;
  final List<int> dim;
  const UnitValue(this.e10, this.dim);

  static const one = UnitValue(0, [0, 0, 0, 0, 0, 0]);

  UnitValue operator *(UnitValue o) => UnitValue(e10 + o.e10, [for (var i = 0; i < 6; i++) dim[i] + o.dim[i]]);
  UnitValue operator /(UnitValue o) => UnitValue(e10 - o.e10, [for (var i = 0; i < 6; i++) dim[i] - o.dim[i]]);
  UnitValue power(int n) => UnitValue(e10 * n, [for (final d in dim) d * n]);
}

const _coherent = <String, UnitValue>{
  'm': UnitValue(0, [0, 1, 0, 0, 0, 0]),
  'g': UnitValue(-3, [1, 0, 0, 0, 0, 0]),
  's': UnitValue(0, [0, 0, 1, 0, 0, 0]),
  'A': UnitValue(0, [0, 0, 0, 1, 0, 0]),
  'K': UnitValue(0, [0, 0, 0, 0, 1, 0]),
  'mol': UnitValue(0, [0, 0, 0, 0, 0, 1]),
  'N': UnitValue(0, [1, 1, -2, 0, 0, 0]),
  'J': UnitValue(0, [1, 2, -2, 0, 0, 0]),
  'W': UnitValue(0, [1, 2, -3, 0, 0, 0]),
  'Pa': UnitValue(0, [1, -1, -2, 0, 0, 0]),
  'Hz': UnitValue(0, [0, 0, -1, 0, 0, 0]),
  'V': UnitValue(0, [1, 2, -3, -1, 0, 0]),
  'C': UnitValue(0, [0, 0, 1, 1, 0, 0]),
};

const _prefixes = <String, int>{'n': -9, 'µ': -6, 'm': -3, 'c': -2, 'd': -1, 'h': 2, 'k': 3, 'M': 6, 'G': 9};

/// Every unit symbol that is read: the SI units with a prefix or none (`kg`, `mm`, `kPa`, `µs`). The centi and the deci only go with the metre
/// and the hecto with the pascal; the kelvin takes none.
final Map<String, UnitValue> _symbols = () {
  final out = <String, UnitValue>{};
  _coherent.forEach((name, u) {
    out[name] = u;
    if (name == 'K') return;
    _prefixes.forEach((p, e) {
      final allowed = switch (p) {
        'c' || 'd' => name == 'm',
        'h' => name == 'Pa',
        _ => true,
      };
      if (allowed) out['$p$name'] = UnitValue(u.e10 + e, u.dim);
    });
  });
  return out;
}();

/// The units that can hardly be anything else after a number: a letter or two that are not likely to be quantities of the
/// problem. (`m`, `s`, `g`, `N`, `A`, `ms`, `dm` can be a mass, a distance, a gravity, an amount.)
bool _isStrong(String token) =>
    token.contains('µ') ||
    token == 'mol' ||
    const {'kg', 'mg', 'cm', 'mm', 'km', 'nm', 'kN', 'mN', 'kJ', 'MJ', 'kW', 'MW', 'kV', 'mV', 'mA'}.contains(token) ||
    token.endsWith('Pa') ||
    token.endsWith('Hz');

/// The result of [readUnits].
class UnitReading {
  /// The text with each `number unit` written as the number in SI units: `5 cm` is `5 \cdot 10^{-2}`, `9.81 m/s^2` is `9.81`.
  final String clean;

  /// The text with each unit written as a product of formal variables ([unitVariable]), to work out what the units of an expression are.
  final String dims;

  const UnitReading(this.clean, this.dims);
}

/// The name of the variable that stands for the base unit with the index [i] in [UnitReading.dims].
String unitVariable(int i) => 'Q_{u$i}';

/// Whether [name] (as `freeVariables` names it) is one of those.
bool isUnitVariable(String name) => RegExp(r'^Q_\{u[0-5]\}$').hasMatch(name);

/// The index of the unit variable [name], or -1.
int unitIndex(String name) => isUnitVariable(name) ? int.parse(name[4]) : -1;

final _number = RegExp(r'(?<![\w.^_\\])\d+(?:\.\d+)?(?:\^\{-?\d+\})?(?:\s*(?:\\cdot|\\times)\s*10\^\{-?\d+\})?');

/// [text] with units read, or null when there are none to be read.
///
/// A unit is what follows a number (`3`, `0.25`, `3 \cdot 10^{8}`): `kg`, `m/s^2`, `\frac{m}{s^2}`, `kg\,m/s^2`, `\mathrm{N}`, `N \cdot m`.
/// What is only one or two letters that could be a quantity (`m`, `s`, `g`, `N`, `ms`) counts only when something in the same text shows that
/// it is about units: another unit that is hardly anything else (`kg`, `cm`, `Pa`, `µs`) or a quotient of units (`m/s`); and a letter that
/// is followed by another letter or a function (`0.5 m v^2`, `2 m \sqrt{x}`) is a product of quantities and not read.
UnitReading? readUnits(String text) {
  final found = <({int start, int end, UnitValue unit, bool strong, int numberEnd})>[];
  for (final m in _number.allMatches(text)) {
    final cur = _Cursor(text, m.end);
    cur.skipSpace();
    final r = _product(cur);
    if (r == null) continue;
    // (a letter that goes on after the unit makes it a product of quantities)
    final after = _Cursor(text, cur.i)..skipSpace();
    final weakOnly = !r.strong;
    if (weakOnly && !_boundary(text, after.i)) continue;
    // (a number that is itself the end of the last unit's exponent was taken by that unit)
    if (found.isNotEmpty && m.start < found.last.end) continue;
    found.add((start: m.start, end: cur.i, unit: r.unit, strong: r.strong, numberEnd: m.end));
  }
  if (!found.any((f) => f.strong)) return null;
  final clean = StringBuffer(), dims = StringBuffer();
  var at = 0;
  for (final f in found) {
    clean.write(text.substring(at, f.start));
    dims.write(text.substring(at, f.start));
    final number = text.substring(f.start, f.numberEnd);
    clean.write(f.unit.e10 == 0 ? number : '$number \\cdot 10^{${f.unit.e10}}');
    dims.write('($number');
    for (var i = 0; i < 6; i++) {
      if (f.unit.dim[i] != 0) dims.write(' \\cdot ${unitVariable(i)}^{${f.unit.dim[i]}}');
    }
    dims.write(')');
    at = f.end;
  }
  clean.write(text.substring(at));
  dims.write(text.substring(at));
  return UnitReading(clean.toString(), dims.toString());
}

/// Whether what stands at [i] ends a quantity: the end, a closing bracket, an operator or a relation (not a letter, a digit, a function).
bool _boundary(String s, int i) {
  if (i >= s.length) return true;
  final c = s[i];
  if (')}]=+-,;&|<>*/'.contains(c)) return true;
  if (c != r'\') return false;
  return RegExp(r'\\(?:cdot|times|div|approx|simeq|pm|mp|Rightarrow|rightarrow|Longrightarrow|to|quad|qquad|right|le|ge|leq|geq|neq|ne|equiv|text|mathrm)(?![a-zA-Z])|\\[,;:! ]').matchAsPrefix(s, i) != null;
}

class _Cursor {
  final String s;
  int i;
  _Cursor(this.s, this.i);

  bool get done => i >= s.length;

  void skipSpace() {
    while (i < s.length) {
      if (s[i] == ' ' || s[i] == '~') {
        i++;
      } else if (s.startsWith(r'\,', i) || s.startsWith(r'\;', i) || s.startsWith(r'\:', i) || s.startsWith(r'\!', i) || s.startsWith(r'\ ', i)) {
        i += 2;
      } else {
        break;
      }
    }
  }

  bool eat(String t) {
    if (!s.startsWith(t, i)) return false;
    if (t.startsWith(r'\') && i + t.length < s.length && RegExp(r'[A-Za-z]').hasMatch(s[i + t.length])) return false;
    i += t.length;
    return true;
  }
}

typedef _Read = ({UnitValue unit, bool strong});

/// `kg`, `m/s^2`, `kg m / s^2`, `N \cdot m`, `J/(kg K)`: the unit that [c] is at, or null when it is not one (the cursor is then
/// anywhere).
_Read? _product(_Cursor c) {
  final first = _term(c);
  if (first == null) return null;
  var q = first;
  while (true) {
    final save = c.i;
    c.skipSpace();
    final spaced = c.i > save;
    if (c.eat('/')) {
      c.skipSpace();
      final t = _term(c);
      if (t == null) {
        c.i = save;
        break;
      }
      q = (unit: q.unit / t.unit, strong: true);
      continue;
    }
    if (c.eat(r'\cdot')) {
      c.skipSpace();
      final t = _term(c);
      if (t == null) {
        c.i = save;
        break;
      }
      q = (unit: q.unit * t.unit, strong: q.strong || t.strong);
      continue;
    }
    if (spaced) {
      final t = _term(c);
      if (t != null) {
        q = (unit: q.unit * t.unit, strong: q.strong || t.strong);
        continue;
      }
    }
    c.i = save;
    break;
  }
  return q;
}

_Read? _term(_Cursor c) {
  _Read? base;
  if (c.eat('(')) {
    c.skipSpace();
    final inner = _product(c);
    c.skipSpace();
    if (inner == null || !c.eat(')')) return null;
    base = inner;
  } else if (c.eat(r'\frac')) {
    final top = _braced(c), bottom = _braced(c);
    if (top == null || bottom == null) return null;
    base = (unit: top.unit / bottom.unit, strong: true);
  } else if (c.eat(r'\mathrm') || c.eat(r'\text') || c.eat(r'\textrm')) {
    final inner = _braced(c);
    if (inner == null) return null;
    base = inner;
  } else {
    final m = RegExp(r'[A-Za-zµ]+').matchAsPrefix(c.s, c.i);
    if (m == null) return null;
    final u = _symbols[m.group(0)!];
    if (u == null) return null;
    c.i = m.end;
    base = (unit: u, strong: _isStrong(m.group(0)!));
  }
  final power = RegExp(r'\^\s*(?:\{\s*(-?\d+)\s*\}|(-?\d))').matchAsPrefix(c.s, c.i);
  if (power != null) {
    final n = int.parse(power.group(1) ?? power.group(2)!);
    if (n.abs() > 6) return null;
    c.i = power.end;
    base = (unit: base.unit.power(n), strong: base.strong);
  }
  return base;
}

/// `{ ... }` holding a unit.
_Read? _braced(_Cursor c) {
  c.skipSpace();
  if (!c.eat('{')) return null;
  final inner = _product(c);
  c.skipSpace();
  if (inner == null || !c.eat('}')) return null;
  return inner;
}

/// The units of [dim] as LaTeX: `\mathrm{N}` for a force, `\mathrm{kg\,m^2/s^3}` for what has no name here; empty for a pure number.
String unitTex(List<int> dim) {
  const named = <String, List<int>>{
    'N': [1, 1, -2, 0, 0, 0],
    'J': [1, 2, -2, 0, 0, 0],
    'W': [1, 2, -3, 0, 0, 0],
    'Pa': [1, -1, -2, 0, 0, 0],
    'Hz': [0, 0, -1, 0, 0, 0],
    'V': [1, 2, -3, -1, 0, 0],
    'C': [0, 0, 1, 1, 0, 0],
  };
  for (final e in named.entries) {
    if (_same(e.value, dim)) return '\\mathrm{${e.key}}';
  }
  String power(String name, int n) => n == 1 ? name : '$name^{$n}';
  final top = [for (var i = 0; i < 6; i++) if (dim[i] > 0) power(unitBases[i], dim[i])];
  final bottom = [for (var i = 0; i < 6; i++) if (dim[i] < 0) power(unitBases[i], -dim[i])];
  if (top.isEmpty && bottom.isEmpty) return '1';
  final up = top.isEmpty ? '1' : top.join(r'\,');
  return '\\mathrm{$up${bottom.isEmpty ? '' : '/${bottom.length > 1 ? '(${bottom.join(r'\,')})' : bottom.single}'}}';
}

bool _same(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
