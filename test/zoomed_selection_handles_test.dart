import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/style/zoomed_selection.dart';

void main() {
  // The handles of a selection in a page that is drawn scaled (the zoom, or a PDF word fitted to its place) follow the finger
  // that drags them, and keep their shape.
  for (final (name, sx, sy) in [('zoomed in', 2.0, 2.0), ('zoomed out', 0.5, 0.5), ('stretched', 1.6, 0.8)]) {
    testWidgets('a handle follows the finger when the text is $name', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final areaKey = GlobalKey<SelectionAreaState>();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Transform(
              transform: Matrix4.diagonal3Values(sx, sy, 1),
              child: SelectionArea(
                key: areaKey,
                selectionControls: selectionControlsAtZoom(() => sx, stretch: (_) => Offset(sx, sy)),
                child: const SizedBox(width: 300, child: Text('alpha bravo charlie delta echo foxtrot golf hotel india', style: TextStyle(fontSize: 14))),
              ),
            ),
          ),
        ),
      ));
      await tester.longPressAt(tester.getTopLeft(find.byType(Text)) + Offset(10 * sx, 7 * sy));
      await tester.pumpAndSettle();
      final region = areaKey.currentState!.selectableRegion;
      expect(region.selectionEndpoints.length, 2);
      final box = areaKey.currentContext!.findRenderObject()! as RenderBox;
      Offset onScreen(Offset local) => box.localToGlobal(local);

      final end = region.selectionEndpoints.last;
      final from = onScreen(end.point);
      region.hideToolbar(false); // (it may be laid over the handle)
      await tester.pumpAndSettle();
      final handles = find.descendant(of: find.byType(CompositedTransformFollower), matching: find.byType(FittedBox));
      expect(handles, findsAtLeastNWidgets(2));
      final grip = tester.getCenter(handles.at(1));
      final gesture = await tester.startGesture(grip);
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final after = onScreen(region.selectionEndpoints.last.point);
      await gesture.up();
      await tester.pumpAndSettle();
      // the end of the selection is at a letter's edge, so within a letter or so of the finger
      debugDefaultTargetPlatformOverride = null;
      expect((after.dx - from.dx - 100).abs(), lessThan(14 * sx + 1), reason: 'moved ${after.dx - from.dx}, the finger 100');
    });
  }
}
