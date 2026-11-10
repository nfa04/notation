import 'dart:math' as math;
import 'dart:typed_data';

import '../ai/ai_prompt.dart';
import '../ai/ai_service.dart';
import '../ai/document_index.dart';
import '../ai/note_knowledge.dart';
import '../ai/text_provider.dart';
import '../automations/note_sorter.dart';
import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../llm/embedding_service.dart';
import 'graph_builder.dart';

/// Stands in for the sentence model when it is not installed: a hashed bag of words, so that texts that share their telling words
/// are close. The graph is made from it all the same, only lexical.
class LexicalEmbedder implements TextEmbedder {
  const LexicalEmbedder();

  static const dimensions = 256;

  @override
  String get modelId => 'lexical';

  @override
  Future<Float32List> embed(String text) async {
    final v = Float32List(dimensions);
    final counts = <String, int>{};
    for (final w in telltaleWords(text)) {
      final stem = w.length > 6 ? w.substring(0, 6) : w;
      counts[stem] = (counts[stem] ?? 0) + 1;
    }
    for (final e in counts.entries) {
      final h = NoteSorter.hashOf(e.key);
      v[h % dimensions] += (h >> 20).isEven ? 1 + math.log(e.value) : -(1 + math.log(e.value));
    }
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var i = 0; i < v.length; i++) {
        v[i] /= norm;
      }
    }
    return v;
  }
}

/// Words a fact must not lean on: it has to stand on its own, as a flashcard does (OpenKnowledgeBase's "Protocol B").
final _dependsOnContext = RegExp(
  r'^(it|they|this|these|those|he|she|its|their|er|sie|es|dies|diese[rsmn]?)\b|\b(the slide|this slide|this example|as seen|as shown|in the previous|next slide|folie|beispiel zeigt)\b',
  caseSensitive: false,
);

typedef ParsedFact = ({String title, String tag, String sentence, List<String> keywords});

/// The facts the model wrote, in `Title | Tag | Sentence | keyword, keyword` lines. A line that does not have the form, a fact that
/// needs the text around it to be understood, and a repeat are left out.
List<ParsedFact> parseFacts(String text) {
  const tags = {'fact', 'explanation', 'data', 'method', 'result', 'claim', 'definition'};
  final out = <ParsedFact>[];
  String plain(String s) => s.toLowerCase().replaceAll(RegExp(r'\W+'), ' ');
  for (final raw in text.split('\n')) {
    final line = raw.trim().replaceAll('**', '').replaceFirst(RegExp(r'^([-*•]|\d+[.)])\s*'), '');
    final parts = line.split('|').map((p) => p.trim()).toList();
    if (parts.length < 3) continue;
    final title = parts[0], sentence = parts[2];
    if (title.isEmpty || sentence.length < 25 || title.length > 90 || title.toLowerCase() == 'title') continue;
    if (_dependsOnContext.hasMatch(sentence)) continue;
    final tag = tags.contains(parts[1].toLowerCase()) ? parts[1][0].toUpperCase() + parts[1].substring(1).toLowerCase() : 'Fact';
    final keywords = parts.length > 3 ? parts[3].split(RegExp(r'[,;]')).map((k) => k.trim()).where((k) => k.isNotEmpty && k.length < 40).take(8).toList() : <String>[];
    if (!out.any((f) => plain(f.sentence) == plain(sentence) || plain(f.title) == plain(title))) {
      out.add((title: title, tag: tag, sentence: sentence, keywords: keywords));
    }
  }
  return out;
}

/// What the person is told when there is no model to write the facts.
String get noFactWriterMessage => tr('Writing the facts needs an AI model: set one up in the Settings (on this device, or a service), or choose another one with the arrows above.');

/// Takes the facts out of the notes and keeps them (with a vector each), a note at a time and only when its text changed. A model
/// writes them - what a fact is, is decided by the prompt (see [system]), which follows the one of OpenKnowledgeBase. Without a
/// model there are none: pieces of the slides are not facts.
class FactExtractor {
  final NoteRepository _notes;
  final AiService? ai;
  final TextEmbedder embedder;

