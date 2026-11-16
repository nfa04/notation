import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Whether the `cryptography` package is the one of `cryptography_flutter` (Android, iOS and macOS: the plugin puts itself in, the
/// system's own code does the ciphers; elsewhere, and in tests on a computer, it is not). Asked of the package itself, not of the
/// platform the app thinks it is on. It only works on the main isolate.
bool get platformCryptoOn => !kIsWeb && Cryptography.instance is FlutterCryptography;

/// Whether the stretching of a passphrase (PBKDF2) is done by the system: only Android does (on iOS and macOS the plugin has the
/// ciphers but PBKDF2 is Dart code, so it is as slow as anywhere and is better kept off the main isolate).
bool get platformPbkdf2On => platformCryptoOn && defaultTargetPlatform == TargetPlatform.android;

/// The most a plugin cipher is asked to do on the main isolate: above this the plugin has no limit that is safe on a phone (a big input
/// is computed on the calling isolate, in Dart), so the work goes to an isolate of its own.
const platformCryptoMostBytes = 4 * 1024 * 1024;
