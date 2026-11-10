import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/devicesync/sync_devices.dart';

/// A keystore whose entries cannot be opened, as the browser's one is after two first writes made two keys (the read throws).
class _Unreadable implements FlutterSecureStorage {
  final writes = <String, String>{};
  bool broken = true;

  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (broken) throw StateError('OperationError: The operation failed for an operation-specific reason');
    return writes[key];
  }

  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    writes[key] = value!;
    broken = false; // (a new write is made with the key that is stored now, and opens)
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('an entry of the keystore that cannot be opened is an absent one, and writing it again repairs it', () async {
    final store = _Unreadable();
    final keys = KeystoreSyncKeys(store);
    expect(await keys.deviceIdentity(), isNull);
    expect(await keys.profileSecret(), isNull);
    expect(await keys.deviceSeed(), isNull);

    final seed = Uint8List.fromList(List.generate(32, (i) => i));
    await keys.setDeviceIdentity((id: 'abcdabcdabcdabcd', seed: seed));
    final back = await keys.deviceIdentity();
    expect(back?.id, 'abcdabcdabcdabcd');
    expect(back?.seed, seed);
  });
}
