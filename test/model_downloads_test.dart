import 'package:flutter_test/flutter_test.dart';
import 'package:notes/images/subject_service.dart';
import 'package:notes/ink/glm_ocr_service.dart';
import 'package:notes/ink/math_service.dart';
import 'package:notes/llm/model_files.dart';

/// The rule for model downloads (docs/model-downloads.md): a file that we publish ourselves (nfa04 on Hugging Face or GitHub) is pinned
/// by a SHA-256 in the service that downloads it; the files of other publishers follow their `main` branch and are not.
void main() {
  void ownFilesArePinned(String what, ModelFilesService service) {
    for (final e in service.files.entries) {
      if (e.value.url.contains('/nfa04/')) {
        expect(service.checksums, contains(e.key), reason: '$what: ${e.key} is ours (${e.value.url}) and must have a checksum');
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(service.checksums[e.key]!), isTrue, reason: '$what: ${e.key}');
      }
    }
  }

  test('every file of ours that a service downloads is pinned', () {
    for (final w in GlmWeights.values) {
      ownFilesArePinned('handwriting ${w.name}', GlmOcrService(weights: w));
    }
    ownFilesArePinned('subject', SubjectService());
    ownFilesArePinned('formulas', MathService(defaultModel: FormulaModel.texteller));
  });

  test('all the files of the handwriting model are pinned, whichever vision network is chosen', () {
    for (final w in GlmWeights.values) {
      final s = GlmOcrService(weights: w);
      expect(s.files.keys.every((n) => s.checksums.containsKey(n)), isTrue, reason: w.name); // (all three or four files are ours here)
    }
  });
}
