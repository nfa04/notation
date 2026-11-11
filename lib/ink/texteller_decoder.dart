import 'dart:math' as math;
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

/// What a reading came to, with how sure the model was of it: the log of the probability it gave the whole line (the scores of the tokens
/// it chose, added up; 0 is certain, and the more negative, the less sure). A line it is unsure of is more often wrong (93 % of the
/// lines above -0.1 were read right, 63 % of the others), which is when another reading with another pen is worth the time.
class TexTellerReading {
  final List<int> ids;
  final double logProb;
  const TexTellerReading(this.ids, this.logProb);
}

/// A [TexTellerModel] that can also say how sure it is of what it read.
abstract class ScoredTexTeller implements TexTellerModel {
  Future<TexTellerReading> readScored(Float32List pixels, {int maxTokens = texTellerMaxTokens});
}

/// How readily a formula is read again with a thinner and a thicker pen (the surest of the three is kept): when the model's log
/// probability for the line is below [doubtBelow]. On 1000 MathWriting lines "normal" is about one in ten and brings all of what
/// reading every line three times does (+2 points exact: 78.7 % to 80.7 %) at a fifth more work; "often" is about three in ten.
enum SecondLook {
  off('off', double.negativeInfinity),
  rarely('rarely', -1.5),
  normal('normal', -0.8),
  often('often', -0.3);

  final String id;
  final double doubtBelow;
  const SecondLook(this.id, this.doubtBelow);
}

/// The default.
const SecondLook texTellerSecondLook = SecondLook.normal;

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

/// The log probability (softmax over the last [vocabSize] numbers of [scores]) of the token [token] at the last position.
double lastLogProb(List<dynamic> scores, int vocabSize, int token) {
  final from = scores.length - vocabSize;
  var top = double.negativeInfinity;
  for (var i = 0; i < vocabSize; i++) {
    final v = (scores[from + i] as num).toDouble();
    if (v > top) top = v;
  }
  var sum = 0.0;
  for (var i = 0; i < vocabSize; i++) {
    sum += math.exp((scores[from + i] as num).toDouble() - top);
  }
  return (scores[from + token] as num).toDouble() - top - math.log(sum);
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
