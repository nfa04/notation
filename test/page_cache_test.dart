import 'package:flutter_test/flutter_test.dart';
import 'package:notes/pdf/page_cache.dart';

void main() {
  const mb = 1 << 20;

  test('nothing is dropped while the pages fit', () {
    expect(pagesToDrop({for (var i = 0; i < 50; i++) i: 1 * mb}, near: 25, budget: 100 * mb), isEmpty);
  });

  test('the farthest pages go first, until the rest fit', () {
    final sizes = {for (var i = 0; i < 100; i++) i: 5 * mb}; // 500 MB
    final drop = pagesToDrop(sizes, near: 50, keep: 10, budget: 300 * mb);
    expect(drop.length, 40); // 200 MB over
    final left = sizes.keys.toSet()..removeAll(drop);
    expect(left.fold<int>(0, (a, i) => a + sizes[i]!), lessThanOrEqualTo(300 * mb));
    // (what went is farther from the page in view than everything that stayed)
    final nearestDropped = drop.map((i) => (i - 50).abs()).reduce((a, b) => a < b ? a : b);
    final farthestLeft = left.map((i) => (i - 50).abs()).reduce((a, b) => a > b ? a : b);
    expect(nearestDropped, greaterThanOrEqualTo(farthestLeft));
    expect(drop.take(2).toSet(), {0, 99}, reason: 'the two ends first');
  });

  test('the pages around the one in view stay, even when they alone are over the budget', () {
    final sizes = {for (var i = 0; i < 100; i++) i: 50 * mb};
    final drop = pagesToDrop(sizes, near: 40, keep: 5, budget: 100 * mb);
    expect(drop.toSet().intersection({for (var i = 35; i <= 45; i++) i}), isEmpty);
    expect(drop.length, 100 - 11);
  });

  test('works at the ends of the PDF and with a page number that is not kept', () {
    final sizes = {for (var i = 0; i < 30; i++) i: 10 * mb};
    expect(pagesToDrop(sizes, near: 0, keep: 3, budget: 100 * mb).toSet(), {for (var i = 10; i < 30; i++) i});
    expect(pagesToDrop({}, near: 5), isEmpty);
    expect(pagesToDrop({7: 500 * mb}, near: 900, keep: 3, budget: mb), [7]);
  });
}
