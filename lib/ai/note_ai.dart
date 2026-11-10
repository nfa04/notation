import '../data/note_data.dart';
import '../data/note_repository.dart';
import '../automations/note_sorter.dart';
import '../l10n/language.dart';
import 'ai_prompt.dart';
import 'ai_service.dart';
import 'document_index.dart';
import 'note_knowledge.dart';
import 'text_provider.dart';

/// What the AI can make of a whole note. The result is kept with the note (in the database and in the note file), so it is
/// made once and shown from then on, until the person asks for it to be made again.
enum NoteAiKind {
  summary('summary', 'Summary', 'The main points of the note, in a short text.'),
  presentation('presentation', 'Presentation', 'Slides made from the note, to show or to export as a PDF.'),
  studyGuide('studyGuide', 'Study guide', 'An outline with the key terms and what to remember.'),
  quiz('quiz', 'Quiz', 'Multiple-choice questions to test yourself on the note.'),
  actions('actions', 'Action items', 'The tasks and dates that the note mentions, to add to the calendar.');

  final String id;
  final String label;
  final String description;
  const NoteAiKind(this.id, this.label, this.description);

  static NoteAiKind? byId(String id) => values.where((k) => k.id == id).firstOrNull;
}

/// Makes and keeps what the AI makes of a note.
class NoteAi {
  final NoteRepository _notes;
  final AiService ai;

  NoteAi(this._notes, this.ai);

  /// A fingerprint of the text of the note now, to tell that it changed after something was made from it.
  Future<int> currentHash(String noteId) async => NoteSorter.hashOf((await chunksOfNote(_notes, noteId)).map((c) => c.text).join('\n'));

  Future<NoteAiRow?> saved(String noteId, NoteAiKind kind) => _notes.ai.get(noteId, kind.id);

  /// Whether the note has changed since [row] was made.
  Future<bool> isStale(NoteAiRow row) async => row.sourceHash != 0 && row.sourceHash != await currentHash(row.noteId);

  Future<void> delete(String noteId, NoteAiKind kind) => _notes.ai.delete(noteId, kind.id);

  /// What the AI made of the note of this [kind] before, or - when there is none or [again] - makes it now and keeps it.
  /// [onPartial] gets the text as it is written; cancelling [cancel] keeps nothing.
  Future<NoteAiRow> get(
    String noteId,
    NoteAiKind kind, {
    bool again = false,
    void Function(String partial)? onPartial,
    AiCancel? cancel,
  }) async {
    if (!again) {
      final kept = await saved(noteId, kind);
      if (kept != null) return kept;
    }
    final chunks = await chunksOfNote(_notes, noteId);
    if (chunks.every((c) => c.text.trim().isEmpty)) throw StateError(tr('The note has no text to work from.'));
    final index = DocumentIndex(chunks);
    // a long note is read as an even spread of it; a short one whole
    final passages = index.select('', ai.contextChars).text;
    final hash = NoteSorter.hashOf(chunks.map((c) => c.text).join('\n'));
    final provider = ai.provider;
    if (provider == null) throw StateError(tr('No AI provider is set up.'));

    final prompt = _prompt(kind, passages);
    var text = await provider.complete(prompt.$1, maxTokens: prompt.$2, onPartial: onPartial, cancel: cancel);
    if (cancel?.cancelled ?? false) throw StateError(tr('(stopped)'));
    text = text.trim();
    if (text.isEmpty) throw StateError(tr('The model gave no answer.'));
    final problem = _check(kind, text);
    if (problem != null) throw StateError(problem);

    final row = NoteAiRow(
      noteId: noteId,
      kind: kind.id,
      content: text,
      sourceHash: hash,
      model: provider is SelectableModels ? (provider as SelectableModels).selectedModelId : provider.id,
      createdAt: DateTime.now(),
    );
    await _notes.ai.put(row);
    return row;
  }