  FactExtractor(this._notes, this.embedder, {this.ai});

  /// What `fact_state.extractor` says of facts written with this prompt (a different prompt is a different version).
  static const version = 'llm2';

  /// How many times a window the model gave nothing usable for is asked again.
  static const retries = 2;

  /// The standing instructions: OpenKnowledgeBase's extraction prompt, with the answer in lines (small models keep to lines better
  /// than to JSON).
  static const system = '''You are an Ontological Knowledge Extractor: you turn messy, fragmented university slides and notes into atomic, abstract knowledge items. Every item must be an abstract, universally true academic principle, severed from the original document's context, order and examples.

Leave out every visual formatting of the source (bullets, page numbers, strings of dots or dashes).

1. WHAT TO EXTRACT. Only: definitions (what is X?), mechanisms and processes (how does X work?), causal relationships (why does X happen, what does it cause?), rules, axioms and formulas, categorizations (the types of X).

2. WHAT TO IGNORE. Pedagogical fluff ("Agenda", "Today we will cover", "Let's review", "Summary", "Questions?"). Situational examples and hard-coded numbers that only illustrate a rule: extract the abstract rule itself. Relative pointers ("as seen on the next slide", "refer to theorem 3", "in the previous lecture"). Page numbers and other artifacts.

3. HOW TO WRITE IT.
- Title: 2 to 5 words, an exact index key in the form "Parent Concept: Specific Mechanism". Bad: "Heaps", "Memory". Good: "Heaps: Swim Function Mechanics", "Operating Systems: Paging vs. Segmentation".
- Sentence: a standalone, abstract truth that is understood with no other context, like a flashcard. No pronouns ("it", "they") and no reference to the text ("the slide says", "this example shows"): use the noun. Bad: "It restores order by swapping with the parent." Good: "The Swim function restores the heap property by iteratively swapping a newly inserted node with its parent until the parent's value is larger."
- If one concept is spread over several fragmented bullet points, write it as one cohesive fact, not as fragments.
- Keep the language of the source (German stays German). Write mathematics in LaTeX (\$x^2\$).
- Tag: one of Fact, Explanation, Data, Method, Result, Claim.
- Keywords: 2 to 8 words to index the fact by.

4. THE ANSWER. One item per line, exactly in this form, and nothing else (no introduction, no numbering):
Title | Tag | Sentence | keyword, keyword, keyword
If the text has nothing worth extracting, answer with an empty line.

Example. Input: "Slide 14: Heaps - Today we look at the swim function - How does it work? - It fixes the heap if a new node is too big - Example: we insert 15 into [10, 8, 5]. 15 is larger than 10, so they swap. - See chapter 4 for proofs. ........"
Answer: Heaps: Swim Function Purpose | Method | The Swim function restores the heap property when a newly inserted node is larger than its parent by swapping their positions. | heap, swim, insertion, heap property''';

  /// The length of a window of a note given to the model at once (characters), after what the provider can read: about 800 tokens
  /// for a small model on the device (as OpenKnowledgeBase uses), more for a service.
  int get windowLength {
    final p = ai?.provider;
    final context = p is ContextSized ? (p as ContextSized).contextChars : 3500;
    return (context ~/ 2).clamp(1600, 4800);
  }

  /// The most windows of one note that are read.
  static const maxWindows = 40;

  /// Whether a model that can write facts is there now.
  bool get canWrite => ai?.provider?.state == ProviderState.ready;

  /// How many windows the model gave nothing usable for in the runs of this extractor (after the retries).
  int unreadWindows = 0;

