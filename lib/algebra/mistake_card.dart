import '../ai/flashcards.dart';
import 'checker.dart';

/// What the front of a mistake card starts with (the line of working follows it).
const mistakeFront = 'Find the mistake in this line of working:\n';

/// Whether a card is one of a mistake ([mistakeCard]).
bool isMistakeCard(String front) => front.startsWith(mistakeFront);

/// The line of working of a mistake card's front.
String mistakeLineOf(String front) => isMistakeCard(front) ? front.substring(mistakeFront.length) : front;

String _tidy(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A flashcard from a line of maths that was found wrong, to ask about it again later: the line is on the front ("Find the mistake"),
/// what is wrong and what it should be on the back. Null for a line that is no problem, or that has nothing but the verdict to
/// say (the card could not teach anything). [headline] says in words what is wrong with it; [expectedLabel] and [counterLabel] are
/// the words in front of what it should be and the example (what the sheet of the mark says).
Flashcard? mistakeCard(String latex, LineCheck check,
    {required String headline, String expectedLabel = 'It should be:', String counterLabel = 'For example:', int? page}) {
  final line = _tidy(latex);
  if (!check.isProblem || line.isEmpty) return null;
  final expected = check.expected, counter = check.counter;
  if (expected == null && counter == null) return null;
  final back = StringBuffer('$headline.');
  if (expected != null) back.write('\n$expectedLabel ${_tidy(expected)}');
  if (counter != null) back.write('\n$counterLabel ${_tidy(counter)}');
  return Flashcard('$mistakeFront$line', back.toString(), page: page);
}