  static (AiPrompt, int) _prompt(NoteAiKind kind, String passages) {
    const language = 'Write in the language of the passages. Do not invent anything that is not in them.';
    switch (kind) {
      case NoteAiKind.summary:
        return (
          AiPrompt(
            system: 'You summarize a student\'s notes. $language',
            user: 'Notes:\n$passages\n\nSummarize them in a short paragraph and then a bullet list (lines starting with "- ") of the main points.',
          ),
          450,
        );
      case NoteAiKind.presentation:
        return (
          AiPrompt(
            system: 'You turn notes into a slide presentation. $language Write exactly in this form and nothing else:\n'
                '# Title of the presentation\n'
                '## Title of a slide\n'
                '- a short bullet\n'
                '- another bullet\n'
                '> what the speaker says (one or two sentences)\n'
                'Make 6 to 10 slides with 2 to 5 short bullets each; the last slide sums up.',
            user: 'Notes:\n$passages\n\nMake the presentation.',
          ),
          1100,
        );
      case NoteAiKind.studyGuide:
        return (
          AiPrompt(
            system: 'You make study guides from notes. $language Use Markdown: a "# " heading, "## " headings for the topics, '
                'bullets for the facts, **bold** for key terms, and at the end a section "## Remember" with the five most important points.',
            user: 'Notes:\n$passages\n\nMake the study guide.',
          ),
          900,
        );
      case NoteAiKind.quiz:
        return (
          AiPrompt(
            system: 'You write multiple-choice questions to test a student on their notes. $language Write each question exactly like this:\n'
                'Q: the question\n'
                'A) first choice\n'
                'B) second choice\n'
                'C) third choice\n'
                'D) fourth choice\n'
                'Answer: the letter of the right choice\n'
                'Why: one sentence\n'
                'Put a blank line between questions. Only one choice is right. Write nothing else.',
            user: 'Notes:\n$passages\n\nWrite 6 questions.',
          ),
          900,
        );
      case NoteAiKind.actions:
        return (
          AiPrompt(
            system: 'You find the tasks in notes: things the writer has to do, hand in or prepare. $language Write one per line, exactly like '
                '"- the task (due: YYYY-MM-DD)", and leave "(due: ...)" out when the notes name no day. If there are no tasks, write "None".',
            user: 'Notes:\n$passages\n\nList the tasks.',
          ),
          400,
        );
    }
  }

  /// Why [text] is not a usable answer for [kind], or null.
  static String? _check(NoteAiKind kind, String text) {
    switch (kind) {
      case NoteAiKind.presentation:
        return parseSlides(text).slides.length < 2 ? tr('The model did not write a presentation. Try again.') : null;
      case NoteAiKind.quiz:
        return parseQuiz(text).isEmpty ? tr('The model did not write questions in the form asked for. Try again.') : null;
      default:
        return null;
    }
  }
}

// ---- presentation ------------------------------------------------------------------

/// One slide of a generated presentation: a title, its bullet points and what to say aloud.
class Slide {
  final String title;
  final List<String> bullets;
  final String notes;
  const Slide(this.title, this.bullets, this.notes);
}

/// A generated presentation (see [parseSlides]); kept with the note and exportable as a PDF.
class Presentation {
  final String title;
  final List<Slide> slides;
  const Presentation(this.title, this.slides);
}

/// The slides in what the model wrote: `# title`, then `## slide`, `- bullet` and `> speaker notes`. Anything else is ignored; a
/// line of text under a slide counts as a bullet.
Presentation parseSlides(String text) {
  var title = '';
  final slides = <Slide>[];
  String? slide;
  var bullets = <String>[];
  var notes = StringBuffer();

  void finish() {
    if (slide != null) slides.add(Slide(slide!, bullets, notes.toString().trim()));
    slide = null;
    bullets = [];
    notes = StringBuffer();
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim().replaceAll('**', '');
    if (line.isEmpty || line.startsWith('```')) continue;
    if (line.startsWith('## ')) {
      finish();
      slide = line.substring(3).trim();
    } else if (line.startsWith('# ')) {
      if (title.isEmpty && slide == null && slides.isEmpty) {
        title = line.substring(2).trim();
      } else {
        finish();
        slide = line.substring(2).trim();
      }
    } else if (slide == null) {
      continue;
    } else if (line.startsWith('>')) {
      notes.write('${notes.isEmpty ? '' : ' '}${line.substring(1).trim()}');
    } else {
      bullets.add(line.replaceFirst(RegExp(r'^([-*•]|\d+[.)])\s*'), ''));
    }
  }
  finish();
  return Presentation(title.isEmpty && slides.isNotEmpty ? slides.first.title : title, slides);
}

