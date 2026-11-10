// Finite automata for the advanced diagrams: read from text, tested on words, made deterministic and minimal.
//
// The text, one statement to a line (`#` starts a comment):
// ```
// start: q0
// accept: q2, q3
// q0 -a-> q1
// q1 --a,b--> q2
// q2 -eps-> q0
// q0 -> q1 : b
// ```
// A state can carry its marks where it is named: `>q0` starts, `*q2` accepts, `((q2))` accepts too. `ε`, `eps`, `epsilon`, `lambda` and `\epsilon`
// are the empty word; an arrow without a label is one as well. A state is named by anything without spaces (`q0`, `q_1`, `{q0,q1}`).

const epsilon = 'ε';

/// The names that stand for the empty word.
final _epsilonNames = RegExp(r'^(?:ε|ϵ|λ|eps|epsilon|lambda|\\epsilon|\\varepsilon|\\lambda)$', caseSensitive: false);

class Transition {
  final String from, to;

  /// The symbols that take [from] to [to] ([epsilon] for the empty word).
  final List<String> symbols;

  const Transition(this.from, this.to, this.symbols);
}

class Automaton {
  final List<String> states;
  final String? start;
  final Set<String> accepting;
  final List<Transition> transitions;

  const Automaton(this.states, this.start, this.accepting, this.transitions);

  bool get isEmpty => states.isEmpty;

  /// The symbols of the alphabet (not the empty word), in order of appearance.
  List<String> get alphabet {
    final out = <String>[];
    for (final t in transitions) {
      for (final s in t.symbols) {
        if (s != epsilon && !out.contains(s)) out.add(s);
      }
    }
    return out;
  }

  bool get hasEpsilon => transitions.any((t) => t.symbols.contains(epsilon));

  /// The states reached from [state] on [symbol].
  Set<String> step(String state, String symbol) => {
        for (final t in transitions)
          if (t.from == state && t.symbols.contains(symbol)) t.to,
      };

  /// [states] and every state that the empty word leads on to.
  Set<String> closure(Iterable<String> states) {
    final out = {...states};
    final todo = [...out];
    while (todo.isNotEmpty) {
      final s = todo.removeLast();
      for (final t in step(s, epsilon)) {
        if (out.add(t)) todo.add(t);
      }
    }
    return out;
  }

  /// The states [states] lead to on [symbol] (and then the empty word).
  Set<String> move(Iterable<String> states, String symbol) => closure({for (final s in states) ...step(s, symbol)});

  /// Whether every state has exactly one way on every symbol, or fewer where something is missing; no empty word.
  bool get isDeterministic {
    if (hasEpsilon) return false;
    for (final s in states) {
      final seen = <String>{};
      for (final t in transitions.where((t) => t.from == s)) {
        for (final c in t.symbols) {
          if (!seen.add(c)) return false;
        }
      }
    }
    return true;
  }

  /// The (state, symbol) pairs that have no way on (only for a deterministic automaton it means a dead end).
  List<(String, String)> get missing {
    final a = alphabet;
    return [
      for (final s in states)
        for (final c in a)
          if (step(s, c).isEmpty) (s, c),
    ];
  }

  /// The states that can be reached from the start.
  Set<String> get reachable {
    if (start == null) return {};
    final seen = {start!};
    final todo = [start!];
    while (todo.isNotEmpty) {
      final s = todo.removeLast();
      for (final t in transitions.where((t) => t.from == s)) {
        if (seen.add(t.to)) todo.add(t.to);
      }
    }
    return seen;
  }

  /// The states from which a state that accepts can be reached.
  Set<String> get live {
    final seen = {...accepting};
    var changed = true;
    while (changed) {
      changed = false;
      for (final t in transitions) {
        if (seen.contains(t.to) && seen.add(t.from)) changed = true;
      }
    }
    return seen;
  }

  /// The text that reads back as this automaton.
  String toText() {
    final out = StringBuffer();
    if (start != null) out.writeln('start: $start');
    if (accepting.isNotEmpty) out.writeln('accept: ${states.where(accepting.contains).join(', ')}');
    for (final t in transitions) {
      out.writeln('${t.from} -${t.symbols.join(',')}-> ${t.to}');
    }
    // states with no transitions at all
    final used = {for (final t in transitions) ...[t.from, t.to], ?start, ...accepting};
    for (final s in states) {
      if (!used.contains(s)) out.writeln(s);
    }
    return out.toString().trimRight();
  }
}

/// An automaton read from text, and what in the text could not be read.
class AutomatonReading {
  final Automaton automaton;

