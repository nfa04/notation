/// Cloze cards: a text with parts hidden as `{{c1::answer}}` (or `{{c1::answer::hint}}`), as Anki writes them. Each number is a card
/// of its own: that part is hidden, the others are shown.
final clozePattern = RegExp(r'\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}', dotAll: true);

/// Whether [text] hides anything.
bool hasCloze(String text) => clozePattern.hasMatch(text);

/// The numbers of the parts [text] hides, in order, each once.
List<int> clozeNumbers(String text) => ({for (final m in clozePattern.allMatches(text)) int.parse(m[1]!)}.toList()..sort());

/// [text] with the hidden part [number] as `[...]` (or `[hint]`) in the question, and shown in the answer; the other parts are shown
/// in both. Plain text, as Anki shows it.
(String, String) clozeSides(String text, int number) {
  final front = text.replaceAllMapped(clozePattern, (m) => int.parse(m[1]!) == number ? '[${(m[3] ?? '').isEmpty ? '...' : m[3]}]' : m[2]!);
  final back = text.replaceAllMapped(clozePattern, (m) => m[2]!);
  return (front, back);
}

/// As [clozeSides], with what is asked for in bold (Markdown), so that it stands out on the card.
(String, String) clozeFaces(String text, int number) {
  final front = text.replaceAllMapped(clozePattern, (m) => int.parse(m[1]!) == number ? '**[${(m[3] ?? '').isEmpty ? '...' : m[3]}]**' : m[2]!);
  final back = text.replaceAllMapped(clozePattern, (m) => int.parse(m[1]!) == number ? '**${m[2]}**' : m[2]!);
  return (front, back);
}

/// [text] with the characters from [start] to [end] hidden as the next number (one more than the highest there is). Nothing is hidden
/// when the range is empty or cuts into a part that is hidden already.
String hideAsCloze(String text, int start, int end) {
  if (start < 0 || end > text.length || start >= end) return text;
  for (final m in clozePattern.allMatches(text)) {
    if (start < m.end && end > m.start) return text;
  }
  final chosen = text.substring(start, end);
  final lead = chosen.length - chosen.trimLeft().length, trail = chosen.length - chosen.trimRight().length;
  if (chosen.trim().isEmpty) return text;
  final s = start + lead, e = end - trail;
  final numbers = clozeNumbers(text);
  final n = numbers.isEmpty ? 1 : numbers.last + 1;
  return '${text.substring(0, s)}{{c$n::${text.substring(s, e)}}}${text.substring(e)}';
}
