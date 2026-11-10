import 'dart:convert';
import 'dart:math' as math;

/// A spelling dictionary in the Hunspell format (a `.dic` word list and an `.aff` file of affix rules), read and used in
/// plain Dart, so that it works on every platform the app does. It covers what the dictionaries of the common
/// languages use: prefixes and suffixes (also with further suffixes and the two together), flags for words that must
/// keep their case, are forbidden or only occur in compounds, simple compounds (as German forms them), the character
/// replacements for the input (`ICONV`), breaking at hyphens, and the `TRY` / `REP` tables that suggestions come from.
/// What it leaves out (the `COMPOUNDRULE` patterns, morphological analysis, two-word suggestions beyond a simple
/// split) is not needed to tell whether a word is spelled right.
class HunspellDictionary {
  final Map<String, Set<String>> _words;
  final List<_Rule> _prefixes, _suffixes;
  final Map<String, List<_Rule>> _prefixesByFirst = {}, _suffixesByLast = {};
  final List<_Rule> _prefixesEmpty = [], _suffixesEmpty = [];
  final String _try;
  final List<(String, String)> _rep, _iconv;
  final String? _keepCase, _forbidden, _needAffix, _onlyInCompound, _noSuggest, _compoundFlag, _compoundBegin, _compoundMiddle, _compoundEnd, _compoundPermit;
  final int _compoundMin;
  final bool _hasCompounds;

  /// Set while looking for suggestions two edits away: they are checked as plain words, which keeps that fast.
  bool _skipCompounds = false;

  HunspellDictionary._(
    this._words,
    this._prefixes,
    this._suffixes,
    this._try,
    this._rep,
    this._iconv,
    this._keepCase,
    this._forbidden,
    this._needAffix,
    this._onlyInCompound,
    this._noSuggest,
    this._compoundFlag,
    this._compoundBegin,
    this._compoundMiddle,
    this._compoundEnd,
    this._compoundPermit,
    this._compoundMin,
  ) : _hasCompounds = _compoundFlag != null || _compoundBegin != null {
    for (final r in _prefixes) {
      r.add.isEmpty ? _prefixesEmpty.add(r) : (_prefixesByFirst[r.add[0]] ??= []).add(r);
    }
    for (final r in _suffixes) {
      r.add.isEmpty ? _suffixesEmpty.add(r) : (_suffixesByLast[r.add[r.add.length - 1]] ??= []).add(r);
    }
  }

  /// How many words the word list has.
  int get size => _words.length;

