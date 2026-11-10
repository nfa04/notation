import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../markdown/code_highlight.dart';
import '../spelling/spell_service.dart';

/// The formatting a piece of text can have. Those from [font] on carry a [TextSpanAttribute.value].
enum AttributeType { bold, italic, underline, font, size, color, highlight, superscript, subscript }

/// The fonts text can be set in: the name that is shown and saved, and the family it is drawn with (bundled, so that it looks
/// the same everywhere).
const documentFonts = {'Sans': 'LiberationSans', 'Serif': 'LiberationSerif', 'Mono': 'LiberationMono', 'DejaVu Sans': 'DejaVuSans'};

/// The size the text of a document has when none is picked, in points.
const documentPointSize = 12.0;

/// Formatting of the characters from [start] to [end] (exclusive). [value] is what a font, size or colour is: the name of a
/// [documentFonts] font, a size in points (`14`), a colour as `#RRGGBB`.
class TextSpanAttribute {
  final int start;
  final int end;
  final AttributeType type;
  final String? value;

  TextSpanAttribute({required this.start, required this.end, required this.type, this.value});

  TextSpanAttribute moved(int start, int end) => TextSpanAttribute(start: start, end: end, type: type, value: value);

  TextSpanAttribute copy() => moved(start, end);

  /// The colour as ARGB, for a [AttributeType.color] or [AttributeType.highlight] (null: none, or the usual yellow).
  int? get colorValue {
    final v = value;
    if (v == null || !v.startsWith('#') || v.length != 7) return null;
    final rgb = int.tryParse(v.substring(1), radix: 16);
    return rgb == null ? null : 0xFF000000 | rgb;
  }

  /// The size as a factor of the usual one, for a [AttributeType.size].
  double? get sizeValue {
    final pt = double.tryParse(value ?? '');
    return pt == null || pt <= 0 ? null : (pt / documentPointSize).clamp(0.25, 8.0);
  }

  int get fingerprint => Object.hash(start, end, type, value);

