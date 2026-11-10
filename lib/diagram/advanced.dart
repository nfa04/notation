import 'automaton.dart';
import 'automaton_layout.dart';
import 'diagram_layout.dart';
import 'graph.dart';
import 'graph_layout.dart';
import 'tree.dart';
import 'tree_layout.dart';

/// What a diagram is made from: an outline or lines with arrows (a mind map or a flowchart, see `diagram.dart`), or one of the advanced
/// kinds for computer science: a state diagram, a tree, a graph.
enum DiagramMode { simple, automaton, tree, graph }

/// What an advanced diagram makes of its text: the picture, what could not be read, and what is worth telling about it.
class AdvancedDiagram {
  final DiagramLayout layout;

  /// Lines of the text that were not understood.
  final List<String> problems;

  /// What to tell, as (name, value) pairs.
  final List<(String, String)> facts;

  const AdvancedDiagram(this.layout, this.problems, this.facts);

  bool get isEmpty => layout.isEmpty;
}

/// The options of the advanced kinds.
class AdvancedOptions {
  /// For a graph: what to show on it.
  final GraphHighlight highlight;

  /// For a search tree: the balance factor beside each node.
  final bool balance;

  const AdvancedOptions({this.highlight = GraphHighlight.none, this.balance = false});
}

/// The diagram of [mode] that [text] describes; [mode] must not be [DiagramMode.simple].
AdvancedDiagram buildAdvanced(DiagramMode mode, String text, {AdvancedOptions options = const AdvancedOptions()}) {
  switch (mode) {
    case DiagramMode.automaton:
      final r = parseAutomaton(text);
      final f = factsOf(r.automaton);
      final facts = r.automaton.isEmpty
          ? const <(String, String)>[]
          : [
              ('Kind', f.kind),
              ('States', '${f.states}'),
              ('Alphabet', f.alphabet.isEmpty ? '—' : f.alphabet.join(', ')),
              if (f.kind == 'DFA') ('Complete', f.complete ? 'yes' : 'no (a missing arrow is a dead end)'),
              if (f.unreachable.isNotEmpty) ('Never reached', f.unreachable.join(', ')),
              if (f.dead.isNotEmpty) ('Dead ends', f.dead.join(', ')),
              if (acceptedWords(r.automaton).isNotEmpty) ('Accepts', acceptedWords(r.automaton).join(', ')),
            ];
      return AdvancedDiagram(layoutAutomaton(r.automaton), [...r.problems, for (final w in f.warnings) w], facts);
    case DiagramMode.tree:
      final r = parseTree(text);
      return AdvancedDiagram(layoutTree(r.tree, balance: options.balance), r.problems, treeFacts(r.tree));
    case DiagramMode.graph:
      final r = parseGraph(text);
      return AdvancedDiagram(layoutGraph(r.graph, highlight: options.highlight), r.problems, graphFacts(r.graph));
    case DiagramMode.simple:
      throw ArgumentError('simple diagrams are made by parseDiagram');
  }
}

/// A text to start from for [mode].
String exampleFor(DiagramMode mode, {int variant = 0}) => switch (mode) {
      DiagramMode.simple => '',
      DiagramMode.automaton => const [
          '# a word with an even number of a\nstart: q0\naccept: q0\nq0 -a-> q1\nq1 -a-> q0\nq0 -b-> q0\nq1 -b-> q1',
          '# an NFA: the last but one symbol is a\n>q0 -a,b-> q0\nq0 -a-> q1\nq1 -a,b-> *q2',
        ][variant % 2],
      DiagramMode.tree => const [
          'bst: 8 3 10 1 6 14 4 7 13',
          'avl: 1 2 3 4 5 6 7',
          'minheap: 5 3 8 1 9 2',
          'A(B(D,E),C(,F))',
        ][variant % 4],
      DiagramMode.graph => const [
          'A -4- B\nA -1- C\nC -2- B\nB -5- D\nC -8- D\nD -3- E\nstart: A',
          'shirt -> tie -> jacket\ntrousers -> belt -> jacket\ntrousers -> shoes\nsocks -> shoes',
        ][variant % 2],
    };
