import 'dart:typed_data';

/// The browser has WebCrypto, which the `cryptography` package uses by itself.
bool get pbkdf2IsNative => false;

Uint8List? pbkdf2Native(String password, Uint8List salt, int iterations, int bytes) => null;
