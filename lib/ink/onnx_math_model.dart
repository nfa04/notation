import 'dart:typed_data';

import '../llm/onnx_session.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'math_decoder.dart';

/// [MathOcrModel] on top of the two ONNX files (encoder and decoder).
///
/// The two sessions are not open together: the encoder (88 MB) is closed as soon
/// as it has run, before the decoder (32 MB) is loaded, so that a tablet with
/// little memory holds one model at a time. Sessions use a few threads and no
/// memory arena, which would keep what the decoder's ever-changing input sizes
/// ask for.
class OnnxMathModel implements MathOcrModel {
  final String _encoderPath;
  final String _decoderPath;
  final bool _keepEncoder;
  OrtSession? _decoder;
  OrtSession? _encoder;

  OnnxMathModel._(this._encoderPath, this._decoderPath, this._keepEncoder);

  /// With [keepEncoder] the encoder stays loaded until [close], for many
  /// pictures in a row (the handwriting reader); else it is closed after each
  /// picture to keep memory low (the big formula encoder).
  static Future<OnnxMathModel> open(String encoderPath, String decoderPath, {bool keepEncoder = false}) async =>
      OnnxMathModel._(encoderPath, decoderPath, keepEncoder);

  static final _options = OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1, useArena: false);

  @override
  Future<Object> encode(Float32List pixels) async {
    final encoder = _encoder ?? await openOnnxSession(_encoderPath, options: _options);
    if (_keepEncoder) _encoder = encoder;
    try {
      final input = await OrtValue.fromList(pixels, [1, 3, formulaImageSize, formulaImageSize]);
      final out = await encoder.run({'pixel_values': input});
      await input.dispose();
      final hidden = out['last_hidden_state'] ?? out.values.first;
      for (final e in out.entries) {
        if (!identical(e.value, hidden)) await e.value.dispose();
      }
      return hidden;
    } finally {
      if (!_keepEncoder) await encoder.close(); // before the decoder is loaded
    }
  }

  @override
  Future<int> nextToken(Object encoded, List<int> ids) async {
    final decoder = _decoder ??= await openOnnxSession(_decoderPath, options: _options, accelerate: false);
    final tokens = await int64Value(ids, [1, ids.length]);
    final out = await decoder.run({'input_ids': tokens, 'encoder_hidden_states': encoded as OrtValue});
    await tokens.dispose();
    final logits = out['logits'] ?? out.values.first;
    final flat = await logits.asFlattenedList(); // every position's scores: [1, ids.length, vocab]
    for (final v in out.values) {
      await v.dispose();
    }
    final vocab = flat.length ~/ ids.length;
    var best = 0;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < vocab; i++) {
      final score = (flat[flat.length - vocab + i] as num).toDouble();
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  @override
  Future<void> release(Object encoded) => (encoded as OrtValue).dispose();

  @override
  Future<void> close() async {
    await _encoder?.close();
    _encoder = null;
    await _decoder?.close();
    _decoder = null;
  }
}
