import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/style/zoomed_selection.dart';

void main() {
  // the page is shown through a scale; the handles and the menu of a selection must stay the size they have on the screen
  for (final scale in const [0.5, 2.5]) {
    testWidgets('the handles and the menu of a selection keep their size in text drawn at $scale', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController(text: 'one two three four');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300 * scale,
              child: FittedBox(
                fit: BoxFit.fitWidth,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  child: TextField(
                    key: const ValueKey('field'),
                    controller: controller,
                    selectionControls: selectionControlsAtZoom(() => scale),
                    contextMenuBuilder: (context, state) => menuAtScreenSize(
                      state.context,
                      AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: state.contextMenuButtonItems),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.longPress(find.byKey(const ValueKey('field')), kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      final handles = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString().contains('Handle'));
      expect(handles, findsWidgets);
      for (final h in handles.evaluate()) {
        final shown = tester.getBottomRight(find.byWidget(h.widget)) - tester.getTopLeft(find.byWidget(h.widget));
        expect(shown.dx.abs(), closeTo(22, 0.5), reason: 'the handle is as large on the screen as ever');
      }
      final copy = find.text('Copy');
      final edit = tester.state<EditableTextState>(find.byType(EditableText));
      final box = edit.renderEditable;
      final top = box.localToGlobal(box.getEndpointsForSelection(edit.textEditingValue.selection).first.point);
      expect(copy, findsOneWidget);
      final button = find.ancestor(of: copy, matching: find.byType(TextButton)).first;
      expect((tester.getBottomRight(button) - tester.getTopLeft(button)).dy, closeTo(48, 6), reason: 'the menu is not scaled');
      expect((tester.getCenter(copy).dy - top.dy).abs(), lessThan(80), reason: 'the menu is by the selection (above it, or under it when there is no room above)');
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
