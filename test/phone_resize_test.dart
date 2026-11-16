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
  testWidgets('resize across the phone switch with semantics on', (tester) async {
    final handle = tester.ensureSemantics();
    final features = FeatureSettings((k) async => null, (k, v) async {});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
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
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, features: features, shortcuts: ShortcutService.inMemory(mac: false))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    for (final w in <double>[900, 800, 721, 719, 650, 500, 400, 650, 721, 900, 1000]) {
      tester.view.physicalSize = Size(w, 800);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width $w');
    }
    handle.dispose();
  });
}
