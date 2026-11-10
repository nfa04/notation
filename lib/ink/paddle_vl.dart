import 'dart:convert';
import 'dart:typed_data';

/// What PaddleOCR-VL 1.5 needs around its networks: the picture cut into patches, the words of the prompt, and the tokens turned
/// back into text. (The networks themselves are run by `onnx_paddle_vl.dart`.)
const paddleVlPatch = 14;
const paddleVlHiddenSize = 1024;

/// The sizes the picture of a line is drawn at: the model wants both sides a multiple of 28 (a patch of 14, two by two merged into
/// one token) and between about 113 000 and 1 000 000 pixels in all.
const paddleVlHeight = 112;
const paddleVlMinWidth = 1008; // (112 x 1008 is the fewest pixels it takes)
const paddleVlMaxWidth = 8960; // (112 x 8960 is the most)

/// The token ids of the prompt, `<s>User: <image>OCR:\nAssistant:\n`, around the picture (checked against the tokenizer of the model).
const paddleVlBeforeImage = [100273, 2969, 93963, 93919, 101305];
const paddleVlImageToken = 100295;
const paddleVlAfterImage = [101306, 93972, 2497, 93963, 23, 92267, 93963, 23];
const paddleVlEndToken = 2;

/// The prompt for a picture that is [gridHeight] x [gridWidth] patches: the picture takes one token for every 2 x 2 patches.
List<int> paddleVlPrompt(int gridHeight, int gridWidth) =>
    [...paddleVlBeforeImage, ...List.filled(gridHeight * gridWidth ~/ 4, paddleVlImageToken), ...paddleVlAfterImage];

/// The pixels [rgba] (4 bytes each, [width] x [height]) as the model takes them: every colour from -1 to 1, cut into patches of
/// 14 x 14, the rows of patches from top to bottom, each patch as three colour planes. Both sides must be a multiple of 28.
Float32List paddleVlPatches(Uint8List rgba, int width, int height) {
  assert(width % 28 == 0 && height % 28 == 0);
  final gh = height ~/ paddleVlPatch, gw = width ~/ paddleVlPatch;
  final out = Float32List(gh * gw * 3 * paddleVlPatch * paddleVlPatch);
  var i = 0;
  for (var py = 0; py < gh; py++) {
    for (var px = 0; px < gw; px++) {
      for (var c = 0; c < 3; c++) {
        for (var ky = 0; ky < paddleVlPatch; ky++) {
          var at = 4 * ((py * paddleVlPatch + ky) * width + px * paddleVlPatch) + c;
          for (var kx = 0; kx < paddleVlPatch; kx++) {
            out[i++] = rgba[at] / 127.5 - 1;
            at += 4;
          }
        }
      }
    }
  }
  return out;
}

/// The words of the model (`tokenizer.json`), to turn the tokens it wrote back into text.
class PaddleVlVocabulary {
  final List<String?> _pieces;
  final Set<int> _special;

  PaddleVlVocabulary._(this._pieces, this._special);

  factory PaddleVlVocabulary.parse(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    final vocab = (data['model'] as Map)['vocab'] as Map;
    final added = (data['added_tokens'] as List).cast<Map>();
    var size = 0;
    for (final v in vocab.values) {
      if ((v as int) >= size) size = v + 1;
    }
    for (final a in added) {
      if ((a['id'] as int) >= size) size = (a['id'] as int) + 1;
    }
    final pieces = List<String?>.filled(size, null);
    vocab.forEach((k, v) => pieces[v as int] = k as String);
    final special = <int>{};
    for (final a in added) {
      pieces[a['id'] as int] = a['content'] as String;
      if (a['special'] == true) special.add(a['id'] as int);
    }
    return PaddleVlVocabulary._(pieces, special);
  }

  /// The text of [ids]: a piece starts with `▁` where a space goes, and a letter that is no piece of its own is spelt in bytes
  /// (`<0xC3>`). The special tokens (start, end, picture) are left out.
  String decode(Iterable<int> ids) {
    final bytes = <int>[];
    final byteToken = RegExp(r'^<0x([0-9A-Fa-f]{2})>$');
    for (final id in ids) {
      if (id < 0 || id >= _pieces.length || _special.contains(id)) continue;
      final piece = _pieces[id];
      if (piece == null) continue;
      final m = byteToken.firstMatch(piece);
      if (m != null) {
        bytes.add(int.parse(m[1]!, radix: 16));
      } else {
        bytes.addAll(utf8.encode(piece.replaceAll('▁', ' ')));
      }
    }
    return utf8.decode(bytes, allowMalformed: true).trim();
  }
}

/// The tokens with a stuck model's loop taken off the end: when the last stretch of 1 to 8 tokens was written four times over, only
/// the first of them is kept. (A model that cannot read a line sometimes repeats a word until it runs out of room.)
List<int> withoutLoop(List<int> tokens) {
  for (var n = 1; n <= 8; n++) {
    var times = 1;
    while (tokens.length >= n * (times + 1) && _sameStretch(tokens, tokens.length - n, tokens.length - n * (times + 1), n)) {
      times++;
    }
    if (times >= 4) return tokens.sublist(0, tokens.length - n * (times - 1));
  }
  return tokens;
}

bool _sameStretch(List<int> t, int a, int b, int n) {
  for (var i = 0; i < n; i++) {
    if (t[a + i] != t[b + i]) return false;
  }
  return true;
}