  /// Lines that were not understood, as `line 3: ...`.
  final List<String> problems;

  const AutomatonReading(this.automaton, this.problems);
}

final _arrow = RegExp(r'-+\s*([^->]*?)\s*-*>');

/// Splits [s] at commas that are not inside braces.
List<String> _commaList(String s) {
  final out = <String>[];
  var depth = 0, from = 0;
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '{') depth++;
    if (s[i] == '}') depth--;
    if (s[i] == ',' && depth == 0) {
      out.add(s.substring(from, i));
      from = i + 1;
    }
  }
  out.add(s.substring(from));
  return [for (final p in out) if (p.trim().isNotEmpty) p.trim()];
}

List<String> _symbols(String label) {
  final text = label.trim();
  if (text.isEmpty) return [epsilon];
  return [
    for (final p in text.split(RegExp(r'[,|;]'))) if (p.trim().isNotEmpty) _epsilonNames.hasMatch(p.trim()) ? epsilon : p.trim(),
  ];
}

/// A state's name with its marks taken off: (name, starts, accepts).
(String, bool, bool) _state(String raw) {
  var s = raw.trim();
  var start = false, accept = false;
  while (true) {
    if (s.startsWith('>')) {
      start = true;
      s = s.substring(1).trim();
    } else if (s.startsWith('*')) {
      accept = true;
      s = s.substring(1).trim();
    } else if (s.startsWith('((') && s.endsWith('))')) {
      accept = true;
      s = s.substring(2, s.length - 2).trim();
    } else if (s.startsWith('(') && s.endsWith(')') && !s.startsWith('(*')) {
      s = s.substring(1, s.length - 1).trim();
    } else {
      break;
    }
  }
  return (s, start, accept);
}

final _validName = RegExp(r'^(?:\{[^{}\s]*\}|[^\s{}>*,:()]+)$');

/// The automaton [text] describes, with the lines that were not understood.
AutomatonReading parseAutomaton(String text) {
  final states = <String>[];
  String? start;
  final accepting = <String>{};
  final edges = <(String, String), List<String>>{};
  final order = <(String, String)>[];
  final problems = <String>[];

  String? declare(String raw, {bool marks = true}) {
    final (name, isStart, isAccept) = _state(raw);
    if (!_validName.hasMatch(name)) return null;
    if (!states.contains(name)) states.add(name);
    if (marks && isStart) start ??= name;
    if (marks && isAccept) accepting.add(name);
    return name;
  }

  final lines = text.split('\n');
  for (var n = 0; n < lines.length; n++) {
    var line = lines[n].replaceFirst(RegExp(r'\s*(?:#|//).*$'), '').trim();
    if (line.isEmpty) continue;
    final head = RegExp(r'^(start|initial|begin|accept|accepts|accepting|final|finals)\s*[:=]?\s+(.*)$', caseSensitive: false).firstMatch(line) ??
        RegExp(r'^(start|initial|begin|accept|accepts|accepting|final|finals)\s*:\s*(.*)$', caseSensitive: false).firstMatch(line);
    if (head != null && !_arrow.hasMatch(line)) {
      final isStart = RegExp('^(start|initial|begin)', caseSensitive: false).hasMatch(head.group(1)!);
      var bad = false;
      for (final piece in _commaList(head.group(2)!)) {
        final name = declare(piece, marks: false);
        if (name == null) {
          bad = true;
          continue;
        }
        if (isStart) {
          start ??= name;
        } else {
          accepting.add(name);
        }
      }
      if (bad) problems.add('line ${n + 1}: $line');
      continue;
    }
    final arrows = _arrow.allMatches(line).toList();
    if (arrows.isEmpty) {
      // a state on its own (with marks), or several with commas
      var bad = false;
      for (final piece in _commaList(line)) {
        if (declare(piece) == null) bad = true;
      }
      if (bad) problems.add('line ${n + 1}: $line');
      continue;
    }
    // `a -x-> b : labels`
    String? tail;
    final colon = line.lastIndexOf(':');
    if (colon > arrows.last.end - 1 && arrows.length == 1) {
      tail = line.substring(colon + 1);
      line = line.substring(0, colon);
    }
    final arrowsHere = _arrow.allMatches(line).toList();
    final names = <String>[];
    var from = 0;
    var bad = false;
    for (final m in arrowsHere) {
      final name = declare(line.substring(from, m.start));
      if (name == null) bad = true;
      names.add(name ?? '');
      from = m.end;
    }
    final last = declare(line.substring(from));
    if (last == null) bad = true;
    names.add(last ?? '');
    if (bad) {
      problems.add('line ${n + 1}: $line');
      continue;
    }
    for (var i = 0; i < arrowsHere.length; i++) {
      final label = tail != null && arrowsHere[i].group(1)!.trim().isEmpty ? tail : arrowsHere[i].group(1)!;
      final key = (names[i], names[i + 1]);
      if (!edges.containsKey(key)) order.add(key);
      final list = edges.putIfAbsent(key, () => []);
      for (final s in _symbols(label)) {
        if (!list.contains(s)) list.add(s);
      }
    }
  }
  final automaton = Automaton(states, start, accepting, [for (final k in order) Transition(k.$1, k.$2, edges[k]!)]);
  return AutomatonReading(automaton, problems);
}

