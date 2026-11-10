import 'package:flutter_test/flutter_test.dart';
import 'package:notes/util/whole_number.dart';

void main() {
  test('a whole number read from the database is an int, also when a browser hands it over as a BigInt', () {
    expect(wholeNumber(42), 42);
    expect(wholeNumber(BigInt.from(42)), 42);
    expect(wholeNumber(7.0), 7);
    // (the 63-bit hash of a text, as a browser's SQLite returns it)
    expect(wholeNumber(BigInt.parse('6953806985881854123')), BigInt.parse('6953806985881854123').toInt());
    expect(() => wholeNumber('7'), throwsA(isA<TypeError>()));
    expect(() => wholeNumber(null), throwsA(isA<TypeError>()));
  });
}
