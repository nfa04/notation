import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart' show DartPbkdf2;
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/lock/lock_crypto.dart';
import 'package:notes/lock/pbkdf2_native_io.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final native = pbkdf2IsNative;

  test('the system\'s OpenSSL gives the published PBKDF2-HMAC-SHA256 values', () {
    expect(hex(pbkdf2Native('password', Uint8List.fromList(utf8.encode('salt')), 1, 32)!), '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
    expect(hex(pbkdf2Native('password', Uint8List.fromList(utf8.encode('salt')), 4096, 32)!), 'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
  }, skip: native ? false : 'no OpenSSL on this machine');

  test('it gives what the Dart code gives, for a passphrase with other letters than ASCII', () async {
    final salt = Uint8List.fromList(List.generate(16, (i) => i * 7));
    const secret = 'Grüezi – 密码 🔑';
    final dart = await DartPbkdf2(macAlgorithm: Hmac.sha256(), iterations: 3000, bits: 256).deriveKeyFromPassword(password: secret, nonce: salt);
    expect(hex(pbkdf2Native(secret, salt, 3000, 32)!), hex(await dart.extractBytes()));
    // and the keys the app makes are the same ones, whichever does the work
    expect(hex(await deriveKey(secret, salt, 3000)), hex(await dart.extractBytes()));
  }, skip: native ? false : 'no OpenSSL on this machine');

  test('a new lock is made with the stronger count where the stretching is quick', () {
    expect(lockIterations, native ? 600000 : 250000);
  });
}
