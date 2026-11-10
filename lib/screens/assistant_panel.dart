import 'package:flutter/material.dart' hide Text;
import '../l10n/language.dart';
import '../l10n/text.dart';
import 'package:flutter/services.dart';

import '../ai/ai_service.dart';
import '../ai/assistant_chat.dart';
import '../ai/flashcards.dart' show Flashcard;
import '../ai/line_diff.dart';
import '../ai/note_agent.dart';
import '../ai/note_ai.dart' show NoteAiKind;
import '../ai/text_provider.dart';
import '../ink/ink_recognizer.dart' show DownloadableModel;
import 'add_to_note.dart';
import 'flashcard_view.dart';

/// Questions and answers about the whole document, beside it (or over it on a
/// narrow screen). Who answers is the AI provider chosen in the Settings.
class AssistantPanel extends StatefulWidget {
  final AiService ai;
  final AssistantChat chat;
  /// Closes the panel (it sits beside a note, or in a window); null: it is a page of its own and has no close button.
  final VoidCallback? onClose;

  /// Takes the reader to a page (zero-based) an answer points at.
  final ValueChanged<int>? onJumpToPage;

  /// Puts an answer on the note.
  final AddToNote? onAddToNote;

  /// Whether the flashcards are offered.
  final bool flashcards;

  /// Keeps flashcards for spaced repetition; null: not offered.
  final Future<int> Function(List<Flashcard> cards)? onKeepCards;

  /// For a conversation about all notes: takes the reader to the note (and page, zero-based) an answer drew on.
  final void Function(String noteId, int? page)? onOpenSource;

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
  static const _agentSuggestions = ['Give this note a clear structure with headings', 'Fix the spelling mistakes', 'Turn the to-dos in this note into tasks'];

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_followAnswer);
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

  void _send([String? text]) {
    final q = text ?? _input.text;
    if (q.trim().isEmpty || widget.chat.busy) return;
    _input.clear();
    widget.chat.ask(q);
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
              ButtonSegment(value: false, icon: const Icon(Icons.chat_bubble_outline, size: 16), label: const Text('Ask'), tooltip: tr('Answers questions; the note stays as it is')),
              ButtonSegment(value: true, icon: const Icon(Icons.auto_fix_normal, size: 16), label: const Text('Agent'), tooltip: tr('Works on the note; it asks before each change')),
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
          chat.acting
              ? tr('Tell the assistant what to do with this note: format it, rewrite parts of it, add to it, make tasks from it. It asks before each change, and every change can be undone in the note.')
              : widget.invitation ?? tr('Ask anything about this document: its pages, your notes and text boxes are read for every question.'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in chat.acting ? _agentSuggestions : widget.suggestions ?? _suggestions)
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
          decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
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
          color: m.failed ? scheme.errorContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var j = 0; j < m.steps.length; j++) _step(context, m.steps[j], i, j),
          if (m.text.isNotEmpty)
            SelectableText(m.text, style: TextStyle(color: m.failed ? scheme.onErrorContainer : null)),
          if (done && !m.failed && m.pages.isNotEmpty && widget.onJumpToPage != null)
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
          if (done && !m.failed && m.sources.isNotEmpty && widget.onOpenSource != null)
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
          if (done && !m.failed && m.text.trim().isNotEmpty && m.text != '(stopped)')
            Row(mainAxisSize: MainAxisSize.min, children: [
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
            ])
          else
            const SizedBox(height: 4),
        ]),
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
      child: Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('assistant-input'),
            controller: _input,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(hintText: chat.acting ? tr('Say what to do with this note...') : tr('Ask a question...'), border: OutlineInputBorder(), isDense: true),
          ),
        ),
        const SizedBox(width: 4),
        if (chat.busy)
          IconButton.filledTonal(key: const ValueKey('assistant-stop'), tooltip: tr('Stop'), icon: const Icon(Icons.stop), onPressed: chat.stop)
        else
          IconButton.filled(key: const ValueKey('assistant-send'), tooltip: tr('Ask'), icon: const Icon(Icons.arrow_upward), onPressed: _send),
      ]),
    );
  }
}
