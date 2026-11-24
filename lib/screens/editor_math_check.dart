part of 'fixed_page_note_editor.dart';

/// Checking the maths that is written on the pages (the tool "Check my maths"; see [MathMarker]). While it is on and
/// the formula reader is installed, the writing is read line by line in the background, a little behind the pen
/// ([InkPrefetcher]); the lines that follow each other are checked as one worked solution, and a mark next to each
/// line says what was found.
extension _EditorMathCheck on _FixedPageNoteEditorState {
  /// Starts or stops checking to match the tool being on and the readers being there.
  void _syncMathCheck() {
    final want = _on(Feature.checkMaths) && _on(Feature.mathInk) && widget.math != null;
    if (want == _checkOn) {
      if (want) _startInk();
      return;
    }
    _checkOn = want;
    _live?.wantMathCheck(want); // (a guest: the host reads by lines for it)
    _startInk().then((_) {
      if (!mounted) return;
      setState(() => _marks = want ? _currentMarks() : const []);
    });
  }

  List<MathMark> _currentMarks() {
    final ink = _ink;
    final read = ink?.readings() ?? const [];
    final marks = _marker.mark([
      for (final r in read) (page: r.block.page, key: r.block.key, rect: r.block.bounds, latex: r.latex),
    ], others: {
      for (final r in read) r.block.key: ink!.othersOf(r.block.key),
    });
    // a line that is marked as a mistake is read once more, another way, in the background: the writing may have been misread (by the
    // device that reads: a guest of a live session gets the other readings from the host)
    if (_reader.readsNow) {
      for (final m in marks) {
        if (m.check.isProblem) unawaited(ink?.lookAgain(m.key) ?? Future<void>.value());
      }
    }
    return marks;
  }

  /// The marks as the writing is now (it may have changed since the lines were read: a line that changed has no
  /// formula until it is read again, and its mark goes).
  void _refreshMarks() {
    final marks = _currentMarks();
    if (marks.length == _marks.length && !marks.asMap().entries.any((e) => e.value.key != _marks[e.key].key || !identical(e.value.check, _marks[e.key].check) || e.value.doubtful != _marks[e.key].doubtful || e.value.latex != _marks[e.key].latex || e.value.rect != _marks[e.key].rect)) return;
    if (mounted) setState(() => _marks = marks);
  }

  /// The marks of one page, beside the lines they are about.
  List<Widget> _markWidgets(int pageIndex) => [
        if (_checkOn)
          for (final m in _marks)
          if (m.page == pageIndex) _markBadge(m),
      ];

  (IconData, Color) _verdictIcon(LineCheck c, bool doubtful) => switch (c.verdict) {
        _ when doubtful => (Symbols.help_outline, Colors.orange),
        Verdict.right => (Symbols.check_circle, Colors.green),
        Verdict.rounded => (Symbols.check_circle_outline, Colors.green),
        Verdict.wrong => (Symbols.cancel, Colors.red),
        Verdict.lost || Verdict.widened => (Symbols.warning_amber_rounded, Colors.orange),
        null => (Symbols.calculate, Colors.blueGrey),
      };

  Widget _markBadge(MathMark m) {
    final c = m.check;
    final (icon, color) = _verdictIcon(c, m.doubtful);
    final answer = c.verdict == null && c.answer != null;
    return Positioned(
      left: math.min(m.rect.right + 6, _paperWidth - (answer ? 90 : 30)),
      top: m.rect.center.dy - 14,
      child: IgnorePointer(
        ignoring: _mode == CanvasInteractionMode.draw, // (the pen draws there; tap it in another mode)
        child: GestureDetector(
          key: ValueKey('math-mark-${m.doubtful ? 'unsure' : c.verdict?.name ?? 'answer'}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _explainMark(m),
          child: answer
              ? Chip(
                  visualDensity: VisualDensity.compact,
                  label: Math.tex('= ${c.answer}', textStyle: const TextStyle(fontSize: 14), onErrorFallback: (_) => Text.verbatim('= ${c.answer}')),
                )
              : Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  child: Icon(icon, color: color, size: 22),
                ),
        ),
      ),
    );
  }

