import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// The next token of a language model's scores, picked inside ONNX Runtime (assets/onnx/pick_token.onnx, made by tool/make_pick_token.py):
/// two numbers come over to Dart instead of every score (59,392 for GLM-OCR). That copy and the loops over it took about 7.5 ms a token on
/// a Ryzen 7 8845HS, on the screen's thread. (A few nodes on the processor: never worth an accelerator.)
class TokenPicker {
  final OrtSession _session;
  TokenPicker._(this._session);

  static Future<TokenPicker> open() async =>
      TokenPicker._(await OnnxRuntime().createSessionFromAsset('assets/onnx/pick_token.onnx', options: OrtSessionOptions(intraOpNumThreads: 1, interOpNumThreads: 1)));

  /// The best token of the last position of [logits] ([1, T, vocabulary]; the first of equal ones) and its log probability. [logits] is
  /// not let go of.
  Future<({int token, double logProb})> pick(OrtValue logits) async {
    final out = await _session.run({'logits': logits});
    try {
      final token = (await out['token']!.asFlattenedList()).single as num;
      final logProb = (await out['log_prob']!.asFlattenedList()).single as num;
      return (token: token.toInt(), logProb: logProb.toDouble());
    } finally {
      for (final v in out.values) {
        await v.dispose();
      }
    }
  }

  Future<void> close() => _session.close();
}

