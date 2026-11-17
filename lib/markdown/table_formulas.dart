/// Formulas in the cells of a Markdown table. A cell that starts with `=` is worked out from the other cells: `=B2*C2`,
/// `=SUM(B2:B9)`, `=ROUND(AVERAGE(B2:B9), 1)`. The cell keeps the formula as its text (so the file, sync and other programs
/// still see plain Markdown); the app shows the result in its place.
///
/// Cells are named as in a spreadsheet: the letter is the column (A, B, ... Z, AA), the number is the row, and **the head is
/// row 1**, so the first row under it is row 2. Functions: SUM, AVERAGE (AVG), MIN, MAX, COUNT, ROUND; arguments are separated by
/// `,` or `;`. A cell's own number may use a comma as the decimal sign (`3,5`), a number inside a formula is written with a point.
/// In a range, cells that are not numbers are left out, as in a spreadsheet.
library;

/// Whether [cell] is a formula.
bool isFormula(String cell) => cell.trimLeft().startsWith('=');

/// The name of column [index] (zero-based): A, B, ... Z, AA, AB, ...
String columnName(int index) {
  var n = index + 1;
  final out = StringBuffer();
  final letters = <String>[];
  while (n > 0) {
    n--;
    letters.add(String.fromCharCode(65 + n % 26));
    n ~/= 26;
  }
  for (final l in letters.reversed) {
    out.write(l);
  }
  return out.toString();
}

/// The number a cell's text says, or null if it is not a plain number. `1 234,5`, `3,5` and `12.50` are numbers; `1,234.5` too.
double? parseCellNumber(String text) {
  var s = text.trim().replaceAll(RegExp(r'[\s   ]'), '').replaceAll("'", '');
  if (s.isEmpty) return null;
  if (s.contains(',') && s.contains('.')) {
    // the last of the two is the decimal sign
    s = s.lastIndexOf(',') > s.lastIndexOf('.') ? s.replaceAll('.', '').replaceAll(',', '.') : s.replaceAll(',', '');
  } else if (s.contains(',')) {
    s = '.'.allMatches(s).isEmpty && ','.allMatches(s).length == 1 ? s.replaceAll(',', '.') : s.replaceAll(',', '');
  }
  if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$').hasMatch(s)) return null;
  final v = double.tryParse(s);
  return v == null || v.isNaN || v.isInfinite ? null : v;
}

/// A number as a cell shows it: whole numbers without a point, others with at most ten significant digits.
String formatCellNumber(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  final s = double.parse(v.toStringAsPrecision(10));
  var t = s.abs() >= 1e-4 && s.abs() < 1e15 ? s.toString() : s.toStringAsPrecision(6);
  if (t.contains('e')) return t.replaceFirst(RegExp(r'\.?0+e'), 'e');
  if (t.contains('.')) t = t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return t;
}

class _FormulaError implements Exception {
  final String shows;
  const _FormulaError(this.shows);
}

/// The cells of one table ([raw] has the head as its first row), worked out on demand.
class TableSheet {
  final List<List<String>> raw;
  final Map<int, double?> _done = {};
  final Set<int> _busy = {};

  TableSheet(this.raw);

  int get _width => raw.fold(0, (w, r) => r.length > w ? r.length : w);

  /// What the cell at [row], [column] (zero-based) shows: the result of a formula, an error mark (`#ERR`, `#REF!`, `#DIV/0!`,
  /// `#LOOP!`), or the text as it is.
  String display(int row, int column) {
    final text = row < raw.length && column < raw[row].length ? raw[row][column] : '';
    if (!isFormula(text)) return text;
    try {
      final v = _numberAt(row, column);
      return v == null ? '' : formatCellNumber(v);
    } on _FormulaError catch (e) {
      return e.shows;
    }
  }

