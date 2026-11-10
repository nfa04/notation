import 'dart:convert';
import 'dart:typed_data';


/// The side of the square picture the formula reader Pix2Text-MFR takes.
const int formulaImageSize = 384;

/// Pix2Text-MFR (a TrOCR retrained on formulas; MIT licence), run with ONNX
/// Runtime. Pictures are 384x384, normalised to -1..1, channels first; the
/// decoder has no cache, so it is given all tokens so far at every step.
const int mathStartToken = 1;
const int mathEosToken = 2;
const int mathMaxTokens = 120; // each token costs a pass over all the tokens before it

/// The two halves of the model, however they are run (ONNX Runtime in the app,
/// a fake in the tests).
abstract class MathOcrModel {
  /// Encodes the picture; the result is handed back to [nextToken] and finally
  /// to [release].
  Future<Object> encode(Float32List pixels);

  /// The most likely token after [ids].
  Future<int> nextToken(Object encoded, List<int> ids);

  Future<void> release(Object encoded);
  Future<void> close();
}

/// Picks the most likely token until the end token. Returns the ids including
/// the start token.
Future<List<int>> greedyDecodeMath(
  MathOcrModel model,
  Float32List pixels, {
  int maxTokens = mathMaxTokens,
  int startToken = mathStartToken,
  int eosToken = mathEosToken,
}) async {
  final encoded = await model.encode(pixels);
  try {
    final ids = [startToken];
    while (ids.length < maxTokens) {
      final token = await model.nextToken(encoded, ids);
      ids.add(token);
      if (token == eosToken) break;
    }
    return ids;
  } finally {
    await model.release(encoded);
  }
}

/// [renderInkForModel]'s pixels (rows of RGB, 0..1) as the formula model wants
/// them: channels first, -1..1.
Float32List toModelInput(Float32List rgb) {
  const n = formulaImageSize * formulaImageSize;
  final out = Float32List(3 * n);
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < 3; c++) {
      out[c * n + i] = (rgb[3 * i + c] - 0.5) / 0.5;
    }
  }
  return out;
}

/// Turns the formula model's token ids back into LaTeX.
class MathVocab {
  final List<String> tokens;

  const MathVocab(this.tokens);

  /// [source] is the vocabulary file: one token per line, in id order.
  factory MathVocab.parse(String source) => MathVocab(source.split('\n')..removeLast());

  static const int _firstRealToken = 5; // <pad> <s> </s> <unk> <mask>

  // the byte-level BPE writes every byte as a printable character (as GPT-2 does)
  static final Map<int, int> _byteOfChar = () {
    final visible = <int>[
      for (var b = 33; b <= 126; b++) b,
      for (var b = 161; b <= 172; b++) b,
      for (var b = 174; b <= 255; b++) b,
    ];
    final map = <int, int>{for (final b in visible) b: b};
    var next = 0;
    for (var b = 0; b < 256; b++) {
      if (!map.containsKey(b)) map[256 + next++] = b;
    }
    return map;
  }();

  /// The byte a character of a byte-level BPE vocabulary stands for (GPT-2's table; other readers of such vocabularies use it too).
  static Map<int, int> get byteOfBpeChar => _byteOfChar;

  /// LaTeX for [ids]; special tokens are left out.
  String decode(List<int> ids) => tidyLatex(decodeRaw(ids));

  /// The text of [ids] as the tokens spell it, without [tidyLatex]: for a model that writes its LaTeX the way it is meant to be
  /// read (TexTeller), where a space after a command (`\partial u`) means something.
  String decodeRaw(List<int> ids) {
    final bytes = <int>[];
    for (final id in ids) {
      if (id < _firstRealToken || id >= tokens.length) continue;
      for (final rune in tokens[id].runes) {
        final b = _byteOfChar[rune];
        if (b != null) bytes.add(b);
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static final _command = RegExp(r'^\\[A-Za-z]+$');
  static const _textCommands = {r'\text', r'\mbox', r'\mathrm', r'\operatorname', r'\textrm'};

  /// The model writes a space between all tokens ("\frac { a } { b }"). Takes
  /// out the spaces that mean nothing, but keeps the one that ends a command
  /// ("\alpha x") and the ones inside text ("\text{ for all }").
  static String tidyLatex(String spaced) {
    final tokens = spaced.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final out = StringBuffer();
    var textDepth = 0; // inside the braces of \text{...}
    var braceDepth = 0;
    var pendingText = false;
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (i > 0) {
        final prev = tokens[i - 1];
        final commandThenLetter = _command.hasMatch(prev) && RegExp(r'^[A-Za-z]').hasMatch(t);
        if (textDepth > 0 || commandThenLetter) out.write(' ');
      }
      out.write(t);
      if (_textCommands.contains(t)) {
        pendingText = true;
      } else if (t == '{') {
        braceDepth++;
        if (pendingText) {
          textDepth = braceDepth;
          pendingText = false;
        }
      } else if (t == '}') {
        if (textDepth == braceDepth) textDepth = 0;
        braceDepth--;
      } else {
        pendingText = false;
      }
    }
    return out.toString();
  }
}