// ---- quiz ----------------------------------------------------------------------------

/// A multiple-choice question of a generated quiz, with the reason the right choice is right.
class QuizQuestion {
  final String question;
  final List<String> choices;

  /// Index into [choices].
  final int answer;
  final String why;
  const QuizQuestion(this.question, this.choices, this.answer, this.why);
}

/// The questions in what the model wrote (`Q:`, `A)`..`D)`, `Answer:`, `Why:`). A question needs at least two choices and a right one.
List<QuizQuestion> parseQuiz(String text) {
  final out = <QuizQuestion>[];
  String? q;
  var choices = <String>[];
  int? answer;
  var why = '';

  void finish() {
    if (q != null && choices.length >= 2 && answer != null && answer! < choices.length) out.add(QuizQuestion(q!, choices, answer!, why.trim()));
    q = null;
    choices = [];
    answer = null;
    why = '';
  }

  final question = RegExp(r'^(?:\d+[.)]\s*)?(?:Q(?:uestion)?\s*\d*\s*[:.)]|Frage\s*\d*\s*[:.)])\s*(.+)$', caseSensitive: false);
  final choice = RegExp(r'^([A-Ha-h])\s*[).:]\s*(.+)$');
  final right = RegExp(r'^(?:Answer|Antwort|Correct)\s*[:.]?\s*\(?([A-Ha-h])\)?', caseSensitive: false);
  final reason = RegExp(r'^(?:Why|Explanation|Warum|Begründung)\s*[:.]\s*(.*)$', caseSensitive: false);
  for (final raw in text.split('\n')) {
    final line = raw.trim().replaceAll('**', '');
    if (line.isEmpty) continue;
    final a = right.firstMatch(line);
    if (a != null && q != null) {
      answer = a.group(1)!.toUpperCase().codeUnitAt(0) - 65;
      continue;
    }
    final r = reason.firstMatch(line);
    if (r != null && q != null) {
      why = r.group(1)!;
      continue;
    }
    final c = choice.firstMatch(line);
    if (c != null && q != null) {
      choices.add(c.group(2)!.trim());
      continue;
    }
    final m = question.firstMatch(line);
    if (m != null) {
      finish();
      q = m.group(1)!.trim();
      continue;
    }
    if (q != null && choices.isEmpty) q = '$q $line';
  }
  finish();
  return out;
}

// ---- action items --------------------------------------------------------------------

/// A task the model found in a note; [due] is null when the note names no date.
class ActionItem {
  final String title;
  final DateTime? due;
  const ActionItem(this.title, this.due);
}

/// The tasks in what the model wrote: `- task (due: 2026-11-05)`.
List<ActionItem> parseActions(String text) {
  final out = <ActionItem>[];
  final due = RegExp(r'\(?\s*due\s*:?\s*(\d{4})-(\d{2})-(\d{2})\s*\)?', caseSensitive: false);
  for (final raw in text.split('\n')) {
    var line = raw.trim().replaceAll('**', '');
    if (!RegExp(r'^([-*•]|\d+[.)])\s+').hasMatch(line)) continue;
    line = line.replaceFirst(RegExp(r'^([-*•]|\d+[.)])\s+(\[[ xX]\]\s*)?'), '');
    DateTime? day;
    final m = due.firstMatch(line);
    if (m != null) {
      day = DateTime.tryParse('${m.group(1)}-${m.group(2)}-${m.group(3)}');
      line = line.replaceFirst(m.group(0)!, '');
    }
    line = line.trim().replaceAll(RegExp(r'[\s,;-]+$'), '');
    if (line.isNotEmpty && line.toLowerCase() != 'none') out.add(ActionItem(line, day));
  }
  return out;
}