  String _headline(LineCheck c) => switch (c.verdict) {
        Verdict.right => tr('This looks right'),
        Verdict.rounded => tr('Right, up to rounding'),
        Verdict.wrong => switch (c.reason) {
            Reason.arithmetic => tr('The sum does not work out'),
            Reason.identity => tr('The two sides are not equal'),
            Reason.derivative => tr('That is not the derivative'),
            Reason.integral => tr('That is not the integral'),
            Reason.limit => tr('That is not the limit'),
            Reason.notSolution => tr('That does not solve the line above'),
            Reason.order => tr('This is not true'),
            Reason.matrix => tr('These matrices are not equal'),
            Reason.shape => tr('The sizes of these matrices do not fit'),
            Reason.singular => tr('This matrix has no inverse'),
            Reason.congruence => tr('These are not congruent'),
            Reason.notEquivalent => tr('These are not equivalent'),
            Reason.units => tr('The units do not fit'),
            _ => tr('This does not follow from the line above'),
          },
        Verdict.lost => tr('A solution of the line above is lost'),
        Verdict.widened => tr('This lets in a solution the line above did not have'),
        null => tr('Result'),
      };

  String _expectedLabel(LineCheck c) => switch (c.reason) {
        Reason.lostSolution => tr('The solution that is missing:'),
        Reason.extraSolution => tr('The solution that is new:'),
        Reason.notImplied => tr('This does not hold for:'),
        Reason.step || Reason.notSolution || Reason.setDiffers => tr('The line above has:'),
        _ => tr('It should be:'),
      };

  String _counterLabel(LineCheck c) => switch (c.reason) {
        Reason.shape => tr('The sizes are:'),
        Reason.singular => tr('Its determinant:'),
        Reason.setDiffers => tr('They differ at:'),
        Reason.units => tr('The units are:'),
        _ => c.verdict == Verdict.wrong && c.reason != Reason.arithmetic ? tr('For example:') : tr('It works out to:'),
      };

  /// [tex] drawn as a formula. What the model reads may be an environment (`\begin{array}...`, line breaks) that the
  /// formula widget cannot lay out (it throws in the layout, where nothing can catch it): that is shown as it is.
  ///
  /// [generated]: it was written by the checker (a `pmatrix` of numbers), not read from the writing, so the environment is safe.
  Widget _formula(String tex, {bool generated = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: !generated && RegExp(r'\\begin|\\end|\\\\|&').hasMatch(tex)
              ? Text.verbatim(tex, style: const TextStyle(fontFamily: 'monospace'))
              : Math.tex(tex, textStyle: const TextStyle(fontSize: 18), onErrorFallback: (_) => Text.verbatim(tex)),
        ),
      );

  /// What is known about one line, as it is told in the sheet: what was read (unless [showRead] is false: the sheet shows
  /// it in a field to correct), what is wrong and what it should be.
  List<Widget> _markBody(String latex, LineCheck c, {bool showRead = true, bool doubtful = false, bool withIcon = false}) => [
        () {
          final title = Text(c.isNothing ? tr('Nothing to check in this line') : (doubtful ? tr('I am not sure I read this right') : _headline(c)), style: Theme.of(context).textTheme.titleMedium);
          if (!withIcon) return title;
          final (icon, color) = _verdictIcon(c, doubtful);
          return Row(children: [Icon(icon, color: color, size: 24), const SizedBox(width: 8), Expanded(child: title)]);
        }(),
        if (doubtful) ...[
          const SizedBox(height: 4),
          Text(tr('As I read it, this is a mistake, but the writing can be read another way (below). Pick what you wrote:'), style: Theme.of(context).textTheme.bodySmall),
        ],
        if (showRead) ...[
          const SizedBox(height: 8),
          Text(tr('I read:'), style: Theme.of(context).textTheme.labelMedium),
          _formula(latex),
        ],
        if (c.counter != null) ...[
          const SizedBox(height: 8),
          Text(_counterLabel(c), style: Theme.of(context).textTheme.labelMedium),
          _formula(c.counter!, generated: true),
        ],
        if (c.expected != null) ...[
          const SizedBox(height: 8),
          Text(_expectedLabel(c), style: Theme.of(context).textTheme.labelMedium),
          _formula(c.expected!, generated: true),
        ],
        if (c.answer != null) ...[
          const SizedBox(height: 8),
          _formula('= ${c.answer}', generated: true),
        ],
        if (c.isNothing)
          if (answerFor(latex) case final answer?) ...[
            const SizedBox(height: 8),
            _formula('= $answer'),
          ],
      ];

