// A probe of whether the identity of a device survives a reload of the page in the browser. The first load makes an identity and a
// profile secret at the same time (as the app can), a later load only reads them; both POST what they saw to /result.
// Build: flutter build web -t tool/web_probe/identity_probe.dart --output build/probe --no-pub --no-wasm-dry-run --no-web-resources-cdn --profile
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:notes/data/app_secure_storage.dart';
import 'package:notes/devicesync/sync_devices.dart';
import 'package:notes/devicesync/sync_diag.dart';
import 'package:notes/devicesync/sync_keys.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = <String>[];
  try {
    if (Uri.base.queryParameters['warm'] == '1') await warmUpSecureStorage();
    const keys = KeystoreSyncKeys();
    final before = await keys.deviceIdentity();
    final secretBefore = await keys.profileSecret();
    log.add('start: identity ${before == null ? 'NONE' : '${before.id} seed ${keyTag(before.seed)}'}, profile secret ${secretBefore == null ? 'NONE' : keyTag(secretBefore)}');
    if (before == null) {
      final fresh = await DeviceIdentity.create();
      final secret = SyncSecret.create();
      // at the same time, as two parts of the app can ask for the keystore at once
      if (Uri.base.queryParameters['seq'] == '1') {
        await keys.setDeviceIdentity((id: fresh.id, seed: fresh.seed));
        await keys.setProfileSecret(secret.bytes);
      } else {
        await Future.wait([
          keys.setDeviceIdentity((id: fresh.id, seed: fresh.seed)),
          keys.setProfileSecret(secret.bytes),
        ]);
      }
      log.add('wrote identity ${fresh.id} seed ${keyTag(fresh.seed)}, secret ${keyTag(secret.bytes)}');
      final back = await keys.deviceIdentity();
      final secretBack = await keys.profileSecret();
      log.add('read back at once: identity ${back == null ? 'NONE' : back.id} (${back?.id == fresh.id ? 'same' : 'DIFFERENT'}), secret ${secretBack == null ? 'NONE' : keyTag(secretBack)} (${secretBack != null && keyTag(secretBack) == keyTag(secret.bytes) ? 'same' : 'DIFFERENT'})');
    }
  } catch (e, s) {
    log.add('FAIL $e\n$s');
  }
  await globalContext.callMethod<JSPromise<JSObject>>('fetch'.toJS, 'result'.toJS, {'method': 'POST', 'body': log.join('\n')}.jsify()).toDart;
}
