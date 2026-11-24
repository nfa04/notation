import 'dart:math' as math;
import 'package:flutter/material.dart' hide Text;
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'package:flutter/services.dart';

import '../ai/ai_service.dart';
import '../ai/assistant_chat.dart';
import '../ai/citations.dart';
import '../ai/flashcards.dart' show Flashcard;
import '../ai/line_diff.dart';
import '../ai/note_agent.dart';
import '../ai/note_ai.dart' show NoteAiKind;
import '../ai/note_lookup.dart';
import '../ai/openai_provider.dart' show OpenAiProvider;
import '../ai/text_provider.dart';
import '../ink/ink_recognizer.dart' show DownloadableModel;
import '../markdown/chat_markdown.dart';
import '../markdown/markdown_view.dart';
import '../models/rich_text.dart';
import 'add_to_note.dart';
import 'flashcard_view.dart';
import 'openai_model_switcher.dart';

/// Questions and answers about the whole document, beside it (or over it on a
/// narrow screen). Who answers is the AI provider chosen in the Settings.
class AssistantPanel extends StatefulWidget {
  final AiService ai;
  final AssistantChat chat;
  /// Closes the panel (it sits beside a note, or in a window); null: it is a page of its own and has no close button.
  final VoidCallback? onClose;

  /// Takes the reader to a page (zero-based) an answer points at.
  final ValueChanged<int>? onJumpToPage;

  /// Goes to a page and lights up [quote] (a few words of it) there: where an answer's source is.
  final void Function(int page, String quote)? onShowPassage;

  /// Puts an answer on the note.
  final AddToNote? onAddToNote;

  /// Whether the flashcards are offered.
  final bool flashcards;

  /// Keeps flashcards for spaced repetition; null: not offered.
  final Future<int> Function(List<Flashcard> cards)? onKeepCards;

  /// For a conversation about all notes: takes the reader to the note (and page, zero-based) an answer drew on.
  final void Function(String noteId, int? page, {String? quote})? onOpenSource;

  /// Makes (or shows, when it was made before) something of the note: a summary, presentation, study guide, quiz or the tasks
  /// in it; with null, shows the list of all of them. Null: not offered.
  final void Function(NoteAiKind? kind)? onMake;

  /// The heading, the line that invites a question and the suggestions, when they are not about one document.
  final String? title;
  final String? invitation;
  final List<String>? suggestions;

  const AssistantPanel({
    super.key,
    required this.ai,
    required this.chat,
    this.onClose,
    this.onJumpToPage,
    this.onShowPassage,
    this.onAddToNote,
    this.flashcards = true,
    this.onKeepCards,
    this.onOpenSource,
    this.onMake,
    this.title,
    this.invitation,
    this.suggestions,
  });

  @override
  State<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<AssistantPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _shown = 0;

  /// Questions to start with; what the AI can make of the note (a summary, ...) is offered apart from them.
  static const _suggestions = ['What are the key points?', 'What are the key terms and what do they mean?', 'What is unclear or missing?'];

  /// What to start with when the assistant acts on the note.
  static const _notesAgentSuggestions = ['Make a note that sums up my notes about exams', 'Put my notes about travel in a folder called Travel', 'Add a task for every deadline I wrote down'];

  /// Whether the panel is about all notes, not one.
  bool get _allNotes => widget.title != null;

