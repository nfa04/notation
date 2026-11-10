import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/features/feature.dart';

void main() {
  test('a tool added after the list was saved is on, one the person switched off stays off', () async {
    // a list saved before citations existed: no record of what it knew
    final store = <String, String>{
      FeatureSettings.enabledKey: jsonEncode(['pdf', 'lookup']),
    };
    final old = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
    await old.load();
    expect(old.on(Feature.citations), isTrue);
    expect(old.on(Feature.lookup), isTrue);
    expect(old.on(Feature.highlighter), isFalse);

    // saved by this version, then the person switches citations off
    await old.set(Feature.citations, false);
    final again = FeatureSettings((k) async => store[k], (k, v) async => store[k] = v);
    await again.load();
    expect(again.on(Feature.citations), isFalse);
    expect(again.on(Feature.highlighter), isFalse);
  });
}
