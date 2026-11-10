import 'dart:convert';

/// The tokenizer of BERT-style models (WordPiece, lower-cased) from the model's
/// `tokenizer.json`, as the sentence-embedding models use it: text goes in as
/// ids between `[CLS]` and `[SEP]`.
class WordPieceTokenizer {
  final Map<String, int> _vocab;
  final int unk, cls, sep;
  final String _prefix;
  final int _maxWordChars;
  final bool _lowercase;

  WordPieceTokenizer._(this._vocab, this.unk, this.cls, this.sep, this._prefix, this._maxWordChars, this._lowercase);

  /// Reads the contents of `tokenizer.json`.
  factory WordPieceTokenizer.parse(String json) {
    final data = jsonDecode(json) as Map<String, Object?>;
    final model = data['model'] as Map<String, Object?>;
    if (model['type'] != 'WordPiece') throw FormatException('not a WordPiece tokenizer: ${model['type']}');
    final vocab = (model['vocab'] as Map).map((k, v) => MapEntry(k as String, v as int));
    final normalizer = data['normalizer'];
    final lowercase = normalizer is Map ? normalizer['lowercase'] != false : true;
    int id(String token) => vocab[token] ?? (throw FormatException('no $token in the vocabulary'));
    return WordPieceTokenizer._(
      vocab,
      id((model['unk_token'] as String?) ?? '[UNK]'),
      id('[CLS]'),
      id('[SEP]'),
      (model['continuing_subword_prefix'] as String?) ?? '##',
      (model['max_input_chars_per_word'] as int?) ?? 100,
      lowercase,
    );
  }

  /// Letters that split into a plain letter and an accent ("é" is "e" and an accent), as a BERT
  /// strips them ("Café" -> "cafe"); letters like ø, ł and ß have no such split and stay.
  static final Map<int, String> _unaccent = () {
    const table = {
      'a': 'àáâãäåāăą',
      'c': 'çćĉċč',
      'd': 'ď',
      'e': 'èéêëēĕėęě',
      'g': 'ĝğġģ',
      'h': 'ĥ',
      'i': 'ìíîïĩīĭį',
      'j': 'ĵ',
      'k': 'ķ',
      'l': 'ĺļľ',
      'n': 'ñńņň',
      'o': 'òóôõöōŏő',
      'r': 'ŕŗř',
      's': 'śŝşš',
      't': 'ţť',
      'u': 'ùúûüũūŭůűų',
      'w': 'ŵ',
      'y': 'ýÿŷ',
      'z': 'źżž',
    };
    return {
      for (final e in table.entries)
        for (final r in e.value.runes) r: e.key,
    };
  }();

  static bool _isCjk(int c) =>
      (c >= 0x4E00 && c <= 0x9FFF) ||
      (c >= 0x3400 && c <= 0x4DBF) ||
      (c >= 0x20000 && c <= 0x2A6DF) ||
      (c >= 0xF900 && c <= 0xFAFF) ||
      (c >= 0x2F800 && c <= 0x2FA1F);

  static final _punctuation = RegExp(r'[\p{P}]|[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E]', unicode: true);
  static final _whitespace = RegExp(r'\s', unicode: true);

  /// The words of [text]: cleaned, lower-cased, split at spaces and around punctuation and Chinese characters.
  List<String> words(String text) {
    final cleaned = StringBuffer();
    for (final r in text.runes) {
      if (r == 0 || r == 0xFFFD || (r < 32 && r != 9 && r != 10 && r != 13)) continue; // control characters
      final ch = String.fromCharCode(r);
      if (_whitespace.hasMatch(ch)) {
        cleaned.write(' ');
      } else if (_isCjk(r)) {
        cleaned.write(' $ch ');
      } else if (_lowercase) {
        // lower-case, then without accents: "É" -> "é" -> "e"; combining marks go
        for (final l in ch.toLowerCase().runes) {
          if (l >= 0x300 && l <= 0x36F) continue;
          cleaned.write(_unaccent[l] ?? String.fromCharCode(l));
        }
      } else {
        cleaned.write(ch);
      }
    }
    final out = <String>[];
    for (final chunk in cleaned.toString().split(' ')) {
      if (chunk.isEmpty) continue;
      var word = StringBuffer();
      for (final r in chunk.runes) {
        final ch = String.fromCharCode(r);
        if (_punctuation.hasMatch(ch)) {
          if (word.isNotEmpty) out.add(word.toString());
          word = StringBuffer();
          out.add(ch);
        } else {
          word.write(ch);
        }
      }
      if (word.isNotEmpty) out.add(word.toString());
    }
    return out;
  }

  /// The pieces of one word, longest match first; a word with a part that is not
  /// in the vocabulary is the unknown token as a whole.
  List<int> _pieces(String word) {
    final chars = word.runes.map(String.fromCharCode).toList();
    if (chars.length > _maxWordChars) return [unk];
    final ids = <int>[];
    var start = 0;
    while (start < chars.length) {
      var end = chars.length;
      int? found;
      while (start < end) {
        final piece = (start > 0 ? _prefix : '') + chars.sublist(start, end).join();
        final id = _vocab[piece];
        if (id != null) {
          found = id;
          break;
        }
        end--;
      }
      if (found == null) return [unk];
      ids.add(found);
      start = end;
    }
    return ids;
  }

  /// The token ids of [text] without the markers around them.
  List<int> tokens(String text) => [for (final w in words(text)) ..._pieces(w)];

  /// [text] as `[CLS] ... [SEP]`, cut to at most [maxLength] ids.
  List<int> encode(String text, {int maxLength = 256}) {
    final t = tokens(text);
    return [cls, ...t.take(maxLength - 2), sep];
  }

  /// Several windows of [text] of at most [window] tokens each, for text longer than the model reads at once.
  List<List<int>> windows(String text, {int window = 256, int most = 4}) {
    final t = tokens(text);
    if (t.isEmpty) return [];
    final room = window - 2;
    return [
      for (var i = 0; i < t.length && i ~/ room < most; i += room) [cls, ...t.skip(i).take(room), sep],
    ];
  }
}