  /// Under a line in the sheet: the other readings of it to pick from (when there are some), or the button that has the formula reader look
  /// at it again, with a thinner and a thicker pen. [pick] puts a reading in the field of the line.
  List<Widget> _otherReadings(int i, List<TextEditingController> edits, List<String?> latex, List<String>? keys, Set<int> asking, List<String> others, ValueChanged<String> pick, StateSetter setSheet) {
    final ink = _ink;
    if (keys == null || ink == null || latex[i] == null || widget.math == null) return const [];
    final key = keys[i];
    if (others.isNotEmpty) {
      return [
        const SizedBox(height: 8),
        Text(tr('Or did you write:'), style: Theme.of(context).textTheme.labelMedium),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (var k = 0; k < others.length; k++)
            ActionChip(
              key: ValueKey('math-check-other-$i-$k'),
              label: Math.tex(others[k], textStyle: const TextStyle(fontSize: 16), onErrorFallback: (_) => Text.verbatim(others[k])),
              onPressed: () => pick(others[k]),
            ),
        ]),
      ];
    }
    if (ink.lookedAgain(key) && !asking.contains(i)) {
      return [const SizedBox(height: 8), Text(tr('Looked again: it reads the same'), style: Theme.of(context).textTheme.bodySmall)];
    }
    if (asking.contains(i)) {
      return [const SizedBox(height: 8), Text(tr('Looking again...'), style: Theme.of(context).textTheme.bodySmall)];
    }
    return [
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: ValueKey('math-check-look-again-$i'),
          icon: const Icon(Symbols.visibility),
          label: Text(tr('Read it again')),
          onPressed: () async {
            asking.add(i);
            setSheet(() {});
            await ink.lookAgain(key);
            asking.remove(i);
            if (mounted) setSheet(() {});
          },
        ),
      ),
    ];
  }

  Widget _checkNote() => Text(
        tr('Checked by working it out in numbers on this device. If the writing was read wrongly, correct it above: the check is done again.'),
        style: Theme.of(context).textTheme.bodySmall,
      );

  /// A field with what was read, to correct when the model read the writing wrongly.
  Widget _correctionField(TextEditingController controller, ValueChanged<String> onChanged, {Key? key}) => TextField(
        key: key,
        controller: controller,
        onChanged: onChanged,
        minLines: 1,
        maxLines: 3,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
        decoration: InputDecoration(
          labelText: tr('I read (correct it if it is wrong):'),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      );

  /// The flashcard for the mistake of a line, when there is one to keep: the line is wrong, the card repository is there and the
  /// flashcards are on.
  Flashcard? _cardFor(int page, String latex, LineCheck? check) {
    if (widget.cards == null || !_on(Feature.flashcards) || check == null) return null;
    return mistakeCard(latex, check, headline: _headline(check), expectedLabel: _expectedLabel(check), counterLabel: _counterLabel(check), page: page);
  }

  /// The button that keeps the mistake of line [i] as a flashcard (nothing when there is none to keep); it closes the sheet it is in.
  List<Widget> _keepCardButton(BuildContext sheet, int i, int page, String latex, LineCheck check) {
    final card = _cardFor(page, latex, check);
    if (card == null) return const [];
    return [
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: ValueKey('math-check-keep-card-$i'),
        icon: const Icon(Symbols.style),
        label: Text(tr('Keep this mistake as a flashcard')),
        onPressed: () async {
          final added = await widget.cards!.addAll(widget.noteId, [card]);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(added > 0 ? tr('Kept it as a flashcard, to ask again later') : tr('This mistake is a flashcard already'))));
          if (sheet.mounted) Navigator.pop(sheet);
        },
      ),
    ];
  }

  /// Scrolls the pages so that the line of [m] is in the top half of the screen, above the card that tells about it.
  void _showLineAbove(MathMark m) {
    if (_infinite || !_pageScroll.hasClients) return;
    final height = MediaQuery.of(context).size.height;
    final y = _pageTop(m.page) + _rulerExtent + m.rect.center.dy * _pageScale;
    final top = _pageScroll.offset;
    if (y > top + height * 0.4 || y < top + 60) {
      unawaited(_pageScroll.animateTo((y - height * 0.2).clamp(0.0, _pageScroll.position.maxScrollExtent), duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
    }
  }

  /// What a mark says, in a small card under the line (the line stays in sight above it): the verdict, what was read, what is wrong
  /// and what it should be, for that line only. When the reading is doubtful the card first asks what was written, and tells the verdict
  /// after that. "Whole solution" opens the sheet with every line of the worked solution.
  Future<void> _explainMark(MathMark m) async {
    final latex = [for (final l in m.solution) l.latex];
    final keys = [for (final l in m.solution) l.key];
    final i = m.index;
    final edit = TextEditingController(text: latex[i] ?? '');
    final asking = <int>{};
    var checks = checkLines(latex);
    var confirmed = false; // (the person said the reading is what was written)
    var fixing = false; // (the field with the reading is open)
    Timer? later;
    void change(String v, StateSetter setCard) {
      latex[i] = v.trim().isEmpty ? null : v.trim();
      checks = checkLines(latex);
      if (latex[i] != null) {
        later?.cancel();
        later = Timer(const Duration(milliseconds: 350), () {
          _ink?.correct(keys[i], latex[i]!);
          _refreshMarks();
        });
      }
      setCard(() {});
    }

    List<String> others() => [for (final o in _ink?.othersOf(keys[i]) ?? const <String>[]) if (!sameReading(o, latex[i] ?? '')) o];
    _showLineAbove(m);
    var whole = false;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      barrierColor: Colors.black12,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setCard) {
          final c = checks[i];
          final other = others();
          final doubtful = c.isProblem && !confirmed && latex[i] != null && readsOtherwise(latex, i, other);
          final theme = Theme.of(sheet);
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.45),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12 + MediaQuery.of(sheet).viewInsets.bottom),
                child: Column(
                  key: const ValueKey('math-check-card'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (latex[i] == null) Text(tr('A line could not be read'), style: theme.textTheme.bodyMedium),
                    if (doubtful) ...[
                      Row(children: [
                        const Icon(Symbols.help_outline, color: Colors.orange, size: 24),
                        const SizedBox(width: 8),
                        Expanded(child: Text(tr('Did you write one of these?'), style: theme.textTheme.titleMedium)),
                      ]),
                      const SizedBox(height: 4),
                      Text(tr('As I read it, this is a mistake, but the writing can be read another way (below). Pick what you wrote:'), style: theme.textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        ChoiceChip(
                          key: ValueKey('math-check-keep-reading-$i'),
                          selected: true,
                          label: Math.tex(latex[i]!, textStyle: const TextStyle(fontSize: 16), onErrorFallback: (_) => Text.verbatim(latex[i]!)),
                          onSelected: (_) => setCard(() => confirmed = true),
                        ),
                        for (var k = 0; k < other.length; k++)
                          ActionChip(
                            key: ValueKey('math-check-other-$i-$k'),
                            label: Math.tex(other[k], textStyle: const TextStyle(fontSize: 16), onErrorFallback: (_) => Text.verbatim(other[k])),
                            onPressed: () {
                              edit.text = other[k];
                              change(other[k], setCard);
                            },
                          ),
                      ]),
                    ] else ...[
                      ..._markBody(edit.text, c, withIcon: true),
                      if (i > 0 && latex[i - 1] != null && c.isProblem && c.expected == null) ...[
                        const SizedBox(height: 8),
                        Opacity(opacity: 0.6, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(tr('The line above:'), style: theme.textTheme.labelMedium), _formula(latex[i - 1]!)])),
                      ],
                    ],
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      OutlinedButton.icon(
                        key: ValueKey('math-check-fix-$i'),
                        icon: const Icon(Symbols.edit, size: 18),
                        label: Text(tr('Fix reading')),
                        onPressed: () => setCard(() => fixing = !fixing),
                      ),
                      if (latex.length > 1)
                        TextButton(
                          key: const ValueKey('math-check-whole'),
                          onPressed: () {
                            whole = true;
                            Navigator.pop(sheet);
                          },
                          child: Text(tr('Whole solution')),
                        ),
                    ]),
                    if (fixing) ...[
                      const SizedBox(height: 8),
                      _correctionField(edit, (v) => change(v, setCard), key: ValueKey('math-check-edit-$i')),
                      _formula(edit.text),
                      if (!doubtful) ..._otherReadings(i, [edit], latex, keys, asking, other, (v) {
                            edit.text = v;
                            change(v, setCard);
                          }, setCard),
                    ],
                    _truthTableButton(edit.text),
                    ..._keepCardButton(sheet, i, m.page, edit.text, c),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    later?.cancel();
    Future<void>.delayed(const Duration(milliseconds: 600), edit.dispose); // (the card is still sliding out)
    if (whole && mounted) {
      await _checkSheet(latex: latex, keys: keys, page: m.page, focus: i);
    }
  }

  /// The sheet that tells how lines of maths were checked (as one worked solution): for each line what was read (in a field
  /// to correct, and the line is checked again), what is wrong and what it should be. [keys] (one for each line) say which
  /// writing a correction belongs to, when the lines are on the pages and corrections stay while the note is open; [focus]
  /// is the line to show and mark out.
  Future<void> _checkSheet({required List<String?> latex, List<String>? keys, required int page, int focus = -1}) async {
    final edits = [for (final l in latex) TextEditingController(text: l ?? '')];
    final spots = [for (var i = 0; i < latex.length; i++) GlobalKey()];
    Timer? later;
    final asking = <int>{}; // (the lines that are being read again)
    var checks = checkLines(latex);
    // what was typed (or picked) for line [i]: the lines are checked again, and the correction is kept for the writing
    void edit(int i, String v, StateSetter setSheet) {
      latex[i] = v.trim().isEmpty ? null : v.trim();
      checks = checkLines(latex);
      if (keys != null && latex[i] != null) {
        later?.cancel();
        later = Timer(const Duration(milliseconds: 350), () {
          _ink?.correct(keys[i], latex[i]!);
          _refreshMarks();
        });
      }
      setSheet(() {});
    }

    // the other readings of line [i] that were made (the formula reader looked at it with a thinner and a thicker pen) and differ from what is there
    List<String> otherReadings(int i) => keys == null ? const [] : [for (final o in _ink?.othersOf(keys[i]) ?? const <String>[]) if (!sameReading(o, latex[i] ?? '')) o];

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) {
          if (focus >= 0 && focus < spots.length) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final c = spots[focus].currentContext;
              if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: Duration.zero);
            });
          }
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
                child: Column(
                  key: const ValueKey('math-check-sheet'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < latex.length; i++) ...[
                      Container(
                        key: spots[i],
                        padding: i == focus ? const EdgeInsets.all(8) : EdgeInsets.zero,
                        decoration: i == focus
                            ? BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8))
                            : null,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (latex[i] == null) Text(tr('A line could not be read'), style: Theme.of(context).textTheme.bodyMedium),
                            ..._markBody(edits[i].text, checks[i], showRead: false, doubtful: checks[i].isProblem && readsOtherwise(latex, i, otherReadings(i))),
                            const SizedBox(height: 12),
                            _correctionField(edits[i], (v) => edit(i, v, setSheet), key: ValueKey('math-check-edit-$i')),
                            _formula(edits[i].text),
                            ..._otherReadings(i, edits, latex, keys, asking, otherReadings(i), (v) {
                              edits[i].text = v;
                              edit(i, v, setSheet);
                            }, setSheet),
                            _truthTableButton(edits[i].text),
                            ..._keepCardButton(context, i, page, edits[i].text, checks[i]),
                          ],
                        ),
                      ),
                      if (i < latex.length - 1) const Divider(height: 28),
                    ],
                    const SizedBox(height: 12),
                    _checkNote(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    later?.cancel();
    // The sheet is still sliding out (a swipe down returns early) and its fields read these, so they go once it is gone.
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      for (final e in edits) {
        e.dispose();
      }
    });
  }

  /// Checks the maths in the selection now (the button over a selection), whether or not the tool that does it
  /// all the time is on: each line is read, and the lines are checked as one worked solution. What was read can be
  /// corrected in the sheet, and the lines are checked again.
  Future<void> _checkSelectedMaths() async {
    final reader = widget.math;
    final strokes = List.of(_selection);
    if (reader == null || strokes.isEmpty) return;
    final page = _selectedStrokePage;
    final messenger = ScaffoldMessenger.of(context);
    if (reader.status != HandwritingStatus.installed) {
      messenger.showSnackBar(SnackBar(content: Text(tr('The formula model is not installed (see Settings)'))));
      return;
    }
    final rows = [...clusterStrokes(page, strokes, rows: true)]..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    if (rows.isEmpty) return;
    messenger.showSnackBar(SnackBar(content: Text(tr('Checking...')), duration: const Duration(seconds: 30)));
    final latex = <String?>[];
    for (final row in rows) {
      try {
        Future<String> read() => reader.recognize(row.strokes);
        latex.add((await (_ink?.exclusive(read) ?? read())).trim());
      } catch (_) {
        latex.add(null);
      }
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 40)); // (the screen gets a turn)
    }
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    await _checkSheet(latex: latex, page: page);
  }
}
