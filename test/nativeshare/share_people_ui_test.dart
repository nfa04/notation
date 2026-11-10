import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/nativeshare/native_share_provider.dart';
import 'package:notes/nativeshare/native_share_service.dart';
import 'package:notes/nativeshare/share_model.dart';
import 'package:notes/screens/share_people.dart';

import '../devicesync/harness.dart';
import 'fake_share_provider.dart';

class _Unsupported extends FakeShareProvider {
  _Unsupported(super.hub, super.user);
  @override
  String? get unsupportedReason => 'Personal accounts cannot share with people.';
}

/// A service whose shares are found from a link that comes with the invitation (as OneDrive's are).
class _Linked extends FakeShareProvider {
  _Linked(super.hub, super.user);
  @override
  bool get acceptsLinks => true;
  @override
  bool recognizes(String text) => text.contains('link:');
  @override
  Future<ProviderShare> share(String place, SharePerson person, ShareRole role) async {
    final s = await super.share(place, person, role);
    return ProviderShare(s.id, s.person, s.role, link: 'link:${s.id}');
  }

  @override
  Future<IncomingShare> addLink(String text) async {
    final id = RegExp(r'link:(\w+)').firstMatch(text)!.group(1)!;
    final found = (await incoming()).where((s) => s.id == id).firstOrNull;
    if (found == null) throw const NativeShareException('This link does not open a shared folder for you.');
    return found;
  }
}

Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory root;
  late FakeShareHub hub;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('share_ui_');
    hub = FakeShareHub();
  });
  tearDown(() => root.delete(recursive: true));

  Future<(Device, NativeShareService)> make(WidgetTester tester, String user, {NativeShareProvider? provider}) async {
    late Device d;
    late NativeShareService s;
    await tester.runAsync(() async {
      d = await Device.create('$user-laptop', root);
      s = NativeShareService(
        db: d.db,
        settings: d.settings,
        library: d.library,
        providers: [provider ?? hub.as(user)],
        deviceId: () => d.identity.id,
        deviceName: () => d.name,
        every: const Duration(hours: 1),
        afterChange: const Duration(hours: 1),
        retryDelays: const [],
      );
      await s.load();
    });
    return (d, s);
  }

  /// Takes the screen away and lets go of the services (their timers would outlive the test).
  Future<void> end(WidgetTester tester, List<NativeShareService> services) async {
    await tester.pumpWidget(const SizedBox());
    for (final s in services) {
      s.dispose();
    }
  }

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: child))));

  testWidgets('share a note with a person found by name, change nothing, remove them, stop', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (dev, svc) = await make(tester, 'alice');
    late String noteId;
    await tester.runAsync(() async => noteId = await dev.note('Optics', 'x'));
    await tester.pumpWidget(host(SharePeoplePanel(service: svc, kind: ShareKind.note, rootId: noteId)));

    expect(find.byKey(const ValueKey('share-recipient-bob')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('share-person')), 'bo');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester, rounds: 2);
    await tester.tap(find.byKey(const ValueKey('share-found-bob')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('share-go')));
    await settle(tester);

    expect(find.byKey(const ValueKey('share-recipient-bob')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-problem')), findsNothing);
    expect(hub.grants.values.single['bob']!.role, ShareRole.editor);

    await tester.tap(find.byKey(const ValueKey('share-remove-bob')));
    await settle(tester);
    expect(find.byKey(const ValueKey('share-recipient-bob')), findsNothing);
    expect(hub.grants.values.single, isEmpty);

    await tester.tap(find.byKey(const ValueKey('share-stop')));
    await settle(tester);
    expect(find.byKey(const ValueKey('share-stop')), findsNothing);
    expect(svc.shares, isEmpty);
    await end(tester, [svc]);
  });

  testWidgets('a person who is typed in whole is shared with even when the search finds nobody; view only is a choice', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (dev, svc) = await make(tester, 'alice');
    late String noteId;
    await tester.runAsync(() async => noteId = await dev.note('Optics', 'x'));
    await tester.pumpWidget(host(SharePeoplePanel(service: svc, kind: ShareKind.note, rootId: noteId)));
    await tester.tap(find.text('Can view'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('share-person')), 'carol');
    await tester.tap(find.byKey(const ValueKey('share-go')));
    await settle(tester);
    expect(find.byKey(const ValueKey('share-recipient-carol')), findsOneWidget);
    expect(hub.grants.values.single['carol']!.role, ShareRole.viewer);
    await end(tester, [svc]);
  });

  testWidgets('a service that cannot share for this account says why instead of offering the form', (tester) async {
    final (dev, svc) = await make(tester, 'alice', provider: _Unsupported(hub, 'alice'));
    late String noteId;
    await tester.runAsync(() async => noteId = await dev.note('Optics', 'x'));
    await tester.pumpWidget(host(SharePeoplePanel(service: svc, kind: ShareKind.note, rootId: noteId)));
    expect(find.byKey(const ValueKey('share-unsupported-fake')), findsOneWidget);
    expect(find.textContaining('Personal accounts cannot share'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-person')), findsNothing);
    await end(tester, [svc]);
  });

  testWidgets('settings: a share that waits is accepted into a folder, then left', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (adev, asvc) = await make(tester, 'alice');
    final (bdev, bsvc) = await make(tester, 'bob');
    late String noteId;
    await tester.runAsync(() async {
      noteId = await adev.note('Optics', 'light');
      await asvc.shareNote(noteId, asvc.usable.single, const SharePerson('bob', 'Bob'), ShareRole.viewer);
    });
    await tester.pumpWidget(host(NativeShareSettings(service: bsvc)));
    await settle(tester);

    expect(find.textContaining('Optics'), findsOneWidget);
    expect(find.textContaining('from Alice'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('pending-accept-${bsvc.pending.single.share.id}')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('No folder (top level)'));
    await settle(tester, rounds: 12);

    expect(bsvc.pending, isEmpty);
    expect(bsvc.received.single.kind, ShareKind.note);
    expect(find.byKey(ValueKey('share-${bsvc.received.single.id}')), findsOneWidget);
    await tester.runAsync(() async => expect(await bdev.text(noteId), 'light'));

    await tester.tap(find.byKey(ValueKey('share-menu-${bsvc.received.single.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave'));
    await settle(tester);
    expect(bsvc.shares, isEmpty);
    await tester.runAsync(() async => expect(await bdev.text(noteId), 'light', reason: 'the note stays'));
    await end(tester, [asvc, bsvc]);
  });

  testWidgets('invitations card: a share that waits is shown with Accept, and goes away when accepted', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (adev, asvc) = await make(tester, 'alice');
    final (_, bsvc) = await make(tester, 'bob');
    await tester.runAsync(() async {
      final id = await adev.note('Optics', 'light');
      await asvc.shareNote(id, asvc.usable.single, const SharePerson('bob', 'Bob'), ShareRole.viewer);
      await bsvc.refreshIncoming();
    });
    await tester.pumpWidget(host(ShareInvitations(service: bsvc)));
    await settle(tester);

    expect(find.byKey(const ValueKey('share-invitations')), findsOneWidget);
    expect(find.text('Someone shared something with you'), findsOneWidget);
    expect(find.textContaining('Optics'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('invitation-accept-${bsvc.pending.single.share.id}')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('No folder (top level)'));
    await settle(tester, rounds: 12);

    expect(bsvc.pending, isEmpty);
    expect(find.byKey(const ValueKey('share-invitations')), findsNothing);
    await end(tester, [asvc, bsvc]);
  });

  testWidgets('settings: a share that is not accepted for a reason says it', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (_, bsvc) = await make(tester, 'bob');
    await tester.runAsync(() => hub.as('carol').share('Evil (Notation abcdef)', const SharePerson('bob', 'Bob'), ShareRole.editor)); // no descriptor in it
    await tester.pumpWidget(host(NativeShareSettings(service: bsvc)));
    await settle(tester);
    await tester.tap(find.byKey(ValueKey('pending-accept-${bsvc.pending.single.share.id}')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('No folder (top level)'));
    await settle(tester);
    expect(find.byKey(const ValueKey('shares-problem')), findsOneWidget);
    expect(find.textContaining('not a share from Notation'), findsOneWidget);
    expect(bsvc.shares, isEmpty);
    await end(tester, [bsvc]);
  });

  testWidgets('a service that needs a link: the sender can copy it, and the person adds it in the settings', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final (adev, asvc) = await make(tester, 'alice', provider: _Linked(hub, 'alice'));
    final (_, bsvc) = await make(tester, 'bob', provider: _Linked(hub, 'bob'));
    late String noteId;
    await tester.runAsync(() async => noteId = await adev.note('Optics', 'x'));
    await tester.pumpWidget(host(SharePeoplePanel(service: asvc, kind: ShareKind.note, rootId: noteId)));
    await tester.enterText(find.byKey(const ValueKey('share-person')), 'bob');
    await tester.tap(find.byKey(const ValueKey('share-go')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('share-link-bob')));
    await settle(tester, rounds: 2);
    expect(copied.single, startsWith('link:'));
    final link = copied.single;
    await end(tester, [asvc]);

    await tester.pumpWidget(host(NativeShareSettings(service: bsvc)));
    await settle(tester);
    expect(find.byKey(const ValueKey('shares-link')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('shares-link')), 'nonsense');
    await tester.tap(find.byKey(const ValueKey('shares-link-add')));
    await settle(tester, rounds: 3);
    expect(find.textContaining('not a link to a share'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('shares-link')), 'Hi! $link');
    await tester.tap(find.byKey(const ValueKey('shares-link-add')));
    await settle(tester, rounds: 3);
    expect(bsvc.pending.single.share.owner, 'Alice');
    expect(find.byKey(ValueKey('pending-${bsvc.pending.single.share.id}')), findsOneWidget);
    await end(tester, [bsvc]);
  });
}
