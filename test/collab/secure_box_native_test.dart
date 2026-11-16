import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/collab/secure_box.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
  final plain = Uint8List.fromList(List.generate(5000, (i) => i * 7));
  final dart = Xchacha20.poly1305Aead();

  test('what the box seals (libsodium) is read by the Dart cipher, with the associated data', () async {
    final sealed = await SecureBox(key).seal(plain, aad: [9, 8, 7]);
    final opened = await dart.decrypt(SecretBox.fromConcatenation(sealed, nonceLength: 24, macLength: 16), secretKey: SecretKey(key), aad: [9, 8, 7]);
    expect(opened, plain);
  });

  test('what the Dart cipher sealed (every file already on a cloud folder) is read by the box', () async {
    final box = await dart.encrypt(plain, secretKey: SecretKey(key), aad: [1]);
    expect(await SecureBox(key).open(Uint8List.fromList(box.concatenation()), aad: [1]), plain);
  });

  test('a changed message, another key or other associated data does not open', () async {
    final sealed = await SecureBox(key).seal(plain);
    final changed = Uint8List.fromList(sealed)..[30] ^= 1;
    await expectLater(SecureBox(key).open(changed), throwsA(isA<SecretBoxAuthenticationError>()));
    await expectLater(SecureBox(Uint8List(32)).open(sealed), throwsA(isA<SecretBoxAuthenticationError>()));
    await expectLater(SecureBox(key).open(sealed, aad: [1]), throwsA(isA<SecretBoxAuthenticationError>()));
  });

  test('a message that is too short is refused, not read', () async {
    await expectLater(SecureBox(key).open(Uint8List(10)), throwsA(anything));
    expect(await SecureBox(key).open(await SecureBox(key).seal(Uint8List(0))), isEmpty);
  });
}
