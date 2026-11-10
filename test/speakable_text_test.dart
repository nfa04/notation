import 'package:flutter_test/flutter_test.dart';
import 'package:notes/speech/speakable_text.dart';

void main() {
  test('footnote marks, citations, links, formulas and Markdown signs are not read', () {
    expect(speakableText('The cell makes energy.[1] It grows¹ and divides [2, 3] fast.^4'), 'The cell makes energy. It grows and divides fast.');
    expect(speakableText('Proven before (Smith et al., 2019; Jones 2020) in tests.'), 'Proven before in tests.');
    expect(speakableText('# Title\n\n- **bold** and _soft_ with [a link](https://example.org/x) and https://example.org'),
        'Title\n\nbold and soft with a link and');
    expect(speakableText('Energy is \$E = mc^2\$ here.'), 'Energy is here.');
    expect(speakableText('Rest of the text.\n3\nPage 4\n---\nmore text'), 'Rest of the text.\nmore text');
  });

  test('footnote texts and the list of references are left out', () {
    expect(speakableText('Main text.[1]\n\n[1] Smith, J. (2020). A book.\n[^2]: another note'), 'Main text.');
    final long = '${'A sentence of the body. ' * 20}\n\n## References\n\n[1] Somebody. Something.';
    expect(speakableText(long), isNot(contains('Somebody')));
    expect(speakableText('Short text.\n\nReferences\nstays when short'), contains('stays'));
  });

  test('a word split at the end of a line is joined; a plain text is unchanged', () {
    expect(speakableText('an exam-\nple of it'), 'an example of it');
    expect(speakableText('Hello world. How are you?'), 'Hello world. How are you?');
    expect(speakableText('Buy milk [ ] not a footnote'), contains('milk'));
  });
}
