import 'package:flutter_test/flutter_test.dart';
import 'package:notes/diagram/automaton.dart';

Automaton parse(String text) => parseAutomaton(text).automaton;

const evenAs = '''
start: q0
accept: q0
q0 -a-> q1
q1 -a-> q0
q0 -b-> q0
q1 -b-> q1
''';

void main() {
  group('reading', () {
    test('states, marks and transitions', () {
      final a = parse(evenAs);
      expect(a.states, ['q0', 'q1']);
      expect(a.start, 'q0');
      expect(a.accepting, {'q0'});
      expect(a.alphabet, ['a', 'b']);
      expect(a.transitions.length, 4);
    });

    test('the marks can be written at the states', () {
      final a = parse('>q0 -a-> q1\nq1 -b-> *q2\n((q3))');
      expect(a.start, 'q0');
      expect(a.accepting, {'q2', 'q3'});
      expect(a.states, ['q0', 'q1', 'q2', 'q3']);
    });

    test('several ways to write an arrow', () {
      final a = parse('q0 --a,b--> q1\nq1 -> q2 : c\nq2 -ε-> q0\nq0 -> q2\nq1 -eps-> q1');
      expect(a.step('q0', 'a'), {'q1'});
      expect(a.step('q0', 'b'), {'q1'});
      expect(a.step('q1', 'c'), {'q2'});
      expect(a.step('q2', epsilon), {'q0'});
      expect(a.step('q0', epsilon), {'q2'}); // (no label: the empty word)
      expect(a.step('q1', epsilon), {'q1'});
    });

    test('a chain on one line', () {
      final a = parse('q0 -a-> q1 -b-> q2 -c-> q0');
      expect(a.transitions.map((t) => '${t.from}${t.symbols.join()}${t.to}').toList(), ['q0aq1', 'q1bq2', 'q2cq0']);
    });

    test('several symbols on one pair of states are merged', () {
      final a = parse('q0 -a-> q1\nq0 -b-> q1\nq0 -a-> q1');
      expect(a.transitions.length, 1);
      expect(a.transitions.single.symbols, ['a', 'b']);
    });

    test('comments, blank lines, subset names, and what cannot be read', () {
      final r = parseAutomaton('# a machine\n\nstart: {q0,q1}  // here\naccept: {q0,q1}, q2\n{q0,q1} -a-> q2\nq2 a b c\nwhat is this -> ?');
      expect(r.automaton.start, '{q0,q1}');
      expect(r.automaton.accepting, {'{q0,q1}', 'q2'});
      expect(r.automaton.step('{q0,q1}', 'a'), {'q2'});
      expect(r.problems.length, 2);
      expect(r.problems.first, startsWith('line 6'));
    });

    test('nothing at all', () {
      final r = parseAutomaton('  \n# only a comment');
      expect(r.automaton.isEmpty, isTrue);
      expect(r.problems, isEmpty);
    });

    test('written out and read again it is the same machine', () {
      final a = parse('>q0 -a,b-> q1\nq1 -ε-> *q2\nq2 -a-> q2\nq3');
      final b = parse(a.toText());
      expect(b.states.toSet(), a.states.toSet());
      expect(b.start, a.start);
      expect(b.accepting, a.accepting);
      expect([for (final t in b.transitions) '${t.from}|${t.symbols.join(',')}|${t.to}'], [for (final t in a.transitions) '${t.from}|${t.symbols.join(',')}|${t.to}']);
    });
  });

  group('words', () {
    test('a deterministic machine', () {
      final a = parse(evenAs);
      expect(runWord(a, 'aa')!.accepted, isTrue);
      expect(runWord(a, 'abba')!.accepted, isTrue);
      expect(runWord(a, 'ab')!.accepted, isFalse);
      expect(runWord(a, '')!.accepted, isTrue);
      expect(runWord(a, 'ε')!.accepted, isTrue);
      expect(runWord(a, 'aba')!.sets.map((s) => s.single).toList(), ['q0', 'q1', 'q1', 'q0']);
    });

    test('a word that gets stuck', () {
      final a = parse('start: q0\naccept: q1\nq0 -a-> q1');
      final run = runWord(a, 'ab')!;
      expect(run.accepted, isFalse);
      expect(run.stuckAfter, 2);
      expect(runWord(a, 'a')!.accepted, isTrue);
      expect(runWord(a, 'b')!.stuckAfter, 1);
    });

    test('a machine with choices and empty moves', () {
      // ends in "ab", with an ε move into the start of the tail
      final a = parse('>q0 -a,b-> q0\nq0 -a-> q1\nq1 -b-> *q2');
      expect(a.isDeterministic, isFalse);
      expect(runWord(a, 'aab')!.accepted, isTrue);
      expect(runWord(a, 'aba')!.accepted, isFalse);
      expect(runWord(a, 'aab')!.sets.last, {'q0', 'q2'});
      final e = parse('>s -ε-> p\np -a-> *f');
      expect(runWord(e, 'a')!.accepted, isTrue);
      expect(runWord(e, '')!.accepted, isFalse);
    });

    test('longer symbols are separated by spaces', () {
      final a = parse('>s -ab-> *t');
      expect(runWord(a, 'ab')!.accepted, isTrue);
      expect(runWord(a, 'ab ab')!.accepted, isFalse);
    });

    test('no start state', () {
      expect(runWord(parse('q0 -a-> q1'), 'a'), isNull);
    });

    test('the shortest accepted words', () {
      expect(acceptedWords(parse(evenAs), count: 5), ['ε', 'b', 'aa', 'bb', 'aab']);
      expect(acceptedWords(parse('>q0 -a-> q1'), count: 3), isEmpty);
      expect(acceptedWords(parse('>q0 -a-> *q1'), count: 3), ['a']);
    });
  });

  group('facts', () {
    test('DFA, NFA, complete, dead ends', () {
      final dfa = factsOf(parse(evenAs));
      expect(dfa.kind, 'DFA');
      expect(dfa.complete, isTrue);
      expect(dfa.unreachable, isEmpty);
      final partial = factsOf(parse('>q0 -a-> *q1\nq2 -a-> q0'));
      expect(partial.kind, 'DFA');
      expect(partial.complete, isFalse);
      expect(partial.unreachable, ['q2']);
      expect(factsOf(parse('>q0 -a-> q0\nq0 -a-> *q1')).kind, 'NFA');
      expect(factsOf(parse('>q0 -ε-> *q1')).kind, 'NFA with ε moves');
      expect(factsOf(parse('>q0 -a-> q1\nq1 -a-> q1\nq0 -b-> *q2')).dead, ['q1']);
    });

    test('what is missing is told', () {
      expect(factsOf(parse('q0 -a-> q1')).warnings, ['no start state (write start: q0 or >q0)', 'no accepting state (write accept: q1 or *q1)']);
      expect(factsOf(parse('>q0 -a-> *q1')).warnings, isEmpty);
    });
  });

  group('deterministic and minimal', () {
    bool sameLanguage(Automaton x, Automaton y, {int length = 7}) {
      final alphabet = {...x.alphabet, ...y.alphabet}.toList();
      var words = <String>[''];
      for (var n = 0; n <= length; n++) {
        for (final w in words) {
          if (runWord(x, w)!.accepted != runWord(y, w)!.accepted) return false;
        }
        words = [for (final w in words) for (final c in alphabet) '$w$c'];
      }
      return true;
    }

    test('the subset construction', () {
      final nfa = parse('>q0 -a,b-> q0\nq0 -a-> q1\nq1 -b-> *q2');
      final dfa = toDeterministic(nfa);
      expect(dfa.isDeterministic, isTrue);
      expect(dfa.start, '{q0}');
      expect(dfa.states, ['{q0}', '{q0,q1}', '{q0,q2}']);
      expect(dfa.accepting, {'{q0,q2}'});
      expect(sameLanguage(nfa, dfa), isTrue);
    });

    test('empty moves are taken in', () {
      final nfa = parse('>s -ε-> p\np -a-> q\nq -ε-> *f\nf -b-> p');
      final dfa = toDeterministic(nfa);
      expect(dfa.hasEpsilon, isFalse);
      expect(sameLanguage(nfa, dfa), isTrue);
    });

    test('a machine that is deterministic already stays as it is when minimised', () {
      final m = minimize(parse(evenAs));
      expect(m.states.length, 2);
      expect(sameLanguage(parse(evenAs), m), isTrue);
    });

    test('equal states are made one', () {
      // a DFA for "ends in a" with a redundant copy of each state
      final big = parse('>s0 -a-> s1\ns0 -b-> s2\ns1 -a-> s3\ns1 -b-> s2\ns2 -a-> s1\ns2 -b-> s2\ns3 -a-> s3\ns3 -b-> s2\naccept: s1, s3');
      final m = minimize(big);
      expect(m.states.length, 2);
      expect(m.states.any((s) => s.startsWith('{')), isTrue);
      expect(sameLanguage(big, m), isTrue);
      expect(m.isDeterministic, isTrue);
    });

    test('unreachable and dead states go', () {
      final m = minimize(parse('>q0 -a-> *q1\nq1 -a-> q2\nq2 -a-> q2\nx -a-> q0'));
      expect(m.states, ['q0', 'q1']);
      expect(m.transitions.length, 1);
    });

    test('an NFA is minimised through the DFA', () {
      final nfa = parse('>q0 -a,b-> q0\nq0 -a-> q1\nq1 -a,b-> *q2');
      final m = minimize(nfa);
      expect(m.states.length, 4); // "a in the second place from the end" needs four states
      expect(sameLanguage(nfa, m), isTrue);
    });

    test('a language with no words', () {
      final m = minimize(parse('>q0 -a-> q1\nq1 -a-> q0'));
      expect(m.states, ['q0']);
      expect(m.accepting, isEmpty);
    });
  });
}
