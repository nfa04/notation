import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/features/feature.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/shortcuts/shortcut_service.dart';
import 'package:notes/style/paper_look.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(AppDatabase.initFfi);

  for (final (name, size) in const [('desktop 1280x800', Size(1280, 800)), ('tablet 820x1180', Size(820, 1180)), ('tablet landscape 1180x820', Size(1180, 820))]) {
    for (final dark in [false, true]) {
      testWidgets('the title and the tools share one line on a $name (${dark ? 'dark' : 'light'})', (tester) async {
        final features = FeatureSettings((k) async => null, (k, v) async {});
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
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
        final base = ThemeData(brightness: dark ? Brightness.dark : Brightness.light, useMaterial3: true);
        await tester.pumpWidget(MaterialApp(
          theme: paperLook(base),
          home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, features: features, shortcuts: ShortcutService.inMemory(mac: false)),
        ));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pumpAndSettle();
        final bar = tester.getSize(find.byType(AppBar));
        expect(bar.height, lessThanOrEqualTo(kToolbarHeight + 1), reason: 'one line: no second row of tools under the title');
        expect(find.byKey(const ValueKey('top-line')), findsOneWidget);
        // the title is plain text that can be edited, not a box
        final field = tester.widget<TextField>(find.descendant(of: find.byType(AppBar), matching: find.byType(TextField)));
        expect(field.decoration!.enabledBorder, InputBorder.none);
        expect(field.decoration!.focusedBorder, InputBorder.none);
        await tester.enterText(find.descendant(of: find.byType(AppBar), matching: find.byType(TextField)), 'Thermodynamics');
        await tester.pump();
        expect(find.text('Thermodynamics'), findsOneWidget);
        // the title sits left of the tools, at the same height
        final title = tester.getRect(find.descendant(of: find.byType(AppBar), matching: find.byType(TextField)));
        final tools = tester.getRect(find.byKey(const ValueKey('top-line')));
        expect(title.right, lessThanOrEqualTo(tools.left + 1));
        expect((title.center.dy - tools.center.dy).abs(), lessThan(8));
      });
    }
  }
}
