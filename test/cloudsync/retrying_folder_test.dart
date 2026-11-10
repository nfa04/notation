import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/cloudsync/cloud_folder.dart';

import 'memory_cloud_folder.dart';

/// Fails the first [failures] writes with [error], then works.
class Flaky extends MemoryCloudFolder {
  int failures;
  final Object error;
  int tries = 0;

  Flaky(this.failures, this.error);

  @override
  Future<void> write(String path, Uint8List bytes) async {
    tries++;
    if (failures > 0) {
      failures--;
      throw error;
    }
    return super.write(path, bytes);
  }
}

void main() {
  const fast = [Duration(milliseconds: 1), Duration(milliseconds: 1), Duration(milliseconds: 1)];
  final bytes = Uint8List.fromList([1, 2, 3]);

  test('a busy service (429, 503) and a dropped connection are tried again', () async {
    for (final error in <Object>[
      const CloudFolderException('slow down', 429),
      const CloudFolderException('busy', 503),
      DioException(requestOptions: RequestOptions(path: '/x'), type: DioExceptionType.connectionError),
    ]) {
      final inner = Flaky(2, error);
      await RetryingFolder(inner, delays: fast).write('a/b', bytes);
      expect(inner.tries, 3, reason: '$error');
      expect(inner.files['a/b'], bytes);
    }
  });

  test('a "no" (login, full, not allowed) is not tried again, and giving up is after the waits are used', () async {
    for (final error in [const CloudFolderException('login', 401), const CloudFolderException('full', 507), StateError('x')]) {
      final inner = Flaky(5, error);
      await expectLater(RetryingFolder(inner, delays: fast).write('a/b', bytes), throwsA(anything));
      expect(inner.tries, 1, reason: '$error');
    }
    final inner = Flaky(99, const CloudFolderException('busy', 503));
    await expectLater(RetryingFolder(inner, delays: fast).write('a/b', bytes), throwsA(isA<CloudFolderException>()));
    expect(inner.tries, 4, reason: 'the first try and one for each wait');
  });
}
