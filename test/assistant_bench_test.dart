// Measures what reaches the model: for questions of the kinds people ask, whether the text that has the answer is among what the
// assistant is given (no model is run; that is tool/assistant_bench). The scores are printed; the expectations are the floor.
//
// The document is made up here (lecture notes of 30 pages, a topic and a fact on each, with the filler real notes have), so nothing
// of anyone's notes is in it.
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/ai/document_index.dart';

const _topics = <(String, String)>[
  ('Photosynthesis', 'Chlorophyll absorbs mostly red and blue light; the Calvin cycle fixes carbon dioxide in the stroma.'),
  ('Cell respiration', 'Glycolysis splits glucose into two pyruvate molecules and yields two ATP.'),
  ('Mitosis', 'During anaphase the sister chromatids are pulled to opposite poles by the spindle.'),
  ('Meiosis', 'Crossing over between homologous chromosomes happens in prophase I.'),
  ('DNA replication', 'Okazaki fragments are joined by DNA ligase on the lagging strand.'),
  ('Transcription', 'RNA polymerase II transcribes protein-coding genes in eukaryotes.'),
  ('Translation', 'The ribosome reads codons in the A site; the start codon is AUG.'),
  ('Enzymes', 'A competitive inhibitor raises the apparent Km but leaves Vmax unchanged.'),
  ('Membranes', 'The sodium-potassium pump moves three sodium ions out and two potassium ions in.'),
  ('Neurons', 'The resting potential of a neuron is about minus seventy millivolts.'),
  ('Synapses', 'Acetylcholine is broken down in the cleft by acetylcholinesterase.'),
  ('Muscle contraction', 'Calcium binds troponin, which moves tropomyosin off the myosin binding sites.'),
  ('Hormones', 'Insulin is released by the beta cells of the pancreas when blood glucose rises.'),
  ('Immune system', 'Antibodies are made by plasma cells, which come from B cells.'),
  ('Evolution', 'Genetic drift has the strongest effect in small populations.'),
  ('Hardy-Weinberg', 'In equilibrium the genotype frequencies are p squared, 2pq and q squared.'),
  ('Ecology', 'Only about ten percent of the energy passes from one trophic level to the next.'),
  ('Nitrogen cycle', 'Rhizobium bacteria in root nodules fix atmospheric nitrogen.'),
  ('Plant hormones', 'Auxin makes the shoot bend toward the light by elongating cells on the shaded side.'),
  ('Genetics', 'A test cross with the homozygous recessive parent reveals an unknown genotype.'),
  ('Sex linkage', 'Red-green colour blindness is inherited on the X chromosome.'),
  ('Biotechnology', 'PCR doubles the target sequence in each cycle of denaturing, annealing and extension.'),
  ('Microbiology', 'Gram-positive bacteria have a thick peptidoglycan wall that keeps the crystal violet stain.'),
  ('Viruses', 'Retroviruses use reverse transcriptase to write their RNA into DNA.'),
  ('Kidney', 'The loop of Henle builds the salt gradient that lets the collecting duct concentrate urine.'),
  ('Heart', 'The sinoatrial node sets the rhythm of the heart beat.'),
  ('Lungs', 'Gas exchange happens by diffusion across the walls of the alveoli.'),
  ('Digestion', 'Bile from the liver emulsifies fats in the small intestine.'),
  ('Exam', 'The final exam takes place on 20 June in room B12; bring a calculator and your student card.'),
  ('Lab safety', 'Goggles must be worn whenever acids are handled in the lab.'),
];

const _filler = 'In this lecture we went through the main ideas step by step and looked at examples from the textbook. '
    'The professor repeated that the details matter for the exercises and that the slides are online. '
    'Students asked several questions at the end, and we agreed to review the hardest part next week.';

DocumentIndex _document() => DocumentIndex([
      for (final (i, (topic, fact)) in _topics.indexed) ...chunkText('Page ${i + 1}', i, '$topic\n\n$_filler\n\n$fact\n\n$_filler'),
    ]);

/// How a question is put to the index; the bench goes through this one door so that what is measured is what the assistant does.
Excerpts _pick(DocumentIndex doc, String question, int budget, {int? currentPage}) =>
    doc.select(question, budget, focus: focusOf(question, currentPage: currentPage, pageCount: doc.pageCount));

int _pagesIn(String text) => RegExp(r'\[Page (\d+)\]').allMatches(text).map((m) => m[1]).toSet().length;

void main() {
  final doc = _document();

  // a question with the words of the text: the fact must be among what is given
  final facts = <(String, int)>[
    ('What does the Calvin cycle fix?', 0),
    ('How many ATP does glycolysis yield?', 1),
    ('When does crossing over happen?', 3),
    ('What joins Okazaki fragments?', 4),
    ('What does a competitive inhibitor do to Km?', 7),
    ('What is the resting potential of a neuron?', 9),
    ('Which cells release insulin?', 12),
    ('What fixes atmospheric nitrogen?', 17),
    ('Where is the final exam?', 28),
    ('When must goggles be worn?', 29),
  ];
  // a question that names a page, or the page the person is on
  final pages = <(String, int?, int)>[
    ('Summarize page 12', null, 11),
    ('What is on p. 25?', null, 24),
    ('Fasse Seite 7 zusammen', null, 6),
    ('Explain this page', 16, 16),
    ('What does this page say about energy?', 16, 16),
  ];
  // a question about the whole document: as many pages as can be given, from all over it
  final whole = ['What are the key points?', 'Summarize this document', 'Give me an overview', 'Was sind die wichtigsten Punkte?', 'What is it about?'];

  for (final budget in [3500, 6000]) {
    test('the right text reaches the model (budget $budget)', () {
      expect(doc.totalChars, greaterThan(budget));
      var factHits = 0;
      for (final (q, page) in facts) {
        if (_pick(doc, q, budget).text.contains(_topics[page].$2)) factHits++;
      }
      var pageHits = 0;
      for (final (q, current, page) in pages) {
        final e = _pick(doc, q, budget, currentPage: current);
        if (e.text.contains(_topics[page].$2) && e.text.contains('[Page ${page + 1}]')) pageHits++;
      }
      final spread = [for (final q in whole) _pagesIn(_pick(doc, q, budget).text)];
      final coverage = spread.reduce((a, b) => a < b ? a : b);
      // and what a page is about, not only its mark: the facts that make it through
      final summary = _pick(doc, whole.first, budget).text;
      final kept = _topics.where((t) => summary.contains(t.$2)).length;
      // ignore: avoid_print
      print('budget $budget: facts $factHits/${facts.length}, named pages $pageHits/${pages.length}, '
          'whole-document questions reach at least $coverage of ${_topics.length} pages ($spread) and keep $kept of the ${_topics.length} facts');
      expect(factHits, facts.length);
      expect(pageHits, pages.length);
      expect(coverage, greaterThanOrEqualTo(budget < 5000 ? 8 : 12));
      expect(kept, greaterThanOrEqualTo(budget < 5000 ? 15 : 25));
    });
  }
}
