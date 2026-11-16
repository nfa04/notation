import 'dart:async';
import 'dart:io' show File, pid;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// The next token of a language model's scores, picked inside ONNX Runtime (assets/onnx/pick_token.onnx, made by tool/make_pick_token.py):
/// two numbers come over to Dart instead of every score (59,392 for GLM-OCR). That copy and the loops over it took about 7.5 ms a token on
/// a Ryzen 7 8845HS, on the screen's thread. (A few nodes on the processor: never worth an accelerator.)
class TokenPicker {
  final OrtSession _session;
  TokenPicker._(this._session);

  static Future<TokenPicker> open() async {
    final options = OrtSessionOptions(intraOpNumThreads: 1, interOpNumThreads: 1);
    if (kIsWeb) return TokenPicker._(await OnnxRuntime().createSessionFromAsset(_asset, options: options));
    // (not createSessionFromAsset: it keeps the copy of an asset by its name only, so a changed model would never reach a device that
    // had the old one. The copy here is named by what is in it)
    final bytes = (await rootBundle.load(_asset)).buffer.asUint8List();
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash = ((hash ^ b) * 0x01000193) & 0xffffffff;
    }
    final file = File(p.join((await getTemporaryDirectory()).path, 'pick_token-${hash.toRadixString(16)}.onnx'));
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      final part = File('${file.path}.$pid.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);
    }
    return TokenPicker._(await OnnxRuntime().createSession(file.path, options: options));
  }

  static const _asset = 'assets/onnx/pick_token.onnx';

  /// The best token of the last position of [logits] ([1, T, vocabulary]; the first of equal ones) and its log probability. [logits] is
  /// not let go of.
  Future<({int token, double logProb})> pick(OrtValue logits) async {
    final out = await _session.run({'logits': logits});
    // (one output, read with one call; let go of without waiting: every call to the plugin costs, 2 to 3 ms on Linux)
    try {
      final both = await out['picked']!.asFlattenedList();
      return (token: (both[0] as num).round(), logProb: (both[1] as num).toDouble());
    } finally {
      for (final v in out.values) {
        unawaited(v.dispose());
      }
    }
  }

  Future<void> close() => _session.close();
}

