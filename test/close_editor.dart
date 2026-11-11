import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Closes the editor that is shown and lets what it keeps as it closes (what was read of the handwriting) reach the database. A
/// write begun in the test's fake time needs real time for the database and a pump for each step after it; left unfinished, it
/// holds the database (which the tests of a file share) and the next test waits on it.
Future<void> closeEditor(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
}

/// Lets the editor that was just shown load what it keeps (the note, and what was read of its handwriting before) and start what
/// it reads in the background: each database step needs real time, and a pump for what follows it.
Future<void> settleEditor(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Waits about [ms] milliseconds of real time for the editor's background reading, with 50 ms of fake time pumped after every 50 ms:
/// the reading goes on in the test's fake time (its timers, its queue) between the steps of the readers, which take real time.
Future<void> letRead(WidgetTester tester, int ms) async {
  for (var waited = 0; waited < ms; waited += 50) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
