import 'dart:typed_data';

import 'math_decoder.dart';

/// TexTeller 3.0 (https://github.com/OleehyO/TexTeller, Apache-2.0) as the app runs it: a 448 x 448 gray picture in (see
/// `renderInkForTexTeller`), LaTeX token ids out. Its decoder has a cache of the keys and values of the tokens so far, so each
/// step is given only the last token (the formula reader of Pix2Text has no cache and is given them all every time).
const int texTellerStartToken = 0;
const int texTellerEosToken = 2;

/// A line of a worked solution is far shorter than this; it stops a model that got stuck in a loop.
const int texTellerMaxTokens = 200;

/// The decoder: 12 layers, each with the keys and values of its self attention (they grow) and of its attention to the
/// picture (they are worked out in the first step and stay), 16 heads of 64.
const int texTellerLayers = 12;
const int texTellerHeads = 16;
const int texTellerHeadSize = 64;

/// The two halves of TexTeller, however they are run (ONNX Runtime in the app, a fake in the tests).
abstract class TexTellerModel {
  /// The ids of the tokens the model reads from [pixels] (448 x 448), the start token first. Reads one picture at a time.
  Future<List<int>> read(Float32List pixels, {int maxTokens = texTellerMaxTokens});

  /// Lets go of what is loaded in memory.
  Future<void> close();
}

/// The index of the largest of the last [vocabSize] numbers of [scores] (the scores of every position so far, in a row; the
/// last position is the one that says what comes next).
int lastArgMax(List<dynamic> scores, int vocabSize) {
  final from = scores.length - vocabSize;
  var best = 0;
  var bestScore = double.negativeInfinity;
  for (var i = 0; i < vocabSize; i++) {
    final s = (scores[from + i] as num).toDouble();
    if (s > bestScore) {
      bestScore = s;
      best = i;
    }
  }
  return best;
}

/// The names the decoder gives the keys and values it is handed (`past_key_values.3.decoder.key`) and hands back
/// (`present.3.decoder.key`): self attention ([decoder] true) or the attention to the picture, key or value, of each layer.
Iterable<({String past, String present, bool decoder})> texTellerCacheNames() sync* {
  for (var layer = 0; layer < texTellerLayers; layer++) {
    for (final kind in const ['decoder', 'encoder']) {
      for (final part in const ['key', 'value']) {
        yield (past: 'past_key_values.$layer.$kind.$part', present: 'present.$layer.$kind.$part', decoder: kind == 'decoder');
      }
    }
  }
}

/// The LaTeX for [ids], as TexTeller wrote it (it writes LaTeX the way it is meant to be read, so the spaces stay: `\partial u`
/// is not `\partialu`), without the `\[ ... \]` it puts around every formula and with runs of spaces made one.
String texTellerLatex(MathVocab vocab, List<int> ids) => withoutDisplayFence(vocab.decodeRaw(ids)).replaceAll(RegExp(r'\s+'), ' ');

String withoutDisplayFence(String latex) {
  var s = latex.trim();
  if (s.startsWith(r'\[')) s = s.substring(2);
  if (s.endsWith(r'\]')) s = s.substring(0, s.length - 2);
  if (s.length >= 4 && s.startsWith(r'$$') && s.endsWith(r'$$')) s = s.substring(2, s.length - 2);
  return s.trim();
}
