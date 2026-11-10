import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/models/canvas_models.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/plot_dialog.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String dir;
  _Paths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('a plot made from a formula in a text box takes every option into the picture on the page', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('plot_formula_');
      PathProviderPlatform.instance = _Paths(dir.path);
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
      final note = (await repo.loadNote(id))!;
      note.textBoxes[0] = [TextBoxWidgetModel(id: 'b', position: const Offset(100, 100), initialText: r'Plot $y = x^2 - 4$')];
      await repo.saveNote(note);
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byKey(const ValueKey('page-0')));
    await tester.tapAt(origin + const Offset(150, 130)); // into the box
    await tester.pumpAndSettle();
    final field = tester.state<EditableTextState>(find.byType(EditableText).first);
    field.widget.controller.selection = const TextSelection(baseOffset: 5, extentOffset: 18); // the formula
    await tester.pump();
    field.showToolbar();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calculate'));
    await tester.pumpAndSettle();
    if (find.byKey(const ValueKey('calc-plot')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('calc-plot')));
      await tester.pumpAndSettle();
    }

    // the same options as for any plot, on the preview of this one
    PlotPainter painter() => tester.widget<CustomPaint>(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PlotPainter)).painter! as PlotPainter;
    expect(painter().spec.latex, contains('x^2'));
    for (final key in ['plot-bg-dark', 'plot-zeros', 'plot-fill', 'plot-grid-fine', 'plot-line-dashed', 'plot-color-3']) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }
    final style = painter().style;
    expect((style.background.name, style.zeros, style.fillUnder, style.grid.name, style.line.name), ('dark', true, true, 'fine', 'dashed'));

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('add-plot')));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-plot')), findsNothing); // the dialog closed
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));

    // the picture on the page is the one that was styled
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    final image = saved.images.values.expand((l) => l).single;
    final bytes = await tester.runAsync(() => File(image.path).readAsBytes());
    final pic = (await tester.runAsync(() async => (await (await ui.instantiateImageCodec(bytes!)).getNextFrame()).image))!;
    final rgba = (await tester.runAsync(() => pic.toByteData()))!.buffer.asUint8List();
    final corner = (20 * pic.width + 20) * 4;
    expect(Color.fromARGB(255, rgba[corner], rgba[corner + 1], rgba[corner + 2]).computeLuminance(), lessThan(0.05)); // the dark page
  });
}
