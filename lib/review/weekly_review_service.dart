import '../ai/ai_service.dart';
import '../ai/reading_agent.dart';
import '../ai/text_provider.dart';
import '../data/card_repository.dart';
import '../data/note_repository.dart';
import '../data/task_repository.dart';
import '../l10n/language.dart';
import 'review_agent_api.dart';
import 'weekly_review.dart';

/// Makes the weekly review: gathers what happened in a week from the notes, the facts the graph found in them, the tasks, the
/// calendar and the flashcards, lets the assistant write a summary when it can, and keeps the result as a note.
class WeeklyReviewService {
  final NoteRepository repository;
  final TaskRepository tasks;

  /// The flashcards kept for review; null: none are mentioned.
  final CardRepository? cards;

  /// The events of the calendars between two days; null: none are mentioned.
  final Future<List<ReviewEvent>> Function(DateTime from, DateTime to)? events;

  /// The assistant; null: the review has no summary.
  final AiService? ai;

  /// Whether the AI features are on (the switch in the settings); null: always.
  final bool Function()? aiEnabled;
  final DateTime Function() _now;

  WeeklyReviewService({required this.repository, required this.tasks, this.cards, this.events, this.ai,
    this.aiEnabled, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  /// The folder the reviews are kept in.
  static String get folderName => tr('Reviews');

  /// Today, for choosing this week or the one before.
  DateTime get today => _now();

  bool get assistantReady =>
      (aiEnabled?.call() ?? true) && ai?.provider?.state == ProviderState.ready;

  static DateTime _plusDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

  /// What the week of [weekOf] (any day in it) holds.
  Future<WeekReviewData> gather(DateTime weekOf) async {
    final from = weekStart(weekOf), to = _plusDays(from, 7);
    final folders = await repository.listFolders();
    final reviews = {for (final f in folders) if (f.parentId == null && f.name == folderName) f.id};

    final all = [for (final n in await repository.listNotes()) if (!n.locked && !reviews.contains(n.folderId)) n];
    final inWeek = [for (final n in all) if (!n.updatedAt.isBefore(from) && n.updatedAt.isBefore(to)) n]..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final notes = <ReviewNote>[];
    for (final n in inWeek) {
      final created = (await repository.noteTimes(n.id))?.created;
      notes.add(ReviewNote(n.id, n.title, n.updatedAt, isNew: created != null && !created.isBefore(from) && created.isBefore(to)));
    }
    final weekIds = {for (final n in notes) n.id};

    // what the graph knows: the facts of this week's notes, and the older notes that talk about the same things
    final facts = <ReviewFact>[];
    final olderFacts = <String, List<ReviewFact>>{};
    for (final f in await repository.knowledge.allFacts()) {
      final fact = ReviewFact(noteId: f.noteId, title: f.title, tag: f.tag, sentence: f.sentence, keywords: f.keywords);
      if (weekIds.contains(f.noteId)) {
        facts.add(fact);
      } else {
        (olderFacts[f.noteId] ??= []).add(fact);
      }
    }
    final olderNotes = {for (final n in all) if (!weekIds.contains(n.id)) n.id: ReviewNote(n.id, n.title, n.updatedAt)};
    final related = relatedOlderNotes(facts, olderFacts, olderNotes);

    final done = <ReviewTask>[], open = <ReviewTask>[], next = <ReviewTask>[];
    final nextEnd = _plusDays(to, 7);
    for (final t in await tasks.listTasks()) {
      if (t.done) {
        if (t.doneAt != null && !t.doneAt!.isBefore(from) && t.doneAt!.isBefore(to)) done.add(ReviewTask(t.title, due: t.dueDate, doneAt: t.doneAt));
      } else if (t.dueDate != null && !t.dueDate!.isBefore(to) && t.dueDate!.isBefore(nextEnd)) {
        next.add(ReviewTask(t.title, due: t.dueDate));
      } else if (t.dueDate == null || t.dueDate!.isBefore(to)) {
        open.add(ReviewTask(t.title, due: t.dueDate));
      }
    }
    open.sort((a, b) => (a.due ?? DateTime(9999)).compareTo(b.due ?? DateTime(9999)));
    next.sort((a, b) => a.due!.compareTo(b.due!));

    List<ReviewEvent> coming = const [];
    try {
      coming = await events?.call(to, nextEnd) ?? const [];
    } catch (_) {
      // a calendar that cannot be read leaves the week ahead without events
    }
    return WeekReviewData(
      from: from,
      to: to,
      notes: notes,
      facts: facts,
      done: done,
      open: open.take(15).toList(),
      dueNextWeek: next,
      nextWeek: coming,
      related: related,
      cardsDue: await cards?.dueCount() ?? 0,
    );
  }

  /// The id of the note that holds the review of the week of [weekOf], if it was made.
  Future<String?> existing(DateTime weekOf) async {
    final title = reviewTitle(weekStart(weekOf));
    for (final f in await repository.listFolders()) {
      if (f.parentId != null || f.name != folderName) continue;
      for (final n in await repository.listNotes()) {
        if (n.folderId == f.id && n.title == title) return n.id;
      }
    }
    return null;
  }

  /// Makes (or makes again) the review of the week of [weekOf] and answers the id of its note. With [withAssistant], and when the
  /// assistant is ready, it is given the review as made here, reads the notes behind it (only reading: see `readingTools`) and writes
  /// what the week was about and suggestions for the next; a model that cannot do that writes a short summary from the review alone,
  /// and if that fails too the review is made without them. [onStatus] says what is going on.
  Future<String> make(DateTime weekOf, {bool withAssistant = true, AiCancel? cancel, void Function(String status)? onStatus}) async {
    onStatus?.call(tr('Gathering the week...'));
    final data = await gather(weekOf);
    String? summary, plan;
    final model = ai;
    if (withAssistant && model != null && assistantReady && !data.isEmpty) {
      onStatus?.call(tr('The assistant is reading the notes...'));
      String? answer;
      try {
        // the assistant starts from the review as the app makes it, and reads the notes behind it to say what the week was about
        answer = await runReadingAgent(
          model,
          api: ReviewAgentApi(repository, tasks),
          system: reviewAgentSystem,
          request: reviewAgentRequest(reviewMarkdown(data)),
          cancel: cancel,
          onStep: onStatus,
        );
      } catch (_) {
        // (a model that cannot work with tools, or that gets lost in them, still writes a short summary from the review alone)
        if (!(cancel?.cancelled ?? false)) {
          onStatus?.call(tr('The assistant is writing...'));
      try {
            answer =await model.generate(reviewPrompt(data), maxTokens: 450, cancel: cancel);
          } catch (_) {
            // the review is worth having without the words of the assistant
          }
        }
      }
      if (answer != null) {
        final parsed = parseReviewAnswer(answer);
        summary = parsed.summary;
        plan = parsed.plan;
      }
    }
    final markdown = reviewMarkdown(data, summary: summary, plan: plan);
    final title = reviewTitle(data.from);
    final old = await existing(weekOf);
    final folder = await _folder();
    final id = old ?? await repository.createNote(title: title, folderId: folder);
    final note = (await repository.loadNote(id))!;
    note.documentText = markdown;
    await repository.saveNote(note);
    return id;
  }

  Future<String> _folder() async {
    for (final f in await repository.listFolders()) {
      if (f.parentId == null && f.name == folderName) return f.id;
    }
    return repository.createFolder(folderName);
  }
}
