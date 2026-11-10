import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../net/extra_roots.dart';

/// Downloads [url] to [path], saying how far it got (0 to 1) when the size is known.
///
/// A connection that gets nowhere, or one that goes quiet half way, ends with an error instead of a progress bar that never moves.
/// In a browser there is no download to a file: the bytes are fetched and written to the file (in memory, kept in IndexedDB; see
/// lib/web/web_files_web.dart). The browser's own request has no "quiet for a minute" timer, so it only gets an overall one there.
/// Only servers that allow it can be fetched from a page (CORS): Hugging Face does, GitHub's release files do not.
Future<void> downloadToFile(String url, String path, [void Function(double)? progress]) async {
  void onProgress(int got, int total) {
    if (total > 0) progress?.call(got / total);
  }

  if (!kIsWeb) {
    await trustBundledRoots();
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(minutes: 1)));
    // a certificate that is not accepted is still refused, but said who it was: that is what tells a machine that lacks a root from
    // a program or a network that puts its own certificate in the way (an antivirus that scans secure connections, a proxy)
    String? refused;
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..badCertificateCallback = (cert, host, port) {
          refused = '$host:$port presented a certificate for "${cert.subject}" issued by "${cert.issuer}"';
          return false;
        },
    );
    try {
      await dio.download(url, path, onReceiveProgress: onProgress);
    } on DioException catch (e) {
      if (refused != null && e.error is HandshakeException) throw HandshakeException('${(e.error as HandshakeException).message}\nThe certificate was refused: $refused');
      rethrow;
    }
    return;
  }
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(hours: 1)));
  final r = await dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes), onReceiveProgress: onProgress);
  final data = r.data ?? const <int>[];
  await File(path).writeAsBytes(data is Uint8List ? data : Uint8List.fromList(data), flush: true);
}
