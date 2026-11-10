import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/history/version_diff.dart';

int lcs(List<String> a, List<String> b) {
  final t = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1]);
    }
  }
  return t[0][0];
}

void check(List<String> a, List<String> b, List<int> m) {
  expect(m, hasLength(b.length));
  var last = -1;
  for (var j = 0; j < b.length; j++) {
    if (m[j] < 0) continue;
    expect(a[m[j]], b[j]);
    expect(m[j], greaterThan(last)); // in order, each line of a once
    last = m[j];
  }
}

void main() {
  test('the lines that stayed are the longest run in order', () {
    final rnd = Random(1);
    for (var k = 0; k < 300; k++) {
      final a = [for (var i = 0; i < rnd.nextInt(30); i++) 'l${rnd.nextInt(8)}'];
      final b = [for (var i = 0; i < rnd.nextInt(30); i++) 'l${rnd.nextInt(8)}'];
      final m = matchLines(a, b);
      check(a, b, m);
      expect(m.where((i) => i >= 0).length, lcs(a, b));
    }
  });

  test('a long text written over is matched in order without a table of all its pairs', () {
    final a = [for (var i = 0; i < 30000; i++) 'old $i'];
    final b = [for (var i = 0; i < 30000; i++) i % 100 == 0 ? 'old $i' : 'new $i'];
    final m = matchLines(a, b);
    check(a, b, m);
    expect(m.where((i) => i >= 0).length, 300);
  });
}
