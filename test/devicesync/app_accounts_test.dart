import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/dropbox_storage.dart';
import 'package:notes/collab/onedrive_storage.dart';
import 'package:notes/collab/s3_storage.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/settings_repository.dart';
import 'package:notes/data/task_repository.dart';
import 'package:notes/devicesync/app_accounts.dart';
import 'package:notes/devicesync/sync_accounts.dart';
import 'package:notes/sync/caldav_service.dart';

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

void main() {
  setUpAll(AppDatabase.initFfi);

  late Directory dir;
  late AppAccounts accounts;
  late S3Storage s3;
  late CalDavService caldav;
  late DropboxStorage dropbox;
  var clock = DateTime.utc(2026, 1, 1);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('accounts_');
    clock = DateTime.utc(2026, 1, 1);
    final db = await AppDatabase.open(path: '${dir.path}/a.db');
    final settings = SettingsRepository(db);
    s3 = S3Storage(settings, secret: _Secret());
    caldav = CalDavService(settings, TaskRepository(db), secret: _Secret());
    dropbox = DropboxStorage(appKey: 'key', settings: settings, store: _Secret());
    final onedrive = OneDriveStorage(clientId: 'cid', settings: settings, store: _Secret());
    accounts = AppAccounts(settings: settings, caldav: caldav, s3: s3, dropbox: dropbox, onedrive: onedrive, now: () => clock);
  });
  tearDown(() => dir.delete(recursive: true));

  Future<AccountBundle> bundle(String kind) async => (await accounts.export()).firstWhere((b) => b.kind == kind);

  test('an account that is set up here is noted with the time; nothing is noted for what was never there', () async {
    expect((await accounts.export()).every((b) => b.at == 0 && b.data == null), isTrue);
    clock = DateTime.utc(2026, 2, 1);
    await s3.save(const S3Config(endpoint: 'https://s3.example', region: 'auto', bucket: 'notes', accessKey: 'AK'), 'SK');
    await Future<void>.delayed(Duration.zero);
    final b = await bundle('s3');
    expect(b.at, clock.millisecondsSinceEpoch);
    expect(b.data, {'endpoint': 'https://s3.example', 'region': 'auto', 'bucket': 'notes', 'access': 'AK', 'secret': 'SK'});

    // taken away here later: the removal is a change too, and it carries the time
    clock = DateTime.utc(2026, 3, 1);
    await s3.remove();
    await Future<void>.delayed(Duration.zero);
    final gone = await bundle('s3');
    expect(gone.at, clock.millisecondsSinceEpoch);
    expect(gone.data, isNull);
  });

  test('accounts from another device are taken when newer; what is taken in does not count as a new change', () async {
    final at = DateTime.utc(2026, 5, 1).millisecondsSinceEpoch;
    final n = await accounts.apply([
      AccountBundle('s3', at, {'endpoint': 'https://s3.example', 'region': 'auto', 'bucket': 'notes', 'access': 'AK', 'secret': 'SK'}),
      AccountBundle('nextcloud', at, {'url': 'https://cloud.example/remote.php/dav', 'user': 'anna', 'password': 'pw', 'tasks': '/tasks/', 'events': '["/cal/"]'}),
      AccountBundle('dropbox', at, {'refresh': 'RT', 'client': 'my-own-app'}),
      AccountBundle('onedrive', at, {'refresh': 'RT2'}),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(n, 4);
    expect(s3.config!.bucket, 'notes');
    expect(s3.secretKey, 'SK');
    expect((await caldav.login())!.password, 'pw');
    expect(caldav.config!.taskCalendar, '/tasks/');
    expect(caldav.config!.eventCalendars, {'/cal/'});
    expect(dropbox.available, isTrue); // (a refresh token is enough: the token for the moment is asked for when needed)
    expect(dropbox.oauth.clientId, 'my-own-app');
    expect((await bundle('s3')).at, at); // the time of the other device, not now
    expect((await bundle('dropbox')).data, {'refresh': 'RT', 'client': 'my-own-app'});

    // older or equal ones change nothing
    expect(await accounts.apply([AccountBundle('s3', at, {'endpoint': 'https://other', 'region': 'x', 'bucket': 'y', 'access': 'z', 'secret': 'w'})]), 0);
    expect(s3.config!.bucket, 'notes');

    // a newer removal removes it
    expect(await accounts.apply([AccountBundle('nextcloud', at + 1, null), AccountBundle('dropbox', at + 1, null)]), 2);
    expect(caldav.isConnected, isFalse);
    expect(dropbox.available, isFalse);
  });
}
