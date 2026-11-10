import 'dart:convert';

/// Turns the numbers Whisper writes back into text: the tokens are pieces of text in a byte-level alphabet (every byte has a
/// printable stand-in), so the pieces are put together, the stand-ins turned back into bytes, and the bytes read as UTF-8.
class WhisperTokenizer {
  final List<String?> _pieces;
  static final Map<String, int> _byteOf = () {
    final printable = <int>[for (var b = 33; b <= 126; b++) b, for (var b = 161; b <= 172; b++) b, for (var b = 174; b <= 255; b++) b];
    final map = <String, int>{};
    var extra = 0;
    for (var b = 0; b < 256; b++) {
      if (printable.contains(b)) {
        map[String.fromCharCode(b)] = b;
      } else {
        map[String.fromCharCode(256 + extra++)] = b;
      }
    }
    return map;
  }();

  WhisperTokenizer._(this._pieces);

  /// The first id of the special tokens (<|endoftext|>); ids from here on are not text.
  static const firstSpecial = 50257;

  factory WhisperTokenizer.parse(String tokenizerJson) {
    final m = jsonDecode(tokenizerJson) as Map;
    final vocab = ((m['model'] as Map)['vocab'] as Map).cast<String, int>();
    final pieces = List<String?>.filled(vocab.values.fold<int>(0, (a, b) => a > b ? a : b) + 1, null);
    for (final e in vocab.entries) {
      pieces[e.value] = e.key;
    }
    return WhisperTokenizer._(pieces);
  }

  String decode(Iterable<int> ids) {
    final bytes = <int>[];
    for (final id in ids) {
      if (id >= firstSpecial || id < 0 || id >= _pieces.length) continue;
      final piece = _pieces[id];
      if (piece == null) continue;
      for (final rune in piece.runes) {
        final b = _byteOf[String.fromCharCode(rune)];
        if (b != null) bytes.add(b);
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