  /// Makes the facts of note [id] now unless they are up to date. Returns how many there are. Throws when there is no model.
  Future<int> extract(String id, {AiCancel? cancel}) async {
    final chunks = await chunksOfNote(_notes, id);
    final text = chunks.map((c) => c.text).join('\n');
    final hash = NoteSorter.hashOf(text);
    final state = await _notes.knowledge.factState(id);
    if (state != null && state.textHash == hash && state.model == embedder.modelId && state.extractor == version) {
      return (await _notes.knowledge.allFacts()).where((f) => f.noteId == id).length;
    }
    final provider = ai?.provider;
    if (provider == null || provider.state != ProviderState.ready) throw StateError(noFactWriterMessage);
    final facts = <StoredFact>[];
    if (text.trim().length >= NoteSorter.minText) {
      final big = provider is ContextSized && (provider as ContextSized).contextChars > 20000;

      Future<List<ParsedFact>> read(({String text, int? page}) w) async {
        var found = <ParsedFact>[];
        for (var attempt = 0; attempt <= retries && found.isEmpty; attempt++) {
          if (cancel?.cancelled ?? false) return found;
          try {
            final answer = await provider.complete(AiPrompt(system: system, user: 'DOCUMENT:\n${w.text}', exact: true), maxTokens: big ? 1500 : 700, cancel: cancel);
            found = parseFacts(answer);
            if (answer.trim().isEmpty) break; // nothing to take out of this window: not an error
          } catch (e) {
            if (attempt == retries && e is StateError) rethrow; // (the provider itself cannot answer)
          }
        }
        if (found.isEmpty) unreadWindows++;
        return found;
      }

      final windows = [for (final w in _windows(chunks)) if (w.text.trim().length >= 40) w];
      // a service answers several requests at once (the model on the device takes one at a time anyway)
      final batch = big ? 3 : 1;
      for (var i = 0; i < windows.length; i += batch) {
        final part = windows.sublist(i, math.min(windows.length, i + batch));
        final results = await Future.wait([for (final w in part) read(w)]);
        for (var k = 0; k < part.length; k++) {
          for (final f in results[k]) {
            if (!facts.any((o) => o.title.toLowerCase() == f.title.toLowerCase() || o.sentence == f.sentence)) {
              facts.add(StoredFact(noteId: id, page: part[k].page, title: f.title, tag: f.tag, sentence: f.sentence, keywords: f.keywords));
            }
          }
        }
      }
    }
    if (cancel?.cancelled ?? false) return 0;
    // like OpenKnowledgeBase, a fact is placed by its keywords (its title when it has none)
    final withVectors = [
      for (final f in facts)
        StoredFact(
            noteId: f.noteId,
            page: f.page,
            title: f.title,
            tag: f.tag,
            sentence: f.sentence,
            keywords: f.keywords,
            vector: await embedder.embed(f.keywords.isEmpty ? f.title : f.keywords.join(' '))),
    ];
    await _notes.knowledge.replaceFacts(id, hash, embedder.modelId, version, withVectors);
    return withVectors.length;
  }

  /// The note in windows of about [windowLength] characters, cut at the end of a page (a slide) or a passage where it can be; a
  /// long passage is cut at its sentences. A very long note is read as an even spread of its windows.
  List<({String text, int? page})> _windows(List<DocChunk> chunks) {
    final max = windowLength;
    final windows = <({String text, int? page})>[];
    var buffer = StringBuffer();
    int? page;
    void flush() {
      if (buffer.length > 0) windows.add((text: buffer.toString().trim(), page: page));
      buffer = StringBuffer();
      page = null;
    }

    void add(String piece, int? at) {
      if (buffer.length + piece.length + 1 > max) flush();
      if (buffer.length == 0) page = at;
      if (buffer.length > 0) buffer.write('\n');
      buffer.write(piece);
    }

    for (final c in chunks) {
      if (c.text.length <= max) {
        add(c.text, c.page);
      } else {
        for (final sentence in c.text.split(RegExp(r'(?<=[.!?])\s+'))) {
          add(sentence.length > max ? sentence.substring(0, max) : sentence, c.page);
        }
      }
    }
    flush();
    if (windows.length <= maxWindows) return windows;
    final step = windows.length / maxWindows;
    return [for (var i = 0; i < maxWindows; i++) windows[(i * step).floor()]];
  }
}
