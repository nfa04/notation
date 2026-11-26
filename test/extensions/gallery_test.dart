import 'package:flutter_test/flutter_test.dart';
import 'package:notes/extensions/extension_gallery.dart';

void main() {
  test('versions are compared by their numbers', () {
    expect(versionIsNewer('1.0.1', '1.0.0'), isTrue);
    expect(versionIsNewer('1.10', '1.9'), isTrue);
    expect(versionIsNewer('2', '1.9.9'), isTrue);
    expect(versionIsNewer('1.0', '1.0.0'), isFalse);
    expect(versionIsNewer('1.0.0', '1.0.0'), isFalse);
    expect(versionIsNewer('0.9', '1.0'), isFalse);
  });
}