  static String hexOf(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// A text controller that shows bold, italic and underlined spans, the spelling marks and the find marks in its text.
class RichInlineTextController extends TextEditingController {
  final List<TextSpanAttribute> attributes = [];

  RichInlineTextController() {
    addListener(_changed);
  }

  // ---- the formatting follows the text it is on

  /// Set while the attributes are being moved by whoever changes the text (they are then not moved again here).
  bool _attributesMoved = false;

  /// Where the last change of the text was: from [of] to [now], the text before `start` and the last `tail` characters stayed.
  ({String of, String now, int start, int tail}) lastEdit = (of: '', now: '', start: 0, tail: 0);

  /// [v], from a change that is known to leave the first [same] characters of the text and the last [sameEnd] alone: nobody has to go
  /// through all of the text to find what changed.
  void setWithin(TextEditingValue v, {required int same, required int sameEnd}) {
    _sameFrom = same;
    _sameEnd = sameEnd;
    try {
      value = v;
    } finally {
      _sameFrom = _sameEnd = 0;
    }
  }

  int _sameFrom = 0, _sameEnd = 0;

  /// What [setWithin] said of the change being made now.
  int get sameFrom => _sameFrom;
  int get sameEnd => _sameEnd;

  /// [attributes] were changed directly: what shows them is told.
  void attributesChanged() => notifyListeners();

  /// Formatting picked with nothing selected: it goes on what is typed next at [_pendingAt].
  final Map<AttributeType, String?> _pending = {};
  int _pendingAt = -1;

  @override
  set value(TextEditingValue newValue) {
    final old = super.value.text;
    if (newValue.text != old && !_attributesMoved) _textChanged(old, newValue.text);
    if (newValue.text == old && _pending.isNotEmpty && !(newValue.selection.isCollapsed && newValue.selection.baseOffset == _pendingAt)) {
      _pending.clear();
    }
    super.value = newValue;
  }

  /// Moves the attributes with an edit of the text from [old] to [now]: what is typed takes the formatting of the character before
  /// it (at the start of a line, of the one after it); what is cut out takes its formatting with it.
  void _textChanged(String old, String now) {
    var p = _sameFrom;
    assert(old.substring(0, p) == now.substring(0, p));
    while (p < old.length && p < now.length && old.codeUnitAt(p) == now.codeUnitAt(p)) {
      p++;
    }
    // (what is known to stay at the end can overlap what was found to stay at the start: in a run of line breaks, say)
    var tail = math.min(_sameEnd, math.min(old.length, now.length) - p);
    assert(old.substring(old.length - tail) == now.substring(now.length - tail));
    while (tail < old.length - p && tail < now.length - p && old.codeUnitAt(old.length - 1 - tail) == now.codeUnitAt(now.length - 1 - tail)) {
      tail++;
    }
    lastEdit = (of: old, now: now, start: p, tail: tail);
    final q = old.length - tail; // old[p, q) was replaced by now[p, p + inserted)
    final inserted = now.length - tail - p;
    // text wrapped in Markdown marks (`three` -> `**three**`) or unwrapped: two small edits, so that the formatting stays on the text
    bool marksOnly(String s) => RegExp(r'^[*_~`=]*$').hasMatch(s);
    final removed = old.substring(p, q), put = now.substring(p, p + inserted);
    if (removed.isNotEmpty && put.length > removed.length) {
      final k = put.indexOf(removed);
      if (k >= 0 && marksOnly(put.substring(0, k)) && marksOnly(put.substring(k + removed.length))) {
        final mid = old.replaceRange(q, q, put.substring(k + removed.length));
        _textChanged(old, mid);
        _textChanged(mid, now);
        return;
      }
    } else if (put.isNotEmpty && removed.length > put.length) {
      final k = removed.indexOf(put);
      if (k >= 0 && marksOnly(removed.substring(0, k)) && marksOnly(removed.substring(k + put.length))) {
        final mid = old.replaceRange(p + k + put.length, q, '');
        _textChanged(old, mid);
        _textChanged(mid, now);
        return;
      }
    }
    final delta = inserted - (q - p);
    final lineStart = p == 0 || old[p - 1] == '\n';
    // (Markdown marks put around formatted text do not take its formatting)
    final marks = inserted > 0 && q == p && RegExp(r'^[*_~`=]+$').hasMatch(now.substring(p, p + inserted));
    final pendingHere = _pendingAt == p && q == p && inserted > 0;
    if (attributes.isNotEmpty) {
      final moved = <TextSpanAttribute>[];
      for (final a in attributes) {
        int s, e;
        if (q == p) {
          // only typed: it joins the formatting it is typed into
          final grows = !marks && (lineStart ? a.start <= p && a.end > p : a.start < p && a.end >= p);
          s = a.start > p || (a.start == p && !grows) ? a.start + delta : a.start;
          e = a.end > p || grows ? a.end + delta : a.end;
        } else {
          s = a.start <= p ? a.start : (a.start >= q ? a.start + delta : p);
          e = a.end <= p ? a.end : (a.end >= q ? a.end + delta : p + inserted);
        }
        if (e > s) moved.add(a.moved(s, e));
      }
      attributes
        ..clear()
        ..addAll(moved);
    }
    if (pendingHere) {
      final pending = Map.of(_pending);
      _pending.clear();
      for (final e in pending.entries) {
        _setAttribute(e.key, e.value, p, p + inserted);
      }
    } else {
      _pending.clear();
    }
  }

  /// The attribute of [type] on the character at [offset] (for a caret: the one before it, at a line start the one after it).
  TextSpanAttribute? attributeAt(AttributeType type, int offset) {
    if (_pendingAt == offset && _pending.containsKey(type)) {
      final v = _pending[type];
      return v == null ? null : TextSpanAttribute(start: offset, end: offset, type: type, value: v);
    }
    final at = offset > 0 && offset <= text.length && text[offset - 1] != '\n' ? offset - 1 : offset;
    return attributes.where((a) => a.type == type && a.start <= at && a.end > at).lastOrNull;
  }

  /// Whether all of [start, end) has an attribute of [type].
  bool hasAttribute(AttributeType type, int start, int end) {
    if (start >= end) return attributeAt(type, start) != null;
    var at = start;
    final spans = attributes.where((a) => a.type == type && a.end > start && a.start < end).toList()..sort((a, b) => a.start.compareTo(b.start));
    for (final a in spans) {
      if (a.start > at) return false;
      if (a.end > at) at = a.end;
    }
    return at >= end;
  }

  /// Gives the selection the formatting [type] with [value] (null: takes it away). With nothing selected, it goes on what is typed
  /// next there.
  void setAttribute(AttributeType type, String? value) {
    final sel = selection;
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      if (_pendingAt != sel.baseOffset) _pending.clear();
      _pendingAt = sel.baseOffset;
      _pending[type] = value;
      notifyListeners();
      return;
    }
    _setAttribute(type, value, sel.start, sel.end);
    notifyListeners();
  }

  void _setAttribute(AttributeType type, String? value, int start, int end) {
    final kept = <TextSpanAttribute>[];
    for (final a in attributes) {
      if (a.type != type || a.end <= start || a.start >= end) {
        kept.add(a);
        continue;
      }
      if (a.start < start) kept.add(a.moved(a.start, start));
      if (a.end > end) kept.add(a.moved(end, a.end));
    }
    // (for a type without a value any value puts it on, and null takes it off)
    if (value != null) kept.add(TextSpanAttribute(start: start, end: end, type: type, value: type.index < AttributeType.font.index ? null : value));
    attributes
      ..clear()
      ..addAll(kept);
  }

  /// Takes [type] away from the selection, or puts it on all of it when some of it does not have it yet.
  void toggleAttribute(AttributeType type) {
    final sel = selection;
    if (!sel.isValid) return;
    final on = sel.isCollapsed ? attributeAt(type, sel.baseOffset) != null : hasAttribute(type, sel.start, sel.end);
    if (sel.isCollapsed) {
      if (_pendingAt != sel.baseOffset) _pending.clear();
      _pendingAt = sel.baseOffset;
      if (on) {
        _pending[type] = null;
      } else {
        _pending[type] = '';
      }
      notifyListeners();
      return;
    }
    final kept = <TextSpanAttribute>[];
    for (final a in attributes) {
      if (a.type != type || a.end <= sel.start || a.start >= sel.end) {
        kept.add(a);
        continue;
      }
      if (a.start < sel.start) kept.add(a.moved(a.start, sel.start));
      if (a.end > sel.end) kept.add(a.moved(sel.end, a.end));
    }
    if (!on) kept.add(TextSpanAttribute(start: sel.start, end: sel.end, type: type));
    attributes
      ..clear()
      ..addAll(kept);
    notifyListeners();
  }

  /// Takes all the formatting picked from the bar off the selection (the Markdown in the text stays).
  void clearAttributes() {
    final sel = selection;
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      _pending
        ..clear()
        ..addAll({for (final t in AttributeType.values) t: null});
      _pendingAt = sel.baseOffset;
      notifyListeners();
      return;
    }
    final kept = <TextSpanAttribute>[];
    for (final a in attributes) {
      if (a.end <= sel.start || a.start >= sel.end) {
        kept.add(a);
        continue;
      }
      if (a.start < sel.start) kept.add(a.moved(a.start, sel.start));
      if (a.end > sel.end) kept.add(a.moved(sel.end, a.end));
    }
    attributes
      ..clear()
      ..addAll(kept);
    notifyListeners();
  }

