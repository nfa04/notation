import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/style/paper_look.dart';

void main() {
  test('the code uses the thin icons only', () {
    final bad = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'(?<![A-Za-z_.])Icons\.[a-z]').hasMatch(lines[i]) && !lines[i].trimLeft().startsWith('//')) bad.add('${f.path}:${i + 1}');
      }
    }
    expect(bad, isEmpty, reason: 'use Symbols.x (material_symbols_icons), see DESIGN.md');
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    test('the paper look in $brightness: no splash, thin icons, ruled cards, flat bars', () {
      final t = paperLook(ThemeData(useMaterial3: true, brightness: brightness, colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness)));
      expect(t.splashFactory, NoSplash.splashFactory);
      expect(t.iconTheme.weight, 300);
      expect(t.cardTheme.elevation, 0);
      expect(t.cardTheme.shape, isA<RoundedRectangleBorder>());
      expect(t.appBarTheme.elevation, 0);
      expect(t.snackBarTheme.elevation, 0);
      expect(t.textTheme.titleLarge?.fontWeight, FontWeight.w300);
      expect(t.textTheme.bodyMedium?.fontFeatures, isNotEmpty);
    });
  }
}
