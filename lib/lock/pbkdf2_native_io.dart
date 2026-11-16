import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _Pbkdf2C = Int32 Function(Pointer<Uint8> pass, Int32 passLen, Pointer<Uint8> salt, Int32 saltLen, Int32 iter, Pointer<Void> md, Int32 keyLen, Pointer<Uint8> out);
typedef _Pbkdf2 = int Function(Pointer<Uint8> pass, int passLen, Pointer<Uint8> salt, int saltLen, int iter, Pointer<Void> md, int keyLen, Pointer<Uint8> out);
typedef _Sha256C = Pointer<Void> Function();
typedef _Sha256 = Pointer<Void> Function();

({_Pbkdf2 derive, _Sha256 sha256})? _load() {
  if (!Platform.isLinux) return null;
  for (final name in const ['libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so']) {
    try {
      final lib = DynamicLibrary.open(name);
      return (derive: lib.lookupFunction<_Pbkdf2C, _Pbkdf2>('PKCS5_PBKDF2_HMAC'), sha256: lib.lookupFunction<_Sha256C, _Sha256>('EVP_sha256'));
    } catch (_) {
      // (not this one)
    }
  }
  return null;
}

final _openssl = _load();

/// Whether the system's OpenSSL does the stirring of a passphrase (Linux): measured on a desktop at 600 000 rounds: 83 ms, against
/// 2.3 s for the Dart code of the `cryptography` package, with the same result.
bool get pbkdf2IsNative => _openssl != null;

/// PBKDF2-HMAC-SHA256 of [password] (as UTF-8) with [salt], [bytes] long, by OpenSSL; null where it is not there (the caller uses Dart).
Uint8List? pbkdf2Native(String password, Uint8List salt, int iterations, int bytes) {
  final ssl = _openssl;
  if (ssl == null) return null;
  final pass = password.toNativeUtf8();
  final saltPtr = calloc<Uint8>(salt.isEmpty ? 1 : salt.length);
  final out = calloc<Uint8>(bytes);
  try {
    saltPtr.asTypedList(salt.length).setAll(0, salt);
    final ok = ssl.derive(pass.cast<Uint8>(), pass.length, saltPtr, salt.length, iterations, ssl.sha256(), bytes, out);
    return ok == 1 ? Uint8List.fromList(out.asTypedList(bytes)) : null;
  } finally {
    calloc.free(pass);
    calloc.free(saltPtr);
    calloc.free(out);
  }
}
