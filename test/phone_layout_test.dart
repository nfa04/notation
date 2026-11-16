import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/shortcuts/shortcut_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  for (final (name, size) in const [('phone 390x844', Size(390, 844)), ('small phone 360x640', Size(360, 640)), ('landscape 844x390', Size(844, 390)), ('narrow window 650x900', Size(650, 900))]) {
    testWidgets('probe $name', (tester) async {
      final features = FeatureSettings((k) async => null, (k, v) async {});
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      late NoteRepository repo;
      late String id;
      await tester.runAsync(() async {
        final db = await AppDatabase.open(path: inMemoryDatabasePath);
        await db.delete('settings');
        repo = NoteRepository(db);
        await repo.settings.set('index_handwriting', '0');
        await repo.settings.set('pdf_handwriting_text', '0');
        id = await repo.createNote();
      });
      final overflows = <String>[];
      final old = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exceptionAsString().contains('overflowed')) {
          overflows.add(d.exceptionAsString().split('\n').first);
        } else {
          old?.call(d);
        }
      };
      addTearDown(() => FlutterError.onError = old);
      await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, features: features, shortcuts: ShortcutService.inMemory(mac: false))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      final bar = tester.getSize(find.byType(AppBar));
      final page = tester.getSize(find.byType(Scrollable).first);
      final small = <String>[];
      var buttons = 0;
      for (final e in find.byWidgetPredicate((w) => w is IconButton || w is InkWell || w is PopupMenuButton).evaluate()) {
        final box = e.renderObject;
        if (box is! RenderBox || !box.hasSize) continue;
        final r = box.localToGlobal(Offset.zero) & box.size;
        if (r.bottom < 0 || r.top > size.height || r.right < 0 || r.left > size.width) continue;
        buttons++;
        if (box.size.width < 44 || box.size.height < 44) small.add('${e.widget.runtimeType} ${box.size.width.round()}x${box.size.height.round()}');
      }
      final bottom = find.byKey(const ValueKey('bottom-toolbar')).evaluate().isEmpty ? Size.zero : tester.getSize(find.byKey(const ValueKey('bottom-toolbar')));
      // ignore: avoid_print
      print('PROBE $name: appBar=${bar.width.round()}x${bar.height.round()} bottomBar=${bottom.height.round()} firstScrollable=${page.width.round()}x${page.height.round()} onScreenButtons=$buttons under44=${small.length} overflows=${overflows.length}');
      // on a phone the bars are one line each that scroll sideways: the page keeps most of the screen
      expect(bar.height, lessThanOrEqualTo(92), reason: 'the top bar is the title and one strip');
      expect(bottom.height, lessThanOrEqualTo(60), reason: 'the bottom toolbar is one strip');
      expect(find.byKey(const ValueKey('top-strip')), findsOneWidget);
      expect(overflows, isEmpty);
      // ignore: avoid_print
      print('PROBE $name small: ${small.toSet().toList().take(12)}');
      // ignore: avoid_print
      print('PROBE $name overflow: ${overflows.take(5)}');
    });
  }
}