// ---- running a word ----

/// What a word does to an automaton: the states it is in after each symbol.
class AutomatonRun {
  final List<String> tokens;

  /// The states before the first symbol and after each one.
  final List<Set<String>> sets;

  /// Whether the word is accepted.
  final bool accepted;

  /// The number of symbols read before there was nowhere to go (null when it never got stuck).
  final int? stuckAfter;

  const AutomatonRun(this.tokens, this.sets, this.accepted, this.stuckAfter);
}

/// The symbols of [word]: the characters when the alphabet is single characters, else the parts between spaces.
List<String> wordTokens(Automaton a, String word) {
  final w = word.trim();
  if (w.isEmpty || _epsilonNames.hasMatch(w)) return const [];
  if (a.alphabet.every((s) => s.length == 1)) return [for (final r in w.replaceAll(RegExp(r'\s+'), '').runes) String.fromCharCode(r)];
  return w.split(RegExp(r'\s+'));
}

/// Runs [word] through [a]. Null when there is no start state.
AutomatonRun? runWord(Automaton a, String word) {
  if (a.start == null) return null;
  final tokens = wordTokens(a, word);
  var now = a.closure({a.start!});
  final sets = [now];
  int? stuck;
  for (var i = 0; i < tokens.length; i++) {
    now = a.move(now, tokens[i]);
    sets.add(now);
    if (now.isEmpty) {
      stuck = i + 1;
      break;
    }
  }
  final accepted = stuck == null && now.any(a.accepting.contains);
  return AutomatonRun(tokens, sets, accepted, stuck);
}

/// The shortest words that [a] accepts (at most [count] of them, none longer than [longest]); the empty word is `ε`.
List<String> acceptedWords(Automaton a, {int count = 6, int longest = 8}) {
  if (a.start == null) return const [];
  final out = <String>[];
  final alphabet = a.alphabet;
  var layer = <(List<String>, Set<String>)>[([], a.closure({a.start!}))];
  for (var len = 0; len <= longest && out.length < count && layer.isNotEmpty; len++) {
    for (final (word, set) in layer) {
      if (set.any(a.accepting.contains)) {
        out.add(word.isEmpty ? epsilon : (alphabet.every((s) => s.length == 1) ? word.join() : word.join(' ')));
        if (out.length >= count) return out;
      }
    }
    final next = <(List<String>, Set<String>)>[];
    final seen = <String>{};
    for (final (word, set) in layer) {
      for (final c in alphabet) {
        final m = a.move(set, c);
        if (m.isEmpty) continue;
        // (a word is only worth following if it leads somewhere new for this length)
        final key = '${word.join('\u0000')}\u0001$c';
        if (seen.add(key) && next.length < 400) next.add(([...word, c], m));
      }
    }
    layer = next;
  }
  return out;
}

// ---- making it deterministic and small ----

String _setName(Automaton a, Iterable<String> set) {
  final ordered = [for (final s in a.states) if (set.contains(s)) s];
  return '{${ordered.join(',')}}';
}

/// The deterministic automaton for [a] (the subset construction, with the empty word taken in). States that cannot be left to an accepting state
/// are kept; the empty set is not a state (a missing arrow is a dead end).
Automaton toDeterministic(Automaton a) {
  if (a.start == null || a.isDeterministic) return a;
  final alphabet = a.alphabet;
  final first = a.closure({a.start!});
  final names = <String, Set<String>>{_setName(a, first): first};
  final order = [_setName(a, first)];
  final transitions = <Transition>[];
  for (var i = 0; i < order.length; i++) {
    final from = order[i];
    final set = names[from]!;
    final targets = <String, List<String>>{};
    for (final c in alphabet) {
      final m = a.move(set, c);
      if (m.isEmpty) continue;
      final name = _setName(a, m);
      if (!names.containsKey(name)) {
        names[name] = m;
        order.add(name);
      }
      targets.putIfAbsent(name, () => []).add(c);
    }
    for (final e in targets.entries) {
      transitions.add(Transition(from, e.key, e.value));
    }
  }
  return Automaton(order, order.first, {for (final n in order) if (names[n]!.any(a.accepting.contains)) n}, transitions);
}

