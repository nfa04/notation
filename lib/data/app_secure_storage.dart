import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one keystore the app uses for its secrets (passwords, tokens, the keys of locked notes and of paired devices).
///
/// On macOS the plugin uses the "data protection" keychain unless told otherwise, and that one only works for an app that is signed
/// by an Apple developer team (it needs a keychain entitlement from a provisioning profile): otherwise every call fails with
/// error -34018. Notation is also handed out as a download that is not signed with a team, so there the ordinary keychain is used,
/// which works for any signed or ad-hoc signed app. Nothing changes on the other platforms.
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

/// Makes the browser's keystore ready before anything uses it. The web keystore encrypts every entry with one key that it makes when the
/// first entry is written; two entries written at the same moment on a fresh browser each make a key, the second replaces the first
/// in the browser, and what was written with the first can never be read again (the read throws, and what it held - the identity of
/// this device, the secret of its profile - is gone at the next load). Writing one entry first, alone, makes the key before the rest
/// ask for it. Nothing to do on the other platforms.
Future<void> warmUpSecureStorage() async {
  if (!kIsWeb) return;
  try {
    await appSecureStorage.write(key: 'keystore_ready', value: '1');
  } catch (e) {
    debugPrint('The keystore of the browser could not be prepared: $e');
  }
}
