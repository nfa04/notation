import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/note_data.dart';
import 'package:notes/graph/echoes.dart';

StoredFact fact(String note, String title, List<String> keywords, {int? page}) =>
    StoredFact(noteId: note, title: title, sentence: 'x' * 30, keywords: keywords, page: page);

void main() {
  final facts = [
    fact('linalg', 'Eigenvalues of a matrix', ['eigenvalue', 'characteristic polynomial', 'determinant'], page: 3),
    fact('linalg', 'Orthogonal matrices', ['orthogonal', 'transpose'], page: 5),
    fact('graphs', 'Spanning trees', ['spanning tree', 'minimum cost', 'determinant']),
    fact('cooking', 'Bread', ['yeast', 'flour']),
    fact('a', 'x', ['function']),
    fact('b', 'x', ['function']),
    fact('c', 'x', ['function']),
    fact('d', 'x', ['function']),
  ];
  final index = EchoIndex(facts);

  test('two terms of another note, or a phrase of it, make an echo; the page is where the first term is', () {
    final found = index.find('Today: the characteristic polynomial gives the eigenvalue of the matrix', exceptNote: 'now');
    expect(found.single.noteId, 'linalg');
    expect(found.single.terms, ['characteristic polynomial', 'eigenvalue']);
    expect(found.single.page, 3);
  });

  test('one single word is not enough, a note is never an echo of itself, and a word everything has says nothing', () {
    expect(index.find('the determinant is a number', exceptNote: 'now'), isEmpty, reason: 'one word, and it is in two notes');
    expect(index.find('a Spanning Tree of the graph', exceptNote: 'now').single.noteId, 'graphs', reason: 'a phrase on its own counts, in any case');
    expect(index.find('a spanning tree with minimum cost', exceptNote: 'graphs'), isEmpty);
    expect(index.find('this function is a function of a function', exceptNote: 'now'), isEmpty);
  });

  test('the notes with the most shared terms come first, at most as many as asked for', () {
    final found = index.find('the orthogonal matrix has a transpose, and the eigenvalue and the determinant, a spanning tree too', exceptNote: 'now', max: 2);
    expect(found.map((e) => e.noteId), ['linalg', 'graphs']);
    expect(found.first.terms.length, greaterThan(found.last.terms.length));
    expect(index.find('the orthogonal matrix has a transpose, and the eigenvalue and the determinant, a spanning tree too', exceptNote: 'now', max: 1), hasLength(1));
  });

  test('a word inside another word is not a match; short text and short terms are ignored', () {
    expect(index.find('the transposed orthogonality of eigenvalues', exceptNote: 'now'), isEmpty);
    expect(index.find('yeast', exceptNote: 'now'), isEmpty);
    expect(EchoIndex([fact('n', 'ab', ['xy'])]).isEmpty, isTrue);
    expect(EchoIndex(const []).find('anything at all here', exceptNote: 'x'), isEmpty);
  });
}