/// The smallest deterministic automaton for the language of [a] (without the dead state): [a] is made deterministic first, then states that
/// no word can tell apart are made one.
Automaton minimize(Automaton a) {
  if (a.start == null) return a;
  final d = toDeterministic(a);
  final reach = d.reachable;
  final states = [for (final s in d.states) if (reach.contains(s)) s];
  const dead = '∅';
  final alphabet = d.alphabet;
  String next(String s, String c) => s == dead ? dead : (d.step(s, c).firstOrNull ?? dead);
  final all = [...states, dead];
  // start with accepting / not, and split until no class splits any more
  var cls = {for (final s in all) s: d.accepting.contains(s) ? 1 : 0};
  while (true) {
    final signature = {for (final s in all) s: '${cls[s]}|${[for (final c in alphabet) cls[next(s, c)]].join(',')}'};
    final ids = <String, int>{};
    final renamed = {for (final s in all) s: ids.putIfAbsent(signature[s]!, () => ids.length)};
    if (ids.length == cls.values.toSet().length) {
      cls = renamed;
      break;
    }
    cls = renamed;
  }
  final liveClasses = <int>{};
  // the classes that can still reach an accepting class
  final accepting = {for (final s in states) if (d.accepting.contains(s)) cls[s]!};
  liveClasses.addAll(accepting);
  var changed = true;
  while (changed) {
    changed = false;
    for (final s in states) {
      for (final c in alphabet) {
        if (liveClasses.contains(cls[next(s, c)]) && liveClasses.add(cls[s]!)) changed = true;
      }
    }
  }
  final startClass = cls[d.start!]!;
  final keep = {...liveClasses, startClass};
  final members = <int, List<String>>{};
  for (final s in states) {
    if (keep.contains(cls[s])) members.putIfAbsent(cls[s]!, () => []).add(s);
  }
  // (a language with no words: the start alone stands for everything)
  if (!liveClasses.contains(startClass)) members[startClass] = [d.start!];
  String nameOf(int k) {
    final m = members[k]!;
    return m.length == 1 ? m.first : '{${m.join(',')}}';
  }

  final ordered = members.keys.toList();
  final transitions = <Transition>[];
  for (final k in ordered) {
    final rep = members[k]!.first;
    final targets = <int, List<String>>{};
    for (final c in alphabet) {
      final t = cls[next(rep, c)]!;
      if (!keep.contains(t) || !members.containsKey(t)) continue;
      targets.putIfAbsent(t, () => []).add(c);
    }
    for (final e in targets.entries) {
      transitions.add(Transition(nameOf(k), nameOf(e.key), e.value));
    }
  }
  return Automaton([for (final k in ordered) nameOf(k)], nameOf(startClass), {for (final k in ordered) if (accepting.contains(k)) nameOf(k)}, transitions);
}

// ---- what is worth telling ----

/// Things to tell about [a], as lines for the person to read.
class AutomatonFacts {
  /// "DFA", "NFA" or "NFA with ε moves".
  final String kind;
  final List<String> alphabet;
  final int states;
  final int transitions;

  /// Whether every state has a way on every symbol.
  final bool complete;
  final List<String> unreachable;

  /// States from which no accepting state can be reached.
  final List<String> dead;
  final List<String> warnings;

  const AutomatonFacts(this.kind, this.alphabet, this.states, this.transitions, this.complete, this.unreachable, this.dead, this.warnings);
}

AutomatonFacts factsOf(Automaton a) {
  final warnings = <String>[];
  if (a.start == null && !a.isEmpty) warnings.add('no start state (write start: q0 or >q0)');
  if (a.accepting.isEmpty && !a.isEmpty) warnings.add('no accepting state (write accept: q1 or *q1)');
  final reach = a.reachable;
  final live = a.live;
  final kind = a.hasEpsilon ? 'NFA with ε moves' : (a.isDeterministic ? 'DFA' : 'NFA');
  return AutomatonFacts(
    kind,
    a.alphabet,
    a.states.length,
    a.transitions.length,
    a.missing.isEmpty,
    a.start == null ? const [] : [for (final s in a.states) if (!reach.contains(s)) s],
    [for (final s in a.states) if (!live.contains(s) && (a.start == null || reach.contains(s))) s],
    warnings,
  );
}
