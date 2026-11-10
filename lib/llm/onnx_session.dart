
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
// ignore: implementation_imports
import 'package:flutter_onnxruntime/src/flutter_onnxruntime_platform_interface.dart' show FlutterOnnxruntimePlatform;

import '../web/blob_url_io.dart' if (dart.library.js_interop) '../web/blob_url_web.dart';
import '../web/web_files.dart';

/// Opens the model at [path]. In a browser the runtime takes an address, not a path: the file (kept in IndexedDB, see
/// lib/web/web_files_web.dart) is read and handed to the runtime under a name (web/index.html), with as few copies as possible: the
/// runtime has its own once it has the session, and nothing else is left.
Future<OrtSession> openOnnxSession(String path, {OrtSessionOptions? options}) async {
  if (!kIsWeb) return OnnxRuntime().createSession(path, options: options);
  final name = handOverBytes(await webFileBytes(path));
  try {
    return await OnnxRuntime().createSession(name, options: options);
  } finally {
    forgetBytes(name);
    await releaseWebFile(path);
  }
}

/// A tensor of 64-bit whole numbers (the ids of tokens, the masks, the positions). A browser has no `Int64List` (it throws), so
/// there the numbers are handed over as a list and the runtime makes its BigInt array of them (see web/index.html).
Future<OrtValue> int64Value(List<int> values, List<int> shape) async {
  if (kIsWeb) return OrtValue.fromMap(await FlutterOnnxruntimePlatform.instance.createOrtValue('int64', values, shape));
  return OrtValue.fromList(Int64List.fromList(values), shape);
}
