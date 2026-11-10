import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/screens/color_wheel_dialog.dart';

void main() {
  testWidgets('tapping the wheel picks a colour', (tester) async {
    Color? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await pickColorOnWheel(context, Colors.white),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final wheel = tester.getRect(find.byKey(const ValueKey('color-wheel')));
    // right edge of the wheel: hue 0 (red), full saturation
    await tester.tapAt(wheel.centerRight - const Offset(2, 0));
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    final hsv = HSVColor.fromColor(result!);
    expect(hsv.hue, closeTo(0, 5));
    expect(hsv.saturation, greaterThan(0.9));
  });

  testWidgets('cancel returns nothing', (tester) async {
    Color? result = Colors.red;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await pickColorOnWheel(context, Colors.white),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('from black the wheel opens bright, so that there is a colour to pick', (tester) async {
    Color? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () async => picked = await pickColorOnWheel(context, Colors.black), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byKey(const ValueKey('color-brightness'))).value, 1);
    // a tap on the wheel gives a colour that is not black
    final wheel = tester.getTopLeft(find.byKey(const ValueKey('color-wheel')));
    await tester.tapAt(wheel + const Offset(190, 110));
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(picked, isNotNull);
    expect(picked!.toARGB32(), isNot(0xFF000000));
  });

  testWidgets('a colour that is already bright opens as it is', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(onPressed: () => pickColorOnWheel(context, const Color(0xFF3060C0)), child: const Text('open')),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byKey(const ValueKey('color-brightness'))).value, closeTo(HSVColor.fromColor(const Color(0xFF3060C0)).value, 0.001));
  });
}
