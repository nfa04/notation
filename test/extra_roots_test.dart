import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/net/extra_roots.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled list of root certificates is a list a TLS context accepts', () async {
    final context = SecurityContext(withTrustedRoots: false);
    await trustBundledRoots(onlyOnWindows: false, context: context);
    final pem = File('assets/certs/ca-bundle.pem').readAsStringSync();
    expect(RegExp('BEGIN CERTIFICATE').allMatches(pem).length, greaterThan(100));
    // and the file really is what the bundle loads (a bad file would only be logged, so load it directly as well)
    SecurityContext(withTrustedRoots: false).setTrustedCertificatesBytes(File('assets/certs/ca-bundle.pem').readAsBytesSync());
  });
}
