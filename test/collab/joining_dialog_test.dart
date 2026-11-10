// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/collab_service.dart';
import 'package:notes/collab/invite.dart';
import 'package:notes/screens/collab_ui.dart';

void main() {
  testWidgets('the joining dialog closes once, however often the attempt changes while it fades out', (tester) async {
    final attempt = JoinAttempt(SessionInvite.create('ws://localhost:1', random: Random(1)));
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showJoinAttempt(context, attempt),
            child: const Text('the screen under it'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('the screen under it'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // (the progress bar never settles)
    expect(find.text('Joining a live session'), findsOneWidget);

    attempt.noteId = 'n1';
    attempt.notifyListeners();
    await tester.pump(const Duration(milliseconds: 20)); // the dialog is fading out
    attempt.notifyListeners(); // the session says who is there, and so on
    attempt.notifyListeners();
    await tester.pumpAndSettle();

    expect(result, 'n1');
    expect(find.text('the screen under it'), findsOneWidget, reason: 'the screen under the dialog is still there');
  });
}