  double? _numberAt(int row, int column) {
    final key = row * 100000 + column;
    if (_errors.containsKey(key)) throw _FormulaError(_errors[key]!);
    if (_done.containsKey(key)) return _done[key];
    final text = raw[row][column];
    if (!isFormula(text)) return parseCellNumber(text);
    if (!_busy.add(key)) throw const _FormulaError('#LOOP!');
    try {
      final v = _Evaluator(this, text.trimLeft().substring(1)).run();
      _done[key] = v;
      return v;
    } on _FormulaError catch (e) {
      // (an error is remembered as an error: the cells that use this one show it too)
      _done[key] = null;
      _errors[key] = e.shows;
      rethrow;
    } finally {
      _busy.remove(key);
    }
  }

  final Map<int, String> _errors = {};

  /// The number in a cell used by a formula: an empty cell is 0, text is an error.
  double _scalar(int row, int column) {
    if (row < 0 || row >= raw.length || column < 0 || column >= _width) throw const _FormulaError('#REF!');
    final key = row * 100000 + column;
    final text = column < raw[row].length ? raw[row][column] : '';
    if (text.trim().isEmpty) return 0;
    final v = _numberAt(row, column);
    if (v == null) throw _FormulaError(_errors[key] ?? '#ERR');
    return v;
  }

  /// The numbers in a range (cells that are not numbers are left out; an error in one of them is the error of the range).
  List<double> _range(int r1, int c1, int r2, int c2) {
    if (r1 > r2) (r1, r2) = (r2, r1);
    if (c1 > c2) (c1, c2) = (c2, c1);
    if (r1 < 0 || c1 < 0 || r2 >= raw.length || c2 >= _width) throw const _FormulaError('#REF!');
    final out = <double>[];
    for (var r = r1; r <= r2; r++) {
      for (var c = c1; c <= c2; c++) {
        final text = c < raw[r].length ? raw[r][c] : '';
        if (text.trim().isEmpty) continue;
        if (isFormula(text)) {
          final v = _numberAt(r, c);
          if (v != null) out.add(v);
        } else {
          final v = parseCellNumber(text);
          if (v != null) out.add(v);
        }
      }
    }
    return out;
  }
}

enum _T { number, name, op, open, close, comma, colon, end }

class _Tok {
  final _T kind;
  final String text;
  const _Tok(this.kind, this.text);
}

class _Evaluator {
  final TableSheet sheet;
  final String source;
  late final List<_Tok> _tokens = _lex();
  int _at = 0;

  _Evaluator(this.sheet, this.source);

  List<_Tok> _lex() {
    final out = <_Tok>[];
    final re = RegExp(r'\s*(?:(\d+\.?\d*|\.\d+)|([A-Za-z_][A-Za-z_0-9]*)|([-+*/])|(\()|(\))|([,;])|(:))');
    var i = 0;
    while (i < source.length) {
      if (source.substring(i).trim().isEmpty) break;
      final m = re.matchAsPrefix(source, i);
      if (m == null || m.end == i) throw const _FormulaError('#ERR');
      if (m.group(1) != null) {
        out.add(_Tok(_T.number, m.group(1)!));
      } else if (m.group(2) != null) {
        out.add(_Tok(_T.name, m.group(2)!.toUpperCase()));
      } else if (m.group(3) != null) {
        out.add(_Tok(_T.op, m.group(3)!));
      } else if (m.group(4) != null) {
        out.add(const _Tok(_T.open, '('));
      } else if (m.group(5) != null) {
        out.add(const _Tok(_T.close, ')'));
      } else if (m.group(6) != null) {
        out.add(const _Tok(_T.comma, ','));
      } else {
        out.add(const _Tok(_T.colon, ':'));
      }
      i = m.end;
    }
    out.add(const _Tok(_T.end, ''));
    return out;
  }

  _Tok get _peek => _tokens[_at];

  double run() {
    final v = _sum();
    if (_peek.kind != _T.end) throw const _FormulaError('#ERR');
    if (v.isNaN || v.isInfinite) throw const _FormulaError('#ERR');
    return v;
  }

  double _sum() {
    var v = _product();
    while (_peek.kind == _T.op && (_peek.text == '+' || _peek.text == '-')) {
      final plus = _tokens[_at++].text == '+';
      final r = _product();
      v = plus ? v + r : v - r;
    }
    return v;
  }