  static const _agentSuggestions = ['Give this note a clear structure with headings', 'Fix the spelling mistakes', 'Turn the to-dos in this note into tasks'];

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_followAnswer);
    _input.addListener(_typed);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_followAnswer);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the newest text in view while it is being written.
  void _followAnswer() {
    final count = widget.chat.messages.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (widget.chat.busy || count != _shown) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
      _shown = count;
    });
  }

  /// The notes the person picked after an `@` in what they are writing, and the ones offered now for the word they are typing.
  final List<NoteRef> _refs = [];
  List<NoteRef> _offered = const [];
  int _mentionFrom = -1;
  int _lookups = 0;

  /// The `@word` the cursor is at the end of, if any: offers the notes that fit it.
  void _typed() async {
    final lookup = widget.chat.lookup;
    final at = _input.selection.baseOffset;
    final before = at < 0 ? _input.text : _input.text.substring(0, at.clamp(0, _input.text.length));
    final m = lookup == null ? null : RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(before);
    if (m == null) {
      if (_offered.isNotEmpty) setState(() => _offered = const []);
      return;
    }
    final mine = ++_lookups;
    final found = await lookup!.find(m[1]!);
    if (!mounted || mine != _lookups) return;
    setState(() {
      _mentionFrom = before.length - m[1]!.length - 1;
      _offered = found;
    });
  }

  /// Puts `@Title` where the `@word` was, and remembers the note.
  void _pick(NoteRef ref) {
    final at = _input.selection.baseOffset.clamp(0, _input.text.length);
    final text = _input.text;
    final insert = '@${ref.title} ';
    _input.value = TextEditingValue(
      text: text.replaceRange(_mentionFrom.clamp(0, at), at, insert),
      selection: TextSelection.collapsed(offset: _mentionFrom.clamp(0, at) + insert.length),
    );
    if (!_refs.any((r) => r.id == ref.id)) _refs.add(ref);
    setState(() => _offered = const []);
  }

  void _send([String? text]) {
    final q = text ?? _input.text;
    if (q.trim().isEmpty || widget.chat.busy) return;
    // (a note whose @Title was taken out of the text again is not meant any more)
    final refs = [for (final r in _refs) if (q.contains('@${r.title}')) r];
    _input.clear();
    _refs.clear();
    setState(() => _offered = const []);
    widget.chat.ask(q, refs: refs);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.ai, widget.chat]),
        builder: (context, _) {
          final provider = widget.ai.provider;
          final chat = widget.chat;
          return Column(children: [
            _header(context, provider),
            if (chat.agent != null && !chat.cardMode) _modeSwitch(context, chat),
            const Divider(height: 1),
            Expanded(child: _body(context, provider, chat)),
            const Divider(height: 1),
            _footer(context, provider, chat),
          ]);
        },
      ),
    );
  }

  Widget _header(BuildContext context, TextModelProvider? provider) {
    String name = provider?.label ?? 'No provider';
    if (provider is SelectableModels) {
      final models = provider as SelectableModels;
      final chosen = models.modelOptions.where((o) => o.id == models.selectedModelId).firstOrNull;
      if (chosen != null) name = '${tr(name)} - ${tr(chosen.label)}';
    }
    if (provider is OpenAiProvider && provider.config.model.isNotEmpty) name = '${tr(name)} - ${provider.config.model}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(children: [
        const Icon(Icons.auto_awesome, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.verbatim(widget.title ?? tr('Ask about this document'), style: Theme.of(context).textTheme.titleSmall),
            Text(name, key: const ValueKey('assistant-model'), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        OpenAiModelSwitcher(ai: widget.ai, compact: true),
        if (widget.ai.providers.length > 1)
          PopupMenuButton<String>(
            key: const ValueKey('assistant-provider'),
            tooltip: tr('Who answers (the model is chosen in the Settings)'),
            icon: const Icon(Icons.swap_horiz, size: 20),
            onSelected: widget.ai.chooseProvider,
            itemBuilder: (context) => [
              for (final p in widget.ai.providers)
                CheckedPopupMenuItem(
                  value: p.id,
                  checked: p.id == provider?.id,
                  enabled: p.state != ProviderState.unavailable,
                  child: Text(p.label),
                ),
            ],
          ),
        if (widget.onMake != null)
          IconButton(
            key: const ValueKey('assistant-note-ai'),
            tooltip: tr('What the AI made of this note, and what it can make'),
            icon: const Icon(Icons.auto_fix_high_outlined, size: 20),
            onPressed: () => widget.onMake!(null),
          ),
        if (widget.flashcards)
        IconButton(
          key: const ValueKey('assistant-flashcards'),
          tooltip: tr(widget.chat.cardMode ? 'Back to the conversation' : 'Flashcards'),
          icon: Icon(Icons.style_outlined, size: 20, color: widget.chat.cardMode ? Theme.of(context).colorScheme.primary : null),
          onPressed: () => widget.chat.openFlashcards(!widget.chat.cardMode),
        ),
        IconButton(
          key: const ValueKey('assistant-clear'),
          tooltip: tr('Start a new conversation'),
          icon: const Icon(Icons.delete_sweep_outlined, size: 20),
          onPressed: widget.chat.messages.isEmpty ? null : widget.chat.clear,
        ),
        if (widget.onClose != null) IconButton(key: const ValueKey('assistant-close'), tooltip: tr('Close'), icon: const Icon(Icons.close, size: 20), onPressed: widget.onClose),
      ]),
    );
  }

  /// Whether the assistant only answers, or acts on the note.
  Widget _modeSwitch(BuildContext context, AssistantChat chat) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            key: const ValueKey('assistant-mode'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(value: false, icon: const Icon(Icons.chat_bubble_outline, size: 16), label: const Text('Ask'), tooltip: _allNotes ? tr('Answers questions; your notes stay as they are') : tr('Answers questions; the note stays as it is')),
              ButtonSegment(value: true, icon: const Icon(Icons.auto_fix_normal, size: 16), label: const Text('Agent'), tooltip: _allNotes ? tr('Works on your notes, tasks and calendar; it asks before each change') : tr('Works on the note; it asks before each change')),
            ],
            selected: {chat.acting},
            onSelectionChanged: chat.busy ? null : (v) => chat.acting = v.first,
          ),
        ),
      );

  static IconData _kindIcon(NoteAiKind kind) => switch (kind) {
        NoteAiKind.summary => Icons.short_text,
        NoteAiKind.presentation => Icons.slideshow_outlined,
        NoteAiKind.studyGuide => Icons.menu_book_outlined,
        NoteAiKind.quiz => Icons.quiz_outlined,
        NoteAiKind.actions => Icons.checklist,
      };

  Widget _body(BuildContext context, TextModelProvider? provider, AssistantChat chat) {
    final scheme = Theme.of(context).colorScheme;
    if (chat.cardMode) {
      return FlashcardView(
        chat: chat,
        ready: provider?.state == ProviderState.ready,
        onJumpToPage: widget.onJumpToPage,
        onAddToNote: widget.onAddToNote == null ? null : (text) => widget.onAddToNote!(text, AddTarget.textBox),
        onKeep: widget.onKeepCards,
      );
    }
    if (chat.messages.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        Text.verbatim(
          chat.acting && _allNotes
              ? tr('Tell the assistant what to do with your notes: find, make, file, tag or trash notes, and add tasks, reminders and events. It asks before each change.')
              : chat.acting
              ? tr('Tell the assistant what to do with this note: format it, rewrite parts of it, add to it, make tasks from it. It asks before each change, and every change can be undone in the note.')
              : widget.invitation ?? tr('Ask anything about this document: its pages, your notes and text boxes are read for every question.'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in chat.acting ? (_allNotes ? _notesAgentSuggestions : _agentSuggestions) : widget.suggestions ?? _suggestions)
            ActionChip(
              key: ValueKey('assistant-suggestion-$s'),
              label: Text(s),
              onPressed: provider?.state == ProviderState.ready ? () => _send(tr(s)) : null,
            ),
        ]),
        if (widget.onMake != null || widget.flashcards) ...[
          const SizedBox(height: 20),
          Text('Make something from this note', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text('It is kept with the note, so it is made only once.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (widget.onMake != null)
              for (final kind in NoteAiKind.values)
                ActionChip(
                  key: ValueKey('assistant-make-${kind.id}'),
                  avatar: Icon(_kindIcon(kind), size: 16),
                  label: Text(kind.label),
                  tooltip: tr(kind.description),
                  onPressed: provider?.state == ProviderState.ready ? () => widget.onMake!(kind) : null,
                ),
            if (widget.flashcards)
              ActionChip(
                key: const ValueKey('assistant-suggestion-flashcards'),
                avatar: const Icon(Icons.style_outlined, size: 16),
                label: const Text('Flashcards'),
                tooltip: tr('Cards to learn the note by, one question each.'),
                onPressed: provider?.state == ProviderState.ready ? () => widget.chat.openFlashcards() : null,
              ),
          ]),
        ],
      ]);
    }
    return ListView.builder(
      key: const ValueKey('assistant-messages'),
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: chat.messages.length + (chat.busy ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == chat.messages.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Row(children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator.adaptive(strokeWidth: 2)),
              const SizedBox(width: 8),
              Expanded(child: Text(chat.status, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
            ]),
          );
        }
        return _bubble(context, chat.messages[i], i);
      },
    );
  }

  Widget _bubble(BuildContext context, ChatMessage m, int i) {
    final scheme = Theme.of(context).colorScheme;
    if (m.fromUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          key: ValueKey('assistant-question-$i'),
          margin: const EdgeInsets.only(bottom: 8, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
          child: SelectableText(m.text, style: TextStyle(color: scheme.onPrimaryContainer)),
        ),
      );
    }
    final done = !(widget.chat.busy && i == widget.chat.messages.length - 1);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: ValueKey('assistant-answer-$i'),
        margin: const EdgeInsets.only(bottom: 8, right: 24),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        decoration: BoxDecoration(
          color: m.failed ? scheme.errorContainer : null,
          border: m.failed ? null : Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var j = 0; j < m.steps.length; j++) _step(context, m.steps[j], i, j),
          if (m.text.isNotEmpty)
            m.failed
                ? SelectableText(m.text, style: TextStyle(color: scheme.onErrorContainer))
                : ChatText(
                    done && (m.check?.cited ?? false) ? m.check!.linked : m.text,
                    key: ValueKey('assistant-text-$i'),
                    color: scheme.onSurface,
                    onLink: (link) {
                      final n = link.startsWith('cite:') ? int.tryParse(link.substring(5)) : null;
                      final sources = m.check?.sources;
                      if (n != null && sources != null && n >= 1 && n <= sources.length) _openSource(sources[n - 1].mark, sources[n - 1].quote);
                    },
                  ),
          if (done && m.check != null) ..._sourcesOf(context, m, i, scheme),
          if (done && !m.failed && !(m.check?.cited ?? false) && m.pages.isNotEmpty && widget.onJumpToPage != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('Pages:', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                for (final p in m.pages)
                  ActionChip(
                    key: ValueKey('assistant-page-${p + 1}'),
                    label: Text('${p + 1}'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    onPressed: () => widget.onJumpToPage!(p),
                  ),
              ]),
            ),
          if (done && !m.failed && !(m.check?.cited ?? false) && m.sources.isNotEmpty && widget.onOpenSource != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text.verbatim('${tr('From')}:', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                for (final s in m.sources)
                  ActionChip(
                    key: ValueKey('assistant-source-${s.noteId}-${s.page ?? ''}'),
                    label: Text.verbatim(s.page == null ? s.title : '${s.title}, ${tr('p.')} ${s.page! + 1}'),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    onPressed: () => widget.onOpenSource!(s.noteId, s.page),
                  ),
              ]),
            ),
          if (done && m.cutOff && i == widget.chat.messages.length - 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextButton.icon(
                key: const ValueKey('assistant-continue'),
                icon: const Icon(Icons.keyboard_double_arrow_down, size: 16),
                label: Text(tr('The answer was cut off: continue')),
                onPressed: widget.chat.continueAnswer,
              ),
            ),
          if (done && (m.failed || (m.text.trim().isNotEmpty && m.text != '(stopped)')))
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (!m.failed) ...[
                IconButton(
                  tooltip: tr('Copy'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 16),
                  onPressed: () => Clipboard.setData(ClipboardData(text: m.text)),
                ),
                if (widget.onAddToNote != null)
                  AddToNoteMenu(
                    buttonKey: ValueKey('assistant-add-$i'),
                    onSelected: (target) => widget.onAddToNote!(m.text, target),
                  ),
              ],
              // (asked again, an answer that acted on the note would act again: only answers that changed nothing)
              if (i == widget.chat.messages.length - 1 && m.steps.isEmpty)
                IconButton(
                  key: const ValueKey('assistant-retry'),
                  tooltip: tr('Ask again'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed: widget.chat.retry,
                ),
              if (m.given.isNotEmpty)
                IconButton(
                  key: ValueKey('assistant-given-$i'),
                  tooltip: tr('What the assistant read'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.article_outlined, size: 16),
                  onPressed: () => _showGiven(context, m.given),
                ),
            ])
          else
            const SizedBox(height: 4),
        ]),
      ),
    );
  }

  /// One source of an answer: its number (as in the text), where it is (opens the place with the words lit up), what it says there
  /// as the note has it, and a warning, with why, when it does not seem to say what the answer says.
  Widget _sourceRow(CitedSource src, int i, int n, ColorScheme scheme, TextStyle small, String Function(KnownMark) label, void Function(KnownMark, String) open) {
    final reason = src.reason;
    final why = reason == null
        ? null
        : reason.startsWith('numbers:')
            ? '${tr('The passage does not have this number:')} ${reason.substring(8)}'
            : tr('The passage has few of the words of the statement: it may say it differently, or not at all.');
    return Padding(
      key: ValueKey('assistant-source-row-$i-$n'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 22, child: Text.verbatim('${n + 1}', style: small.copyWith(fontWeight: FontWeight.w500))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              ActionChip(
                key: ValueKey('assistant-cite-$i-$n'),
                avatar: why != null
                    ? Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error, key: ValueKey('assistant-cite-doubt-$i-$n'))
                    : src.handwriting
                        ? Icon(Icons.draw_outlined, size: 16, key: ValueKey('assistant-cite-ink-$i-$n'))
                        : null,
                label: Text.verbatim(label(src.mark)),
                tooltip: src.handwriting ? tr('Read from handwriting by the app: it can be misread.') : null,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: () => open(src.mark, src.quote),
              ),
            ]),
            for (final e in src.evidence)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: ChatText(e, color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            if (why != null)
              Text(
                '$why${src.better == null ? '' : ' ${tr('Perhaps')}: ${label(src.better!)}'}',
                key: ValueKey('assistant-source-why-$i-$n'),
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
          ]),
        ),
      ]),
    );
  }

  /// Goes to a source an answer names: the note and page, with [quote] (a few words of it) lit up.
  void _openSource(KnownMark k, String quote) {
    if (k.noteId.isNotEmpty && widget.onOpenSource != null) {
      widget.onOpenSource!(k.noteId, k.page, quote: quote.isEmpty ? null : quote);
    } else if (k.page != null && quote.isNotEmpty && widget.onShowPassage != null) {
      widget.onShowPassage!(k.page!, quote);
    } else if (k.page != null && widget.onJumpToPage != null) {
      widget.onJumpToPage!(k.page!);
    }
  }

  /// The answers whose list of sources is shown whole (the first few are shown otherwise).
  final _allSources = <int>{};

  /// Where the answer says it comes from: the passages it names, each opening its place, marked when the passage does not seem to
  /// say what the answer says there; and a word when it names nothing, or something it was not given.
  List<Widget> _sourcesOf(BuildContext context, ChatMessage m, int i, ColorScheme scheme) {
    final check = m.check!;
    final small = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final open = _openSource;

    String label(KnownMark k) => k.title.isEmpty
        ? (k.page == null ? k.mark : '${tr('p.')} ${k.page! + 1}')
        : (k.page == null ? k.title : '${k.title}, ${tr('p.')} ${k.page! + 1}');

    return [
      if (check.cited)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.verbatim('${tr('Sources')}:', style: small.copyWith(fontWeight: FontWeight.w500)),
            for (var n = 0; n < (_allSources.contains(i) ? check.sources.length : math.min(check.sources.length, 4)); n++)
              _sourceRow(check.sources[n], i, n, scheme, small, label, open),
            if (check.sources.length > 4 && !_allSources.contains(i))
              TextButton(
                key: ValueKey('assistant-all-sources-$i'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                onPressed: () => setState(() => _allSources.add(i)),
                child: Text(tr('Show all {n} sources', {'n': '${check.sources.length}'})),
              ),
            if (check.unsourced > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr('Statements with no source named: {n}', {'n': '${check.unsourced}'}),
                  key: ValueKey('assistant-nosource-$i'),
                  style: small,
                ),
              ),
          ]),
        )
      else if (m.known.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('This answer names no passage of your notes: it may come from the model, not from them.'), key: ValueKey('assistant-uncited-$i'), style: small),
        ),
      if (check.usesHandwriting)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(tr('Part of this was read from handwriting by the app: it can contain a misread word or digit.'), key: ValueKey('assistant-handwriting-$i'), style: small),
        ),
      if (check.unknown.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${tr('Named, but not among what was read')}: ${check.unknown.join(', ')}', key: ValueKey('assistant-unknown-cite-$i'), style: TextStyle(fontSize: 12, color: scheme.error)),
        ),
    ];
  }

  /// What the model was given for an answer: the person can see why it said what it said (or why it missed something).
  void _showGiven(BuildContext context, String given) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('What the assistant read')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: SelectableText(given, key: const ValueKey('assistant-given-text'), style: const TextStyle(fontSize: 13))),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Close')))],
      ),
    );
  }

  /// The lines a change would make different: what goes red, what comes green, a little of what is around them.
  Widget _diff(BuildContext context, AgentPreview preview, String key) {
    final scheme = Theme.of(context).colorScheme;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    Widget line(DiffLine l) {
      final (mark, background, color) = switch (l.kind) {
        DiffKind.added => ('+', Colors.green.withValues(alpha: 0.22), scheme.onSurface),
        DiffKind.removed => ('-', Colors.red.withValues(alpha: 0.22), scheme.onSurface),
        DiffKind.same => (' ', null, scheme.onSurfaceVariant),
        DiffKind.gap => (' ', null, scheme.onSurfaceVariant),
      };
      return Container(
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text.verbatim(
          l.kind == DiffKind.gap ? '  ... ${tr('{n} more lines', {'n': l.text})}' : '$mark ${l.text.isEmpty ? ' ' : l.text}',
          style: mono.copyWith(color: color),
        ),
      );
    }

    return Padding(
      key: ValueKey('agent-diff-$key'),
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(4)),
        constraints: const BoxConstraints(maxHeight: 180),
        child: SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final l in preview.lines) line(l)]))),
      ),
    );
  }

  /// One thing the assistant does; while it waits for leave, with the buttons that give it.
  Widget _step(BuildContext context, AgentStep step, int i, int j) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (step.state) {
      AgentStepState.asking => (Icons.help_outline, scheme.primary),
      AgentStepState.running => (Icons.more_horiz, scheme.onSurfaceVariant),
      AgentStepState.done => (Icons.check_circle_outline, scheme.primary),
      AgentStepState.refused => (Icons.block, scheme.onSurfaceVariant),
      AgentStepState.failed => (Icons.error_outline, scheme.error),
    };
    final detail = step.action.detail;
    final permission = step.permission ?? step.tool?.permission;
    return Container(
      key: ValueKey('agent-step-$i-$j'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: step.state == AgentStepState.asking ? scheme.primary : scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text.verbatim(step.action.summary, style: const TextStyle(fontSize: 13))),
        ]),
        if (detail != null && step.state != AgentStepState.refused)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(child: SelectableText(detail, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
            ),
          ),
        if (step.preview != null && step.preview!.lines.isNotEmpty) _diff(context, step.preview!, '$i-$j'),
        if (step.result.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text.verbatim(step.result, style: TextStyle(fontSize: 12, color: scheme.error)),
          ),
        if (step.state == AgentStepState.asking && permission != null) ...[
          const SizedBox(height: 6),
          Text.verbatim(agentQuestion(permission), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            FilledButton(
              key: const ValueKey('agent-allow'),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onPressed: () => widget.chat.decide(AgentChoice.once),
              child: const Text('Allow'),
            ),
            OutlinedButton(
              key: const ValueKey('agent-allow-chat'),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onPressed: () => widget.chat.decide(AgentChoice.always),
              child: const Text('Allow for this chat'),
            ),
            TextButton(
              key: const ValueKey('agent-deny'),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onPressed: () => widget.chat.decide(AgentChoice.deny),
              child: const Text('Don\'t allow'),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _footer(BuildContext context, TextModelProvider? provider, AssistantChat chat) {
    final scheme = Theme.of(context).colorScheme;
    final state = provider?.state;
    if (provider == null || state == ProviderState.unavailable) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(provider?.reason ?? 'No AI provider is set up. Choose one in the Settings.',
            key: const ValueKey('assistant-unavailable'), style: TextStyle(color: scheme.error)),
      );
    }
    if (state == ProviderState.needsDownload || state == ProviderState.downloading) {
      final download = provider is DownloadableModel ? provider as DownloadableModel : null;
      return Padding(
        padding: const EdgeInsets.all(12),
        child: state == ProviderState.downloading
            ? Row(children: [
                Expanded(child: LinearProgressIndicator(value: (download?.progress ?? 0) > 0 ? download!.progress : null)),
                const SizedBox(width: 12),
                Text('${((download?.progress ?? 0) * 100).round()}%'),
              ])
            : Row(children: [
                Expanded(
                  child: Text.verbatim(tr('The model has to be downloaded first (about {size} GB).', {'size': ((download?.sizeMb ?? 0) / 1000).toStringAsFixed(1)}),
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
                FilledButton(key: const ValueKey('assistant-download'), onPressed: provider.prepare, child: const Text('Download')),
              ]),
      );
    }
    if (chat.cardMode) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_offered.isNotEmpty)
          Padding(
            key: const ValueKey('assistant-mentions'),
            padding: const EdgeInsets.only(bottom: 6, right: 4),
            child: Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (final n in _offered)
                ListTile(
                  key: ValueKey('assistant-mention-${n.id}'),
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.description_outlined, size: 18),
                  title: Text.verbatim(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _pick(n),
                ),
            ]),
            ),
          ),
        Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('assistant-input'),
            controller: _input,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(hintText: chat.acting ? (_allNotes ? tr('Say what to do with your notes...') : tr('Say what to do with this note...')) : tr('Ask a question...'), border: OutlineInputBorder(), isDense: true),
          ),
        ),
        if (chat.lookup != null)
          IconButton(
            key: const ValueKey('assistant-mention'),
            tooltip: tr('Refer to a note (@)'),
            icon: const Icon(Icons.alternate_email, size: 20),
            onPressed: () {
              final t = _input.text;
              _input.value = TextEditingValue(text: t.isEmpty || t.endsWith(' ') ? '$t@' : '$t @', selection: TextSelection.collapsed(offset: t.isEmpty || t.endsWith(' ') ? t.length + 1 : t.length + 2));
            },
          ),
        const SizedBox(width: 4),
        if (chat.busy)
          IconButton.filledTonal(key: const ValueKey('assistant-stop'), tooltip: tr('Stop'), icon: const Icon(Icons.stop), onPressed: chat.stop)
        else
          IconButton.filled(key: const ValueKey('assistant-send'), tooltip: tr('Ask'), icon: const Icon(Icons.arrow_upward), onPressed: _send),
        ]),
      ]),
    );
  }
}

/// An answer of the assistant as the app draws a note: Markdown (bold, lists, headings, tables) and formulas, which models write as
/// `$x$`, `$$x$$`, `\(x\)` or `\[x\]`. The text can be selected and copied.
class ChatText extends StatefulWidget {
  final String text;
  final Color color;
  final double fontSize;

  /// Called with the target of a link in the text (`cite:2`).
  final ValueChanged<String>? onLink;
  const ChatText(this.text, {super.key, required this.color, this.fontSize = 14, this.onLink});

  @override
  State<ChatText> createState() => _ChatTextState();
}

class _ChatTextState extends State<ChatText> {
  final _controller = RichInlineTextController();

  @override
  void initState() {
    super.initState();
    _controller.text = chatMarkdown(widget.text);
  }

  @override
  void didUpdateWidget(ChatText old) {
    super.didUpdateWidget(old);
    // (an answer grows while it is written)
    if (old.text != widget.text) _controller.text = chatMarkdown(widget.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionArea(child: MarkdownView(controller: _controller, fontSize: widget.fontSize, textColor: widget.color, onLink: widget.onLink));
}

