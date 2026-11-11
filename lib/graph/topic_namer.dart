import '../ai/ai_prompt.dart';

/// A topic as the model is shown it: its number, the words it is known by so far, and titles of some of what is in it.
class TopicSample {
  final int index;
  final String words;
  final List<String> titles;
  const TopicSample(this.index, this.words, this.titles);
}

/// The request that names topics (the model is only asked for names: which node is in which topic stays what the structure says, so a
/// graph is the same with or without a model).
AiPrompt topicNamePrompt(List<TopicSample> topics) {
  final lines = StringBuffer();
  for (final t in topics) {
    lines.writeln('${t.index} (words: ${t.words}): ${t.titles.join('; ')}');
  }
  return AiPrompt(
    system: 'You name groups of notes or facts. For each numbered group give a short name of 2 to 4 words that says what the group is '
        'about, in the language of its titles, in the form a book chapter would have (a noun phrase, no verbs, no quotation marks). '
        'Answer with one line per group, exactly "number | name", and nothing else.',
    user: lines.toString().trimRight(),
    exact: true,
  );
}

/// The names in a model's [reply] by topic number; lines that are not of the form "number | name", names that are empty or too long to be a
/// name, and numbers not in [wanted] are left out.
Map<int, String> parseTopicNames(String reply, Set<int> wanted) {
  final out = <int, String>{};
  for (final line in reply.split('\n')) {
    final m = RegExp(r'^\s*[*\-#]*\s*(\d+)\s*[|:.)\-–]\s*(.+?)\s*$').firstMatch(line);
    if (m == null) continue;
    final number = int.parse(m[1]!);
    if (!wanted.contains(number) || out.containsKey(number)) continue;
    var name = m[2]!.replaceAll(RegExp(r'''["“”„'`*_]+'''), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    name = name.replaceFirst(RegExp(r'[.;:,]+$'), '');
    if (name.isEmpty || name.length > 60 || name.split(' ').length > 8) continue;
    out[number] = name;
  }
  return out;
}