  double _product() {
    var v = _unary();
    while (_peek.kind == _T.op && (_peek.text == '*' || _peek.text == '/')) {
      final times = _tokens[_at++].text == '*';
      final r = _unary();
      if (!times && r == 0) throw const _FormulaError('#DIV/0!');
      v = times ? v * r : v / r;
    }
    return v;
  }

  double _unary() {
    if (_peek.kind == _T.op && _peek.text == '-') {
      _at++;
      return -_unary();
    }
    if (_peek.kind == _T.op && _peek.text == '+') {
      _at++;
      return _unary();
    }
    return _primary();
  }

  static final _cell = RegExp(r'^([A-Z]{1,3})(\d{1,5})$');

  (int row, int column)? _ref(String name) {
    final m = _cell.firstMatch(name);
    if (m == null) return null;
    var column = 0;
    for (final ch in m.group(1)!.codeUnits) {
      column = column * 26 + (ch - 64);
    }
    return (int.parse(m.group(2)!) - 1, column - 1);
  }

  double _primary() {
    final t = _tokens[_at];
    switch (t.kind) {
      case _T.number:
        _at++;
        return parseCellNumber(t.text) ?? (throw const _FormulaError('#ERR'));
      case _T.open:
        _at++;
        final v = _sum();
        if (_peek.kind != _T.close) throw const _FormulaError('#ERR');
        _at++;
        return v;
      case _T.name:
        _at++;
        if (_peek.kind == _T.open) return _call(t.text);
        final ref = _ref(t.text);
        if (ref == null) throw const _FormulaError('#ERR');
        if (_peek.kind == _T.colon) throw const _FormulaError('#ERR'); // a range is for a function
        return sheet._scalar(ref.$1, ref.$2);
      default:
        throw const _FormulaError('#ERR');
    }
  }

  /// The numbers an argument stands for: a range, or one value.
  List<double> _argument() {
    if (_peek.kind == _T.name && _tokens[_at + 1].kind == _T.colon) {
      final a = _ref(_tokens[_at].text);
      final b = _tokens[_at + 2].kind == _T.name ? _ref(_tokens[_at + 2].text) : null;
      if (a == null || b == null) throw const _FormulaError('#ERR');
      _at += 3;
      return sheet._range(a.$1, a.$2, b.$1, b.$2);
    }
    return [_sum()];
  }

  double _call(String name) {
    _at++; // the bracket
    final args = <List<double>>[];
    if (_peek.kind != _T.close) {
      args.add(_argument());
      while (_peek.kind == _T.comma) {
        _at++;
        args.add(_argument());
      }
    }
    if (_peek.kind != _T.close) throw const _FormulaError('#ERR');
    _at++;
    final all = [for (final a in args) ...a];
    switch (name) {
      case 'SUM':
        return all.fold(0.0, (a, b) => a + b);
      case 'AVERAGE' || 'AVG':
        if (all.isEmpty) throw const _FormulaError('#DIV/0!');
        return all.fold(0.0, (a, b) => a + b) / all.length;
      case 'MIN':
        return all.isEmpty ? 0 : all.reduce((a, b) => a < b ? a : b);
      case 'MAX':
        return all.isEmpty ? 0 : all.reduce((a, b) => a > b ? a : b);
      case 'COUNT':
        return all.length.toDouble();
      case 'ROUND':
        if (args.isEmpty || args.length > 2 || args[0].length != 1 || (args.length == 2 && args[1].length != 1)) throw const _FormulaError('#ERR');
        final digits = args.length == 2 ? args[1][0].round().clamp(0, 12) : 0;
        var scale = 1.0;
        for (var i = 0; i < digits; i++) {
          scale *= 10;
        }
        return (args[0][0] * scale).roundToDouble() / scale;
      default:
        throw const _FormulaError('#ERR');
    }
  }
}

/// [raw] (the head first) with every formula replaced by what it shows.
List<List<String>> worked(List<List<String>> raw) {
  if (!raw.any((r) => r.any(isFormula))) return raw;
  final sheet = TableSheet(raw);
  return [
    for (var r = 0; r < raw.length; r++) [for (var c = 0; c < raw[r].length; c++) sheet.display(r, c)],
  ];
}
