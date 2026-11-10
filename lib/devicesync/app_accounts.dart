import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../collab/dropbox_storage.dart';
import '../collab/onedrive_storage.dart';
import '../collab/oauth.dart';
import '../collab/s3_storage.dart';
import '../data/settings_repository.dart';
import '../sync/caldav_service.dart';
import 'sync_accounts.dart';

/// [SyncedAccounts] on the services of the app. When an account changes here (connected, changed, removed), the time is noted, so
/// that the newer one wins when two devices meet.
class AppAccounts implements SyncedAccounts {
  final SettingsRepository settings;
  final CalDavService caldav;
  final S3Storage s3;
  final DropboxStorage dropbox;
  final OneDriveStorage onedrive;
  final DateTime Function() _now;

  AppAccounts({required this.settings, required this.caldav, required this.s3, required this.dropbox, required this.onedrive, DateTime Function()? now})
      : _now = now ?? DateTime.now {
    for (final n in <Listenable>[caldav, s3, dropbox, onedrive]) {
      n.addListener(() => unawaited(_changed()));
    }
  }

  static const kinds = ['nextcloud', 's3', 'dropbox', 'onedrive'];

  bool _applying = false;

  // ---- reading an account

  Future<Map<String, String>?> _read(String kind) async {
    switch (kind) {
      case 'nextcloud':
        final login = await caldav.login();
        final c = caldav.config;
        if (login == null || c == null) return null;
        return {
          'url': login.serverUrl,
          'user': login.username,
          'password': login.password,
          'tasks': ?c.taskCalendar,
          'events': jsonEncode(c.eventCalendars.toList()..sort()),
        };
      case 's3':
        final c = s3.config, secret = s3.secretKey;
        if (c == null || secret == null) return null;
        return {'endpoint': c.endpoint, 'region': c.region, 'bucket': c.bucket, 'access': c.accessKey, 'secret': secret};
      case 'dropbox':
        return _readOAuth(dropbox);
      case 'onedrive':
        return _readOAuth(onedrive);
    }
    return null;
  }

  Map<String, String>? _readOAuth(OAuthShareStorage storage) {
    final refresh = storage.oauth.refreshToken;
    if (refresh == null) return null;
    return {'refresh': refresh, if (storage.customClientId) 'client': storage.oauth.clientId};
  }

  // ---- when it changed

  String _fingerprint(Map<String, String>? data) {
    if (data == null) return 'none';
    final keys = data.keys.toList()..sort();
    return sha256.convert(utf8.encode(jsonEncode([for (final k in keys) [k, data[k]]]))).toString();
  }

  /// Notes the time when what an account holds is not what it was.
  Future<void> _changed() async {
    if (_applying) return;
    await reconcile();
  }

  /// Compares every account with what was noted of it; the ones that differ changed now.
  Future<void> reconcile() async {
    for (final kind in kinds) {
      final fp = _fingerprint(await _read(kind));
      if (await settings.get('acct_fp_$kind') == fp) continue;
      // an account that was never there and is not there is not a change
      if (fp == 'none' && await settings.get('acct_fp_$kind') == null) continue;
      await settings.set('acct_fp_$kind', fp);
      await settings.set('acct_at_$kind', '${_now().millisecondsSinceEpoch}');
    }
  }

  @override
  Future<List<AccountBundle>> export() async {
    await reconcile();
    return [
      for (final kind in kinds) AccountBundle(kind, int.tryParse(await settings.get('acct_at_$kind') ?? '') ?? 0, await _read(kind)),
    ];
  }

  // ---- taking one in

  @override
  Future<int> apply(List<AccountBundle> theirs) async {
    final mine = {for (final b in await export()) b.kind: b};
    var changed = 0;
    for (final t in theirs) {
      final m = mine[t.kind];
      if (m == null || t.at <= m.at) continue;
      _applying = true;
      try {
        await _take(t);
        await settings.set('acct_fp_${t.kind}', _fingerprint(await _read(t.kind)));
        await settings.set('acct_at_${t.kind}', '${t.at}');
        changed++;
      } finally {
        _applying = false;
      }
    }
    return changed;
  }

  Future<void> _take(AccountBundle b) async {
    final d = b.data;
    switch (b.kind) {
      case 'nextcloud':
        if (d == null) {
          await caldav.disconnect();
          return;
        }
        await caldav.save(d['url']!, d['user']!, d['password']!,
            taskCalendar: d['tasks'], eventCalendars: {...(jsonDecode(d['events'] ?? '[]') as List).cast<String>()});
      case 's3':
        if (d == null) {
          await s3.remove();
          return;
        }
        await s3.save(S3Config(endpoint: d['endpoint']!, region: d['region']!, bucket: d['bucket']!, accessKey: d['access']!), d['secret']!);
      case 'dropbox':
        await _takeOAuth(dropbox, d);
      case 'onedrive':
        await _takeOAuth(onedrive, d);
    }
  }

  Future<void> _takeOAuth(OAuthShareStorage storage, Map<String, String>? d) async {
    if (d == null) {
      await storage.signOut();
      return;
    }
    await storage.setClientId(d['client'] ?? '');
    await storage.oauth.adopt(d['refresh']!);
    await storage.load();
  }
}