  // ---- spelling ----

  SpellService? _spell;
  Timer? _spellTimer;
  String _checkedText = '';

  /// Where words are spelled wrong (drawn with a wavy red line), as of the last look.
  List<TextRange> misspelled = const [];

  /// Starts (or, with null, stops) checking the spelling of this text, a moment after it changes.
  void useSpelling(SpellService? service) {
    if (identical(service, _spell)) return;
    _spell?.removeListener(recheckSpelling);
    _spell = service;
    service?.addListener(recheckSpelling);
    scheduleMicrotask(recheckSpelling); // (not now: this is called while building)
  }

  /// Looks at the text again now.
  void recheckSpelling() {
    _spellTimer?.cancel();
    final checker = _spell?.checker;
    _checkedText = text;
    if (checker == null || !checker.active) {
      if (misspelled.isNotEmpty) {
        misspelled = const [];
        notifyListeners();
      }
      return;
    }
    final cursor = selection.isValid && selection.isCollapsed ? selection.baseOffset : -1;
    // the word being typed is not marked until it is finished
    final found = [
      for (final r in checker.misspellings(text))
        if (!(cursor > r.start && cursor <= r.end)) r,
    ];
    final same = found.length == misspelled.length && !found.asMap().entries.any((e) => e.value != misspelled[e.key]);
    misspelled = found;
    if (!same) notifyListeners();
  }

