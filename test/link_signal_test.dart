import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/link_stats.dart';
import 'package:notes/screens/link_signal.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget w) => tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: w))));

  testWidgets('the signal shows bars for how good the link is, and nothing while it is not known', (tester) async {
    await show(tester, const LinkSignal(band: LinkBand.unknown));
    expect(find.byType(Icon), findsNothing);

    for (final (band, icon) in [
      (LinkBand.good, Icons.signal_cellular_alt),
      (LinkBand.fair, Icons.signal_cellular_alt_2_bar),
      (LinkBand.poor, Icons.signal_cellular_alt_1_bar),
    ]) {
      await show(tester, LinkSignal(band: band));
      expect(find.byKey(ValueKey('link-signal-${band.name}')), findsOneWidget);
      expect(tester.widget<Icon>(find.byKey(ValueKey('link-signal-${band.name}'))).icon, icon);
      expect(find.byKey(const ValueKey('link-signal-relayed')), findsNothing);
    }
  });

  testWidgets('the three bands have three colours, and say what they mean in words', (tester) async {
    await show(tester, const SizedBox());
    final context = tester.element(find.byType(SizedBox).first);
    final colors = {for (final b in [LinkBand.good, LinkBand.fair, LinkBand.poor]) LinkSignal.colorOf(context, b)};
    expect(colors.length, 3);
    expect(LinkSignal.describe(LinkBand.good), 'Good connection');
    expect(LinkSignal.describe(LinkBand.fair), 'Unstable connection');
    expect(LinkSignal.describe(LinkBand.poor), 'Poor connection');
    expect(LinkSignal.describe(LinkBand.fair, relayed: true), 'Unstable connection, through a relay');
  });

  testWidgets('a link through a relay has its own mark and says so when asked', (tester) async {
    await show(tester, const LinkSignal(band: LinkBand.fair, relayed: true));
    expect(find.byKey(const ValueKey('link-signal-relayed')), findsOneWidget);
    await tester.longPress(find.byType(LinkSignal));
    await tester.pumpAndSettle();
    expect(find.text('Unstable connection, through a relay'), findsOneWidget);
  });

  testWidgets('the dot on a button is only there when the link is not good', (tester) async {
    for (final b in [LinkBand.unknown, LinkBand.good]) {
      await show(tester, LinkDot(band: b));
      expect(find.byType(Container), findsNothing, reason: '${b.name}: nothing to see while all is well');
    }
    await show(tester, const LinkDot(band: LinkBand.fair));
    expect(find.byKey(const ValueKey('link-dot-fair')), findsOneWidget);
    await show(tester, const LinkDot(band: LinkBand.poor));
    expect(find.byKey(const ValueKey('link-dot-poor')), findsOneWidget);
  });
}