  /// Reads a dictionary. [aff] and [dic] are the bytes of the two files; the character set is the one the `.aff` file
  /// declares (`SET`). [breathe] is called now and then while reading, so that the screen can go on (a big dictionary has
  /// hundreds of thousands of lines).
  static Future<HunspellDictionary> parse(List<int> aff, List<int> dic, {Future<void> Function()? breathe}) async {
    final affText = _decode(aff, null);
    final charset = RegExp(r'^\s*SET\s+(\S+)', multiLine: true).firstMatch(affText)?.group(1);
    final text = charset == null ? affText : _decode(aff, charset);
    final settings = _AffixFile.read(text);
    final words = <String, Set<String>>{};
    final interned = <String, Set<String>>{};
    const empty = <String>{};

    final lines = _decode(dic, charset).split('\n');
    var first = true;
    for (var n = 0; n < lines.length; n++) {
      if (breathe != null && n % 20000 == 0) await breathe();
      var line = lines[n];
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty || line.startsWith('#') || line.startsWith('\t')) continue;
      if (first) {
        first = false;
        if (RegExp(r'^\d+\s*$').hasMatch(line)) continue; // (the number of words)
      }
      // word/FLAGS morphology ...
      var end = line.length;
      for (var i = 0; i < line.length; i++) {
        final c = line.codeUnitAt(i);
        if (c == 0x20 || c == 0x09) {
          end = i;
          break;
        }
      }
      final entry = line.substring(0, end);
      var slash = -1;
      for (var i = 0; i < entry.length; i++) {
        if (entry[i] == '/' && (i == 0 || entry[i - 1] != '\\')) {
          slash = i;
          break;
        }
      }
      final word = (slash < 0 ? entry : entry.substring(0, slash)).replaceAll(r'\/', '/');
      if (word.isEmpty) continue;
      final Set<String> flags;
      if (slash < 0 || slash == entry.length - 1) {
        flags = empty;
      } else {
        final raw = entry.substring(slash + 1);
        flags = interned.putIfAbsent(raw, () => settings.flags(raw).toSet());
      }
      final old = words[word];
      words[word] = old == null || old.isEmpty ? flags : (flags.isEmpty ? old : {...old, ...flags});
    }
    return HunspellDictionary._(
      words,
      settings.prefixes,
      settings.suffixes,
      settings.tryChars,
      settings.rep,
      settings.iconv,
      settings.single('KEEPCASE'),
      settings.single('FORBIDDENWORD'),
      settings.single('NEEDAFFIX') ?? settings.single('PSEUDOROOT'),
      settings.single('ONLYINCOMPOUND'),
      settings.single('NOSUGGEST'),
      settings.single('COMPOUNDFLAG'),
      settings.single('COMPOUNDBEGIN'),
      settings.single('COMPOUNDMIDDLE'),
      settings.single('COMPOUNDEND'),
      settings.single('COMPOUNDPERMITFLAG'),
      int.tryParse(settings.single('COMPOUNDMIN') ?? '') ?? 3,
    );
  }

  static String _decode(List<int> bytes, String? charset) {
    final c = charset?.toUpperCase().replaceAll('_', '-');
    if (c == null || c == 'UTF-8' || c == 'UTF8') return utf8.decode(bytes, allowMalformed: true);
    if (c == 'ISO8859-1' || c == 'ISO-8859-1' || c == 'LATIN1') return latin1.decode(bytes);
    if (c == 'ISO8859-15' || c == 'ISO-8859-15') {
      const swapped = {0xA4: '€', 0xA6: 'Š', 0xA8: 'š', 0xB4: 'Ž', 0xB8: 'ž', 0xBC: 'Œ', 0xBD: 'œ', 0xBE: 'Ÿ'};
      return String.fromCharCodes([for (final b in bytes) if (swapped.containsKey(b)) swapped[b]!.codeUnitAt(0) else b]);
    }
    if (c == 'KOI8-R') return _koi8r(bytes);
    if (c == 'ISO8859-2' || c == 'ISO-8859-2') return _latin2(bytes);
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _koi8r(List<int> bytes) {
    const upper = 'ЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬЫЗШЭЩЧЪ';
    const lower = 'юабцдефгхийклмнопярстужвьызшэщчъ';
    const table = '─│┌┐└┘├┤┬┴┼▀▄█▌▐░▒▓⌠■∙√≈≤≥ ⌡°²·÷═║╒ё╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡Ё╢╣╤╥╦╧╨╩╪╫╬©';
    final out = StringBuffer();
    for (final b in bytes) {
      if (b < 0x80) {
        out.writeCharCode(b);
      } else if (b < 0xC0) {
        out.write(table[b - 0x80]);
      } else if (b < 0xE0) {
        out.write(lower[b - 0xC0]);
      } else {
        out.write(upper[b - 0xE0]);
      }
    }
    return out.toString();
  }

  static String _latin2(List<int> bytes) {
    const high = ' Ą˘Ł¤ĽŚ§¨ŠŞŤŹ­ŽŻ°ą˛ł´ľśˇ¸šşťź˝žżŔÁÂĂÄĹĆÇČÉĘËĚÍÎĎĐŃŇÓÔŐÖ×ŘŮÚŰÜÝŢßŕáâăäĺćçčéęëěíîďđńňóôőö÷řůúűüýţ˙';
    return String.fromCharCodes([for (final b in bytes) b < 0xA0 ? b : high.codeUnitAt(b - 0xA0)]);
  }

  // ---- is a word spelled right ----

  /// Whether [word] is spelled right. A word with digits in it is left alone, and so is one that is only a hyphen or
  /// an apostrophe.
  bool isCorrect(String word) {
    var w = word;
    for (final (from, to) in _iconv) {
      if (w.contains(from)) w = w.replaceAll(from, to);
    }
    if (w.isEmpty) return true;
    if (RegExp(r'\d').hasMatch(w)) return true;
    if (_checkCased(w)) return true;
    // broken at hyphens: every part has to be a word
    if (w.contains('-')) {
      final parts = w.split('-').where((p) => p.isNotEmpty).toList();
      return parts.isNotEmpty && parts.length > 1 && parts.every(_checkCased);
    }
    return false;
  }

  bool _checkCased(String w) {
    if (w.isEmpty) return true;
    final lower = w.toLowerCase(), upper = w.toUpperCase();
    if (w == lower) return _accept(w);
    final capitalised = _capitalise(lower);
    if (w == upper && w.length > 1) {
      // WORDS IN CAPITALS: as they are, in small letters, or with a capital at the front
      return _accept(w) || _acceptLowered(lower) || _accept(capitalised);
    }
    if (w == capitalised) return _accept(w) || _acceptLowered(lower);
    // iPhone, McDonald: only as written in the dictionary
    return _accept(w);
  }

  /// [lower] for a word that was written with capitals: not allowed for words that must keep their case.
  bool _acceptLowered(String lower) => _accept(lower, lowered: true);

  static String _capitalise(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  bool _accept(String w, {bool lowered = false}) {
    if (_acceptSingle(w, lowered: lowered)) return true;
    return _hasCompounds && !_skipCompounds && w.length >= 2 * _compoundMin && _isCompound(w, lowered: lowered);
  }

  /// The flags of the dictionary entry for [stem] if it has all of [flags] and may be used here: not a forbidden word, not one that
  /// needs an affix (unless [affixed]), not one for compounds only (unless [inCompound]), not one that keeps its case
  /// (when [lowered]). Null if there is no such entry.
  Set<String>? _entry(String stem, List<String> flags, {required bool affixed, bool inCompound = false, bool lowered = false}) {
    final f = _words[stem];
    if (f == null) return null;
    if (_forbidden != null && f.contains(_forbidden)) return null;
    if (_needAffix != null && f.contains(_needAffix) && !affixed) return null;
    if (_onlyInCompound != null && f.contains(_onlyInCompound) && !inCompound) return null;
    if (lowered && _keepCase != null && f.contains(_keepCase)) return null;
    for (final x in flags) {
      if (!f.contains(x)) return null;
    }
    return f;
  }

  /// Whether a form made with [rules] from an entry with [entry] flags may stand as a part of a compound that must have one of
  /// [any]: the rules give the place (a suffix that adds nothing but the flag for the beginning of a compound, as the German
  /// dictionaries do), or the word does and the rules allow compounding at all.
  bool _fits(Set<String> entry, List<_Rule> rules, Set<String>? any, bool inCompound) {
    final continuation = <String>{for (final r in rules) ...r.continuation};
    // a form that is only for compounds
    if (_onlyInCompound != null && continuation.contains(_onlyInCompound) && !inCompound) return false;
    if (any == null) return true;
    if (rules.isEmpty) return any.any(entry.contains);
    if (any.any(continuation.contains)) return true;
    return _compoundPermit != null && continuation.contains(_compoundPermit) && any.any(entry.contains);
  }

  /// What was found out about single words and parts of compounds (the same parts come up again and again).
  final Map<String, bool> _known = {};

  bool _acceptSingle(String w, {bool lowered = false, Set<String>? any, bool inCompound = false}) {
    final key = '${any?.join(',') ?? ''}|${inCompound ? 1 : 0}${lowered ? 1 : 0}|$w';
    final known = _known[key];
    if (known != null) return known;
    final result = _acceptSingleUncached(w, lowered: lowered, any: any, inCompound: inCompound);
    if (_known.length > 30000) _known.clear();
    return _known[key] = result;
  }

  bool _acceptSingleUncached(String w, {bool lowered = false, Set<String>? any, bool inCompound = false}) {
    final direct = _entry(w, const [], affixed: false, inCompound: inCompound, lowered: lowered);
    if (direct != null && _fits(direct, const [], any, inCompound)) return true;
    return _affixed(w, lowered: lowered, any: any, inCompound: inCompound);
  }

  bool _affixed(String w, {required bool lowered, Set<String>? any, bool inCompound = false}) {
    // [needed]: rules whose flags the entry must have; [also]: further rules the form went through
    bool ok(String stem, List<_Rule> needed, [List<_Rule> also = const []]) {
      final e = _entry(stem, [for (final r in needed) r.flag], affixed: true, inCompound: inCompound, lowered: lowered);
      return e != null && _fits(e, [...needed, ...also], any, inCompound);
    }

    for (final rule in _suffixCandidates(w)) {
      final stem = rule.stemOf(w);
      if (stem == null) continue;
      if (ok(stem, [rule])) return true;
      // a prefix as well (both cross over)
      if (rule.cross) {
        for (final p in _prefixCandidates(stem)) {
          if (!p.cross) continue;
          final inner = p.stemOf(stem);
          if (inner != null && ok(inner, [rule, p])) return true;
        }
      }
      // another suffix underneath that allows this one (the rule of the inner suffix lists the flag of the outer one)
      for (final inner in _suffixCandidates(stem)) {
        if (!inner.continuation.contains(rule.flag)) continue;
        final base = inner.stemOf(stem);
        if (base != null && ok(base, [inner], [rule])) return true;
      }
    }
    for (final rule in _prefixCandidates(w)) {
      final stem = rule.stemOf(w);
      if (stem == null) continue;
      if (ok(stem, [rule])) return true;
      // a suffix underneath that allows this prefix
      for (final inner in _suffixCandidates(stem)) {
        if (!inner.continuation.contains(rule.flag)) continue;
        final base = inner.stemOf(stem);
        if (base != null && ok(base, [inner], [rule])) return true;
      }
    }
    return false;
  }

  Iterable<_Rule> _suffixCandidates(String w) sync* {
    if (w.isNotEmpty) {
      final byLast = _suffixesByLast[w[w.length - 1]];
      if (byLast != null) {
        for (final r in byLast) {
          if (w.endsWith(r.add)) yield r;
        }
      }
    }
    yield* _suffixesEmpty;
  }

  Iterable<_Rule> _prefixCandidates(String w) sync* {
    if (w.isNotEmpty) {
      final byFirst = _prefixesByFirst[w[0]];
      if (byFirst != null) {
        for (final r in byFirst) {
          if (w.startsWith(r.add)) yield r;
        }
      }
    }
    yield* _prefixesEmpty;
  }

  // ---- compounds ----

  bool _isCompound(String w, {required bool lowered}) {
    final begin = {?_compoundFlag, ?_compoundBegin};
    final middle = {?_compoundFlag, ?_compoundMiddle};
    final end = {?_compoundFlag, ?_compoundEnd};
    if (begin.isEmpty || end.isEmpty) return false;
    // (the parts after the first are in small letters, though the dictionary has them with a capital if they are nouns)
    // (a word that is not one could take very long to give up: only so many tries)
    var tries = 0;
    final seen = <String, bool>{};
    bool part(String s, Set<String> flags, String place) => seen.putIfAbsent(
        '$place:$s',
        () => ++tries > 500 ? false : _acceptSingle(s, any: flags, inCompound: true, lowered: lowered) || _acceptSingle(_capitalise(s), any: flags, inCompound: true, lowered: lowered));
    final rests = <String, bool>{};
    bool rest(String tail, int parts) => rests.putIfAbsent('$parts:$tail', () {
          // the last part
          if (tail.length >= _compoundMin && part(tail, end, 'e')) return true;
          if (parts >= 4) return false;
          for (var cut = _compoundMin; cut <= tail.length - _compoundMin; cut++) {
            if (part(tail.substring(0, cut), middle, 'm') && rest(tail.substring(cut), parts + 1)) return true;
          }
          return false;
        });

    for (var cut = _compoundMin; cut <= w.length - _compoundMin && tries <= 500; cut++) {
      tries++;
      if (_acceptSingle(w.substring(0, cut), any: begin, inCompound: true, lowered: lowered) && rest(w.substring(cut), 2)) return true;
    }
    return false;
  }

  // ---- suggestions ----

  /// Words that [word] may have been meant to be, best first: one letter more, fewer or different, two letters
  /// swapped, the replacements of the dictionary, the word broken in two, and (for [deep], slower) two letters
  /// fewer or swapped.
  List<String> suggest(String word, {int max = 6, bool deep = true}) {
    if (word.isEmpty || word.length > 40) return const [];
    // (a long word is not tried as a compound for every candidate: that would take seconds)
    final skipBefore = _skipCompounds;
    _skipCompounds = skipBefore || word.length > 10;
    try {
      return _suggest(word, max, deep);
    } finally {
      _skipCompounds = skipBefore;
    }
  }

  /// How common words are, for ranking suggestions: the most common first (a list of words from a corpus of the language).
  /// Without it "tis" is as likely to be "tie" as "this"; with it the common word comes first.
  void useFrequencies(Iterable<String> mostCommonFirst) {
    final ranks = <String, int>{};
    var i = 0;
    for (final w in mostCommonFirst) {
      final lower = w.toLowerCase();
      if (lower.isEmpty || lower.startsWith("'") || ranks.containsKey(lower)) continue;
      ranks[lower] = i++;
      if (i >= 80000) break;
    }
    _ranks = ranks.isEmpty ? null : ranks;
  }

  Map<String, int>? _ranks;

  static const _keyRows = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const _keyShift = [0.0, 0.5, 1.5];

  /// Whether two letters are next to each other on a keyboard (the usual wrong key).
  static bool _neighbours(String a, String b) {
    (double, double)? where(String c) {
      for (var r = 0; r < _keyRows.length; r++) {
        final i = _keyRows[r].indexOf(c.toLowerCase());
        if (i >= 0) return (i + _keyShift[r], r.toDouble());
      }
      return null;
    }

    final p = where(a), q = where(b);
    if (p == null || q == null) return false;
    final dx = p.$1 - q.$1, dy = p.$2 - q.$2;
    return dx * dx + dy * dy <= 1.3;
  }

  List<String> _suggest(String word, int max, bool deep) {
    // the edit that makes each candidate, as a cost: a swap or a wrong key next to the right one is a likely slip, a
    // missing or extra letter less, a letter far from the right one least
    final cost = <String, double>{};
    void offer(String candidate, double c) {
      if (candidate == word || candidate.isEmpty) return;
      final old = cost[candidate];
      if (old != null && old <= c) return;
      if (!isCorrect(candidate) || _forbiddenOrNoSuggest(candidate)) return;
      cost[candidate] = c;
    }

    void edits(String w, String Function(String) shown, double extra) {
      void put(String candidate, double c) => offer(shown(candidate), c + extra);
      // (a candidate is checked as it is shown; the edits are made on [w])
      final alphabet = _alphabet(w);
      final n = w.length;
      for (var i = 0; i + 1 < n; i++) {
        if (w[i] != w[i + 1]) put(w.substring(0, i) + w[i + 1] + w[i] + w.substring(i + 2), 1.0); // swapped
      }
      for (final (from, to) in _rep) {
        var at = w.indexOf(from);
        while (at >= 0) {
          put(w.replaceRange(at, at + from.length, to), 1.1);
          at = w.indexOf(from, at + 1);
        }
      }
      for (var i = 0; i < n; i++) {
        final doubled = (i > 0 && w[i] == w[i - 1]) || (i + 1 < n && w[i] == w[i + 1]);
        put(w.substring(0, i) + w.substring(i + 1), doubled ? 1.0 : 1.6); // one letter fewer
        for (final c in alphabet) {
          if (c != w[i]) put(w.substring(0, i) + c + w.substring(i + 1), _neighbours(c, w[i]) ? 1.0 : 1.8); // another letter
        }
      }
      for (var i = 0; i <= n; i++) {
        for (final c in alphabet) {
          final doubled = (i > 0 && w[i - 1] == c) || (i < n && w[i] == c);
          put(w.substring(0, i) + c + w.substring(i), doubled ? 1.1 : 1.6); // one more
        }
      }
    }

    // the same letters in another case
    final lower = word.toLowerCase();
    if (lower != word) offer(lower, 0.3);
    offer(_capitalise(lower), 0.3);

    edits(word, (c) => c, 0);
    // a word that starts with a capital may only be at the start of a sentence: as a small word too, with the capital back
    final capitalised = word.length > 1 && word == _capitalise(lower);
    if (capitalised) edits(lower, _capitalise, 0.2);

    final n = word.length;
    // two words (a single letter only if it is a very common word: "a lot")
    final ranks = _ranks;
    bool common(String w) => w.length > 1 || (ranks != null && (ranks[w.toLowerCase()] ?? 999) < 60);
    for (var i = 1; i <= n - 1; i++) {
      final a = word.substring(0, i), b = word.substring(i);
      if (!common(a) || !common(b)) continue;
      if (isCorrect(a) && isCorrect(b) && !RegExp(r'^\p{Lu}', unicode: true).hasMatch(b)) cost.putIfAbsent('$a $b', () => 2.2);
    }
    if (deep && cost.length < 3 && n >= 5 && n <= 14) {
      final before = _skipCompounds;
      _skipCompounds = true;
      try {
        // two letters fewer or swapped (from every word one edit away that is not a word itself)
        final once = <String>{};
        for (var i = 0; i < n; i++) {
          once.add(word.substring(0, i) + word.substring(i + 1));
        }
        for (var i = 0; i + 1 < n; i++) {
          once.add(word.substring(0, i) + word[i + 1] + word[i] + word.substring(i + 2));
        }
        for (final c1 in once.toList()) {
          for (var i = 0; i < c1.length; i++) {
            offer(c1.substring(0, i) + c1.substring(i + 1), 4.0);
          }
          for (var i = 0; i + 1 < c1.length; i++) {
            offer(c1.substring(0, i) + c1[i + 1] + c1[i] + c1.substring(i + 2), 4.0);
          }
        }
      } finally {
        _skipCompounds = before;
      }
    }

    final typedUpper = word.length > 1 && word == word.toUpperCase();
    final typedLower = word == lower;
    double score(String candidate, double c) {
      var v = c;
      final flat = candidate.toLowerCase();
      // what is no ordinary word: abbreviations, words with apostrophes, odd capitals
      // (a word that only lacks its apostrophe is not odd: dont, don't)
      final onlyApostrophe = RegExp(r"(n't|'ll|'re|'ve|'m|'d)$").hasMatch(flat) && flat.replaceAll("'", '') == lower;
      if (!word.contains("'") && !onlyApostrophe && (candidate.contains("'") || RegExp(r'\d').hasMatch(candidate))) v += 2.5;
      if (onlyApostrophe) v -= 0.6;
      if (!typedUpper && candidate.length > 1 && candidate == candidate.toUpperCase() && RegExp(r'\p{L}', unicode: true).hasMatch(candidate)) v += 2.5;
      if (RegExp(r'.\p{Lu}', unicode: true).hasMatch(candidate) && candidate != candidate.toUpperCase()) v += 2.5;
      if (typedLower && candidate != flat && !candidate.contains(' ')) v += 1.2;
      // it starts and ends like the word
      if (flat.isNotEmpty && lower.isNotEmpty) {
        if (flat[0] == lower[0]) v -= 0.4;
        if (flat[flat.length - 1] == lower[lower.length - 1]) v -= 0.3;
      }
      v += 0.15 * (candidate.length - word.length).abs();
      // how common it is
      final ranks = _ranks;
      if (ranks != null) {
        final key = candidate.contains(' ')
            ? candidate.split(' ').map((w) => ranks[w.toLowerCase()] ?? 80000).reduce((a, b) => a > b ? a : b)
            : ranks[flat] ?? (flat.contains("'") ? ranks[flat.split("'").first] : null);
        if (key == null) {
          v += 0.5;
        } else {
          v -= 2.2 * (1 - math.log(1 + key) / math.log(1 + 80000));
        }
      }
      return v;
    }

    final ranked = [for (final e in cost.entries) (e.key, score(e.key, e.value))]
      ..sort((a, b) {
        final c = a.$2.compareTo(b.$2);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final e in ranked.take(max)) e.$1];
  }

  bool _forbiddenOrNoSuggest(String w) {
    final f = _words[w] ?? _words[w.toLowerCase()];
    return f != null && ((_noSuggest != null && f.contains(_noSuggest)) || (_forbidden != null && f.contains(_forbidden)));
  }

  List<String> _alphabet(String word) {
    final letters = <String>{};
    for (final r in (_try.isEmpty ? 'abcdefghijklmnopqrstuvwxyz' : _try).runes) {
      final c = String.fromCharCode(r);
      if (c != '-' && c != '.') letters.add(c);
    }
    return letters.toList();
  }
}

// ---- the affix file ----

class _Rule {
  final String flag;
  final bool prefix, cross;
  final String strip, add;
  final Set<String> continuation;
  final RegExp? condition;

  _Rule(this.flag, this.prefix, this.cross, this.strip, this.add, this.continuation, this.condition);

  /// The word [w] was made from, or null if this rule's condition does not fit it.
  String? stemOf(String w) {
    final stem = prefix ? strip + w.substring(add.length) : w.substring(0, w.length - add.length) + strip;
    if (stem.isEmpty) return null;
    if (condition != null && !condition!.hasMatch(stem)) return null;
    return stem;
  }
}

class _AffixFile {
  final Map<String, String> _single = {};
  final prefixes = <_Rule>[];
  final suffixes = <_Rule>[];
  final rep = <(String, String)>[];
  final iconv = <(String, String)>[];
  String tryChars = '';
  String _flagType = 'char';

  String? single(String key) => _single[key];

  /// The flags written in [raw] (`AB`, `Ab12` for the long type, `1,2,3` for numbers).
  List<String> flags(String raw) {
    switch (_flagType) {
      case 'long':
        return [for (var i = 0; i + 1 < raw.length; i += 2) raw.substring(i, i + 2)];
      case 'num':
        return raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      default:
        return raw.runes.map(String.fromCharCode).toList();
    }
  }

  static _AffixFile read(String text) {
    final file = _AffixFile();
    final lines = text.split('\n');
    // the flag type comes first, as the rules need it
    for (final line in lines) {
      final m = RegExp(r'^\s*FLAG\s+(\S+)').firstMatch(line);
      if (m != null) {
        final t = m.group(1)!.toLowerCase();
        file._flagType = t == 'long' ? 'long' : (t == 'num' ? 'num' : 'char');
        break;
      }
    }
    final headers = <String, (bool, int)>{}; // "PFX A" -> cross, remaining
    for (var raw in lines) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+'));
      final key = parts[0];
      switch (key) {
        case 'TRY':
          if (parts.length > 1) file.tryChars = parts[1];
        case 'REP':
          if (parts.length >= 3) file.rep.add((parts[1].replaceAll('_', ' '), parts[2].replaceAll('_', ' ')));
        case 'ICONV':
          if (parts.length >= 3) file.iconv.add((parts[1], parts[2]));
        case 'PFX' || 'SFX':
          if (parts.length < 4) break;
          final flag = parts[1];
          final id = '$key $flag';
          if (!headers.containsKey(id) && parts.length <= 5 && (parts[2] == 'Y' || parts[2] == 'N') && int.tryParse(parts[3]) != null) {
            headers[id] = (parts[2] == 'Y', int.parse(parts[3]));
            break;
          }
          final strip = parts[2] == '0' ? '' : parts[2];
          var add = parts[3];
          var cont = <String>{};
          final slash = add.indexOf('/');
          if (slash >= 0) {
            cont = file.flags(add.substring(slash + 1)).toSet();
            add = add.substring(0, slash);
          }
          if (add == '0') add = '';
          final cond = parts.length > 4 ? parts[4] : '.';
          RegExp? condition;
          if (cond != '.') {
            try {
              condition = RegExp(key == 'SFX' ? '(?:$cond)\$' : '^(?:$cond)', unicode: true);
            } catch (_) {
              condition = null;
            }
          }
          final rule = _Rule(flag, key == 'PFX', headers[id]?.$1 ?? false, strip, add, cont, condition);
          (key == 'PFX' ? file.prefixes : file.suffixes).add(rule);
        default:
          if (parts.length >= 2 && !file._single.containsKey(key)) file._single[key] = parts[1];
      }
    }
    return file;
  }
}
