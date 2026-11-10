import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/cloud_share.dart';
import 'package:notes/collab/dropbox_storage.dart';
import 'package:notes/collab/s3_storage.dart';
import 'package:notes/collab/share_storage.dart';
import 'package:notes/data/note_file_service.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/screens/share_storage_settings.dart';
import 'package:notes/sync/caldav_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

class _Plain extends ShareStorage {
  @override
  String get label => 'Plain';
  @override
  bool get available => false;
  @override
  Duration get keeps => const Duration(days: 1);
  @override
  Future<StoredFile> store(Uint8List sealed) async => StoredFile(Uri.parse('https://x.example/1'), '1');
}

void main() {
  setUpAll(AppDatabase.initFfi);

  testWidgets('every kind of service has its section, and the S3 form waits for its fields', (tester) async {
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    final files = NoteFileService(NoteRepository(db!));
    final s3 = S3Storage(null, secret: _Secret());
    final share = CloudShare(files, [s3, DropboxStorage(appKey: 'k', store: _Secret()), _Plain()]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ShareStorageSettings(share: share)))));
    await tester.pump();

    expect(find.text('S3 storage'), findsOneWidget);
    expect(find.text('Dropbox'), findsOneWidget);
    expect(find.text('Plain'), findsOneWidget);
    expect(find.byKey(const ValueKey('dropbox-signin')), findsOneWidget);

    FilledButton save() => tester.widget<FilledButton>(find.byKey(const ValueKey('s3-save')));
    expect(save().onPressed, isNull, reason: 'nothing filled in yet');
    await tester.enterText(find.byKey(const ValueKey('s3-endpoint')), 'acct.r2.cloudflarestorage.com');
    await tester.enterText(find.byKey(const ValueKey('s3-bucket')), 'notes');
    await tester.enterText(find.byKey(const ValueKey('s3-access')), 'AKID');
    await tester.pump();
    expect(save().onPressed, isNull, reason: 'the secret is missing');
    await tester.enterText(find.byKey(const ValueKey('s3-secret')), 'shh');
    await tester.pump();
    expect(save().onPressed, isNotNull);
  });

  testWidgets('a service without an app registration asks for one, keeps it, and is then ready to sign in', (tester) async {
    final db = await tester.runAsync(() => AppDatabase.open(path: inMemoryDatabasePath));
    final settings = SettingsRepository(db!);
    final dropbox = DropboxStorage(settings: settings, store: _Secret()); // as in a build without a key
    final share = CloudShare(NoteFileService(NoteRepository(db)), [dropbox]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ShareStorageSettings(share: share)))));
    await tester.pump();

    expect(dropbox.configured, isFalse);
    expect(find.byKey(const ValueKey('dropbox-signin')), findsNothing);
    expect(find.byKey(const ValueKey('dropbox-setup')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('dropbox-save-id'))).onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('dropbox-clientid')), 'myappkey');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('dropbox-save-id')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(dropbox.configured, isTrue);
    expect(dropbox.oauth.clientId, 'myappkey');
    expect(find.byKey(const ValueKey('dropbox-signin')), findsOneWidget);
    expect((await tester.runAsync(() => settings.get('dropbox_app_key'))), 'myappkey');

    // it is remembered for the next start
    final again = DropboxStorage(settings: settings, store: _Secret());
    await tester.runAsync(again.load);
    expect(again.oauth.clientId, 'myappkey');
    expect(again.customClientId, isTrue);
  });
}
