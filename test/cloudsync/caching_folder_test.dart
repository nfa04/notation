import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/caching_folder.dart';

import 'memory_cloud_folder.dart';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);
String _s(Uint8List? b) => String.fromCharCodes(b!);

void main() {
  late MemoryCloudFolder service;
  late CachingFolder folder;
  var now = DateTime(2026, 11, 9, 12);
  void pass(Duration d) => now = now.add(d);

  setUp(() async {
    now = DateTime(2026, 11, 9, 12);
    service = MemoryCloudFolder();
    folder = CachingFolder(service, clock: () => now);
    // what other devices published: written to the service directly, not through the cache
    await service.write('x1/m', _b('manifest of 1'));
    await service.write('x2/m', _b('manifest of 2'));
    await service.write('_profile/b', _b('bootstrap'));
    service.calls = 0;
  });

  test('a file that did not change is read once, and the stamps are asked once for all the reads', () async {
    expect(_s(await folder.read('x1/m')), 'manifest of 1');
    expect(service.calls, 2, reason: 'the stamps and the file');
    expect(_s(await folder.read('x1/m')), 'manifest of 1');
    expect(_s(await folder.read('x2/m')), 'manifest of 2');
    expect(service.calls, 3, reason: 'only the other device\'s file; the stamps count for all');
    expect(_s(await folder.read('x2/m')), 'manifest of 2');
    expect(service.calls, 3);
    expect(folder.hits, 2);
  });

  test('a file another device changed is read again once the stamps are asked again', () async {
    await folder.read('x1/m');
    await service.write('x1/m', _b('changed'));
    expect(_s(await folder.read('x1/m')), 'manifest of 1', reason: 'the stamps are still the ones of a moment ago');
    pass(const Duration(seconds: 16));
    expect(_s(await folder.read('x1/m')), 'changed');
    expect(_s(await folder.read('x1/m')), 'changed');
    expect(service.calls, 5, reason: 'stamps and file, the other device\'s write, stamps and file again - and the last read from what is kept');
  });

  test('invalidate: the next read sees what is up there now', () async {
    await folder.read('x1/m');
    await service.write('x1/m', _b('changed'));
    folder.invalidate();
    expect(_s(await folder.read('x1/m')), 'changed');
  });

  test('what this device writes or removes is not kept', () async {
    await folder.read('x1/m');
    await folder.write('x1/m', _b('mine'));
    expect(_s(await folder.read('x1/m')), 'mine');
    await folder.delete('x1/m');
    expect(await folder.read('x1/m'), isNull);
  });

  test('after the time a file counts for, it is read again whatever the stamps say', () async {
    await folder.read('x1/m');
    final before = service.calls;
    pass(const Duration(minutes: 11));
    await folder.read('x1/m');
    expect(service.calls - before, 2, reason: 'stamps and file');
  });

  test('a service that cannot say what changed is not cached', () async {
    service.canStamp = false;
    await folder.read('x1/m');
    await folder.read('x1/m');
    expect(folder.hits, 0);
    expect(_s(await folder.read('x1/m')), 'manifest of 1');
  });

  test('big files, and files deeper than one directory, are not kept', () async {
    final big = CachingFolder(service, clock: () => now, maxFileBytes: 4);
    await big.read('x1/m');
    await big.read('x1/m');
    expect(big.hits, 0, reason: 'bigger than the limit');
    await service.write('x1/n/note', _b('a note'));
    await folder.read('x1/n/note');
    await folder.read('x1/n/note');
    expect(folder.hits, 0, reason: 'two directories down');
  });

  test('a listing of a directory is kept until something in it changes', () async {
    expect(await folder.list('_profile'), ['b']);
    expect(await folder.list('_profile'), ['b']);
    expect(folder.hits, 1);
    await folder.write('_profile/j-1', _b('x'));
    expect((await folder.list('_profile')).toSet(), {'b', 'j-1'});
  });

  test('a file that is not there is not kept as missing', () async {
    expect(await folder.read('x3/m'), isNull);
    await service.write('x3/m', _b('now here'));
    folder.invalidate();
    expect(_s(await folder.read('x3/m')), 'now here');
  });

  test('a read that began before a change does not keep what it read', () async {
    final slow = Completer();
    service.hold = slow;
    final read = folder.read('x1/m');
    await Future<void>.delayed(Duration.zero);
    folder.invalidate();
    service.hold = null;
    slow.complete();
    await read;
    final before = service.calls;
    await folder.read('x1/m');
    expect(service.calls - before, greaterThan(0), reason: 'it had to go to the service again');
  });

  test('what the sync asked for itself is used by the reads that follow', () async {
    await folder.stamps('');
    service.calls = 0;
    await folder.read('x1/m');
    expect(service.calls, 1, reason: 'the file only: the stamps were just asked');
  });
}