  void _changed() {
    if (_spell == null || text == _checkedText) return;
    // marks that are before the change stay, those after it move with the text, those it touches go
    if (misspelled.isNotEmpty) {
      var start = 0;
      final old = _checkedText;
      while (start < old.length && start < text.length && old[start] == text[start]) {
        start++;
      }
      var tail = 0;
      while (tail < old.length - start && tail < text.length - start && old[old.length - 1 - tail] == text[text.length - 1 - tail]) {
        tail++;
      }
      final delta = text.length - old.length;
      misspelled = [
        for (final r in misspelled)
          if (r.end <= start) r else if (r.start >= old.length - tail) TextRange(start: r.start + delta, end: r.end + delta),
      ];
      _checkedText = text;
    }
    _spellTimer?.cancel();
    _spellTimer = Timer(const Duration(milliseconds: 600), recheckSpelling);
  }

  @override
  void dispose() {
    _spellTimer?.cancel();
    _spell?.removeListener(recheckSpelling);
    super.dispose();
  }

  void toggleAttributeForSelection(AttributeType type) {
    if (selection.isCollapsed || selection.start < 0) return;

    final start = selection.start;
    final end = selection.end;

    final existingIndex = attributes.indexWhere(
      (attr) => attr.type == type && attr.start <= start && attr.end >= end,
    );

    if (existingIndex >= 0) {
      attributes.removeAt(existingIndex);
    } else {
      attributes.add(TextSpanAttribute(start: start, end: end, type: type));
    }
    notifyListeners();
  }

  /// Replaces stretches of the text ([edits]: in order, not overlapping). The bold, italic and underlined spans stay with their words;
  /// the caret goes behind the last replacement.
  void replaceRanges(List<({int start, int end, String text})> edits) {
    if (edits.isEmpty) return;
    final out = StringBuffer();
    var at = 0;
    for (final e in edits) {
      out.write(text.substring(at, e.start));
      out.write(e.text);
      at = e.end;
    }
    out.write(text.substring(at));
    // where a place of the old text is in the new one (inside a replaced stretch: its start, or its end if [end])
    int moved(int p, {required bool end}) {
      var delta = 0;
      for (final e in edits) {
        if (e.end <= p) {
          delta += e.text.length - (e.end - e.start);
        } else if (e.start < p) {
          return e.start + delta + (end ? e.text.length : 0);
        }
      }
      return p + delta;
    }

    final spans = [
      for (final a in attributes)
        a.moved(moved(a.start, end: false), moved(a.end, end: true)),
    ]..removeWhere((a) => a.end <= a.start);
    attributes
      ..clear()
      ..addAll(spans);
    final last = edits.last;
    final caret = moved(last.end, end: true).clamp(0, out.length);
    _attributesMoved = true;
    try {
      value = TextEditingValue(text: out.toString(), selection: TextSelection.collapsed(offset: caret));
    } finally {
      _attributesMoved = false;
    }
  }

