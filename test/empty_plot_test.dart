import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/algebra/plot.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/screens/image_item_widget.dart';
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

  test('a blank plot has axes and a grid and no curve', () async {
    expect(const PlotSpec.blank().isBlank, isTrue);
    final png = await renderPlotPng(const PlotSpec.blank(), const PlotRange(-5, 5, -5, 5), const Size(200, 200), scale: 3); // 600 pixels square
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    final rgba = (await image.toByteData())!.buffer.asUint8List();
    Color at(int x, int y) {
      final i = (y * image.width + x) * 4;
      return Color.fromARGB(rgba[i + 3], rgba[i], rgba[i + 1], rgba[i + 2]);
    }

    double darkest(Iterable<Color> colors) => colors.map((c) => c.computeLuminance()).reduce((a, b) => a < b ? a : b);
    expect(darkest([for (var x = 297; x <= 303; x++) at(x, 120)]), lessThan(0.1)); // the y axis, through x = 0
    expect(darkest([for (var y = 297; y <= 303; y++) at(120, y)]), lessThan(0.1)); // the x axis
    expect(at(270, 270), const Color(0xFFFFFFFF)); // plain paper between the lines
    var blue = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      if (rgba[i + 2] > 150 && rgba[i] < 60) blue++; // the colour of a curve
    }
    expect(blue, 0);
  });

  testWidgets('the dialog asks for x and y from and to, checks them and previews the result', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Uint8List? placed;
    Size? placedSize;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => EmptyPlotDialog(onAdd: (png, size) async {
              placed = png;
              placedSize = size;
            }),
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plot-preview')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('plot-x-from'))).controller!.text, '-5'); // sensible start

    // an empty or backwards range is refused, with the reason
    await tester.enterText(find.byKey(const ValueKey('plot-x-from')), '');
    await tester.pump();
    expect(find.byKey(const ValueKey('plot-x-problem')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('plot-place'))).onPressed, isNull);
    expect(find.byKey(const ValueKey('plot-preview')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('plot-x-from')), '10');
    await tester.pump();
    expect(find.textContaining('smaller to a larger'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('plot-x-from')), '0');
    await tester.enterText(find.byKey(const ValueKey('plot-x-to')), '2,5'); // a decimal comma works
    await tester.enterText(find.byKey(const ValueKey('plot-y-from')), '-1');
    await tester.enterText(find.byKey(const ValueKey('plot-y-to')), '1e3');
    await tester.pump();
    expect(find.byKey(const ValueKey('plot-x-problem')), findsNothing);
    expect(find.byKey(const ValueKey('plot-y-problem')), findsNothing);
    final painter = tester.widget<CustomPaint>(find.byKey(const ValueKey('plot-preview'))).painter as PlotPainter;
    expect((painter.range.xmin, painter.range.xmax, painter.range.ymin, painter.range.ymax), (0.0, 2.5, -1.0, 1000.0));

    await tester.tap(find.byKey(const ValueKey('plot-shape-Square')));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('plot-place')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(placed, isNotNull);
    expect(placed!.sublist(1, 4), 'PNG'.codeUnits);
    expect(placedSize, const Size(420, 420));
    expect(find.byKey(const ValueKey('plot-place')), findsNothing); // the dialog closed
  });

  testWidgets('the draw bar places an empty plot on the page, and the pen stays ready', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late NoteRepository repo;
    late String id;
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('plot_');
      PathProviderPlatform.instance = _Paths(dir.path);
      final db = await AppDatabase.open(path: inMemoryDatabasePath);
      repo = NoteRepository(db);
      id = await repo.createNote();
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('empty-plot')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('plot-x-from')), '0');
    await tester.enterText(find.byKey(const ValueKey('plot-x-to')), '10');
    await tester.enterText(find.byKey(const ValueKey('plot-y-from')), '0');
    await tester.enterText(find.byKey(const ValueKey('plot-y-to')), '100');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('plot-place')));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is ImageItemWidget && w.key.toString().contains('image-pic')), findsOneWidget);
    // still in draw mode: the bar with the pen tools is there, and nothing is selected for moving
    expect(find.byKey(const ValueKey('empty-plot')), findsOneWidget);
    expect(find.byKey(const ValueKey('shape-tool')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    final saved = (await tester.runAsync(() => repo.loadNote(id)))!;
    final image = saved.images.values.expand((l) => l).single;
    expect(File(image.path).existsSync(), isTrue);
    expect(image.size.width / image.size.height, closeTo(480 / 360, 0.01));
  });
}