  /// The places a search found in the text, and which of them is the one being looked at (-1: none).
  List<({int start, int end})> found = const [];
  int foundNow = -1;

  /// Marks [ranges] as found (the [now]th in a stronger colour); an empty list takes the marks away.
  void showFound(List<({int start, int end})> ranges, [int now = -1]) {
    if (found.isEmpty && ranges.isEmpty) return;
    found = ranges;
    foundNow = now;
    notifyListeners();
  }

  // the blocks of code in the text, with a colour for each character of them (ARGB; 0: none), worked out once for a text
  String? _codeFor;
  bool _codeDark = false;
  List<CodeBlockSpan> _codeBlocks = const [];
  List<int> _codeColors = const [];

  /// Finds the blocks of code in the text and the colour of each character in them (by the language named at the fence), so that
  /// code is coloured while it is typed, in the raw text too.
  void _findCode(bool dark) {
    if (_codeFor == text && _codeDark == dark) return;
    _codeFor = text;
    _codeDark = dark;
    _codeBlocks = codeBlockSpans(text);
    _codeColors = _codeBlocks.isEmpty ? const [] : List<int>.filled(text.length, 0);
    for (final b in _codeBlocks) {
      // the fences: dim
      final dim = dark ? 0xFF8B949E : 0xFF6E7781;
      for (var i = b.start; i < b.bodyStart && i < text.length; i++) {
        _codeColors[i] = dim;
      }
      for (var i = b.bodyEnd; i < b.end && i < text.length; i++) {
        _codeColors[i] = dim;
      }
      var at = b.bodyStart;
      for (final t in highlightCode(text.substring(b.bodyStart, b.bodyEnd), b.lang)) {
        final c = codeColor(t.kind, dark: dark) ?? 0;
        for (var k = 0; k < t.text.length && at + k < text.length; k++) {
          _codeColors[at + k] = c;
        }
        at += t.text.length;
      }
    }
  }

  bool _inCode(int i) {
    for (final b in _codeBlocks) {
      if (i >= b.start && i < b.end) return true;
    }
    return false;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (text.isEmpty) {
      return TextSpan(text: '', style: style);
    }

    final wrong = List<bool>.filled(text.length, false);
    for (final r in misspelled) {
      for (var i = r.start; i < r.end && i < text.length; i++) {
        wrong[i] = true;
      }
    }
    final mark = List<int>.filled(text.length, 0);
    for (var k = 0; k < found.length; k++) {
      for (var i = found[k].start; i < found[k].end && i < text.length; i++) {
        mark[i] = k == foundNow ? 2 : 1;
      }
    }
    _findCode((style?.color ?? Colors.black).computeLuminance() > 0.5);
    final children = <InlineSpan>[];
    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      bool isBold = false;
      bool isItalic = false;
      bool isUnderline = false;

      for (var attr in attributes) {
        if (i >= attr.start && i < attr.end) {
          if (attr.type == AttributeType.bold) isBold = true;
          if (attr.type == AttributeType.italic) isItalic = true;
          if (attr.type == AttributeType.underline) isUnderline = true;
        }
      }

      children.add(
        TextSpan(
          text: char,
          style: style?.copyWith(
            fontFamily: _codeBlocks.isNotEmpty && _inCode(i) ? 'monospace' : null,
            color: _codeBlocks.isNotEmpty && _codeColors[i] != 0 ? Color(_codeColors[i]) : null,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
            decoration: wrong[i] || isUnderline ? TextDecoration.underline : TextDecoration.none,
            decorationStyle: wrong[i] ? TextDecorationStyle.wavy : null,
            decorationColor: wrong[i] ? Colors.red : null,
            backgroundColor: mark[i] == 0 ? null : (mark[i] == 2 ? const Color(0xAAFF9800) : const Color(0x66FFEB3B)),
          ),
        ),
      );
    }

    return TextSpan(children: children, style: style);
  }
}
