import '../pdf/open_pdf.dart';
import '../web/picked_file.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../data/file_digest.dart';
import 'package:archive/archive.dart' show Archive, ArchiveFile, CompressionType, ZipEncoder;
import '../export/file_dialogs.dart';
import '../export/image_export.dart';
import '../export/pdf_brush.dart';
import '../export/ora_export.dart';
import '../export/svg_export.dart';
import '../export/pdf_ink_text.dart';
import '../export/pdf_label.dart';
import '../export/widget_pictures.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/rendering.dart' show RenderBox, RenderParagraph, RenderRepaintBoundary, ScrollCacheExtent;
import '../pdf/pdf_content_editor.dart';
import '../pdf/page_cache.dart';
import '../pdf/pdf_pages.dart';
import 'color_swatches.dart';
import '../pdf/pdf_stand_in_fonts.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HardwareKeyboard, KeyDownEvent, KeyboardInsertedContent, LogicalKeyboardKey, MissingPluginException, SystemChrome, SystemUiMode;
import 'package:flutter_math_fork/flutter_math.dart' show Math;
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pw_widgets;
import 'package:pdf_overlay/pdf_overlay.dart';
import 'package:pdfrx/pdfrx.dart';

import '../ai/ai_prompt.dart' show AiPrompt, AiTask, hasWords, worthSummarizing;
import '../citations/cite_picker.dart';
import '../citations/citation_service.dart';
import '../citations/citation_document.dart';
import '../markdown/markdown_parser.dart' show MdRun, parseMarkdown, withoutParagraphFormats;
import '../citations/citation_library_screen.dart';
import '../citations/citation_style.dart';
import '../citations/lookup.dart';
import '../citations/source.dart';
import '../ai/ai_service.dart';
import '../ai/assistant_chat.dart';
import '../ai/document_index.dart';
import '../ai/flashcards.dart' show Flashcard;
import '../ai/note_ai.dart';
import '../algebra/calculator.dart';
import '../algebra/checker.dart';
import '../algebra/latex_parser.dart' show normalizeLatex;
import '../algebra/logic.dart' show looksLogical;
import '../algebra/truth_table.dart';
import '../algebra/equation_solver.dart';
import '../algebra/mistake_card.dart';
import '../algebra/plot.dart';
import '../algebra/text_equation.dart';
import '../automations/automation_service.dart' show ImageExporter, InkPreparer, NoteEditorHandle, TitleSetter;
import '../mcp/agent_editable.dart';
import '../collab/collab_service.dart';
import '../collab/invite.dart';
import '../collab/replica.dart';
import '../collab/session.dart';
import '../collab/transport.dart' show HostTransport;
import 'link_signal.dart';
import 'presence.dart';
import '../audio/sound_player.dart';
import '../audio/lecture_recorder.dart';
import '../audio/sound_marks.dart';
import 'audio_panel.dart';
import '../data/audio_repository.dart';
import '../data/bookmark_repository.dart';
import 'outline_panel.dart';
import '../data/card_repository.dart';
import '../graph/echoes.dart';
import '../data/link_repository.dart';
import '../outline/outline.dart';
import '../reminders/reminder.dart';
import '../reminders/reminder_service.dart';
import 'reminders_screen.dart';
import '../ai/text_provider.dart';
import '../ai/translation.dart';
import 'translate_dialog.dart';
import 'diagram_dialog.dart';
import 'truth_table_dialog.dart';
import 'presentation_view.dart';
import '../diagram/advanced.dart' show DiagramMode, buildAdvanced;
import '../diagram/diagram.dart';
import '../diagram/diagram_layout.dart';
import '../diagram/place_layout.dart';
import '../diagram/ink_diagram.dart';
import '../data/note_data.dart';
import '../data/note_file_service.dart';
import '../data/brush_library.dart';
import '../models/brush_desc.dart';
import 'brush_designer.dart';
import '../data/note_repository.dart';
import '../extensions/draw_result.dart';
import '../extensions/extension_host.dart';
import '../extensions/library_api.dart';
import '../extensions/notes_read_api.dart';
import '../extensions/extension_manifest.dart';
import '../extensions/extension_service.dart';
import '../extensions/note_format.dart';
import '../extensions/pdf_text.dart';
import 'add_to_note.dart';
import 'generated_panel.dart';
import '../ai/note_agent.dart';
import '../extensions/shared_api.dart';
import '../features/feature.dart';
import '../features/toolbar_profiles.dart';
import '../data/tag_repository.dart';
import '../data/task_repository.dart';
import '../sync/calendar_access.dart';
import '../history/note_history.dart';
import '../ink/ink_clusters.dart';
import '../ink/ink_grouping.dart' show strokeBounds;
import '../ink/ink_prefetcher.dart';
import '../ink/ink_recognizer.dart';
import '../ink/ink_spelling.dart';
import '../ink/math_marks.dart';
import '../ink/note_ink_reader.dart';
import '../block_editor/block_editor.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';
import '../lock/note_lock_service.dart';
import '../markdown/markdown_pdf.dart';
import '../markdown/markdown_table.dart';
import '../markdown/markdown_formatting.dart';
import '../markdown/markdown_toolbar.dart';
import '../markdown/markdown_view.dart';
import '../markdown/math_images.dart';
import '../markdown/mention.dart';
import '../models/arrange.dart';
import '../models/authorship.dart';
import '../models/bezier.dart';
import '../models/brush.dart';
import '../models/canvas_models.dart';
import '../models/gradient.dart';
import '../models/stroke_label.dart';
import '../models/canvas_view.dart';
import '../models/collage.dart';
import '../models/color_sample.dart';
import '../models/free_transform.dart';
import '../models/region_fill.dart';
import '../models/connector.dart';
import '../images/picture_edit.dart';
import '../models/align_snap.dart';
import '../models/guides.dart';
import '../models/image_item.dart';
import '../models/layers.dart';
import 'layers_dialog.dart';
import 'stamps_dialog.dart';
import 'palette_dialog.dart';
import 'picture_edit_dialog.dart';
import '../models/page_background.dart';
import '../models/page_format.dart';
import '../models/pdf_models.dart';
import '../models/rich_text.dart';
import '../models/shape_ops.dart';
import '../models/shapes.dart';
import '../models/stamps.dart';
import '../models/shape_snap.dart';
import '../models/stabilizer.dart';
import '../models/symmetry.dart';
import '../models/straighten.dart';
import '../models/undo_stack.dart';
import '../painters/canvas_painters.dart';
import '../painters/onion_skin.dart';
import '../painters/align_lines_painter.dart';
import '../painters/guides_painter.dart';
import '../painters/symmetry_painter.dart';
import '../pdf/page_jobs.dart';
import '../pdf/pdf_page_loader.dart';
import '../images/subject_service.dart';
import '../scan/ocr_service.dart';
import '../search/ink_indexer.dart';
import '../search/search_query.dart';
import '../speech/mic_recorder.dart';
import '../speech/read_aloud.dart';
import '../speech/speakable_text.dart';
import '../speech/speech_to_text.dart';
import '../spelling/spell_menu.dart';
import '../spelling/spell_service.dart';
import '../style/color_names.dart';
import '../shortcuts/shortcut_action.dart';
import '../shortcuts/shortcut_service.dart';
import '../style/stylus_settings.dart';
import 'ai_summary_dialog.dart';
import 'ideas_dialog.dart';
import 'image_export_dialog.dart';
import 'label_dialog.dart';
import 'assistant_panel.dart';
import 'collab_ui.dart';
import 'color_wheel_dialog.dart';
import 'document_sheet.dart';
import 'document_sheets.dart';
import 'print_preview.dart';
import '../markdown/live_markdown.dart';
import '../markdown/grammar.dart';
import 'bar_layout.dart';
import '../style/tool_columns.dart';
import '../style/zoomed_selection.dart';
import 'page_list.dart';
import '../markdown/document_export.dart';
import '../markdown/latex_export.dart';
import '../markdown/document_images.dart';
import '../markdown/docx_import.dart';
import '../markdown/document_import.dart';
import '../markdown/document_toolbar.dart';
import 'element_drag_detector.dart';
import 'history_panel.dart';
import 'image_item_widget.dart';
import 'lock_dialogs.dart';
import 'lookup_panel.dart';
import 'margin_ruler.dart';
import 'note_ai_sheet.dart';
import 'note_file_actions.dart';
import 'note_picker_dialog.dart';
import 'page_scrollbar.dart';
import 'plot_dialog.dart';
import 'scan_screen.dart';
import 'shape_style_dialog.dart';
import 'speech_recorder.dart';
import 'table_editor.dart';
import 'text_box_style_dialog.dart';
import '../style/platform_dialog.dart';
import '../style/platform_look.dart';

part 'editor_pdf_export.dart';
part 'editor_selection.dart';
part 'editor_comments.dart';
part 'editor_assistant.dart';
part 'editor_lookup.dart';
part 'editor_citations.dart';
part 'editor_zoom.dart';
part 'editor_images.dart';
part 'editor_undo.dart';
part 'editor_pages.dart';
part 'editor_draw_bar.dart';
part 'editor_symmetry.dart';
part 'editor_layers.dart';
part 'editor_side_panels.dart';
part 'editor_guides.dart';
part 'editor_ideas.dart';
part 'editor_image_export.dart';
part 'editor_svg_export.dart';
part 'editor_lecture.dart';
part 'editor_echoes.dart';
part 'editor_labels.dart';
part 'editor_pdf_pages.dart';
part 'editor_pdf_edit.dart';
part 'editor_text_boxes.dart';
part 'editor_shortcuts.dart';
part 'editor_page_tile.dart';
part 'editor_collab.dart';
part 'editor_history.dart';
part 'editor_duplicate.dart';
part 'editor_ink_prefetch.dart';
part 'editor_math_check.dart';
part 'editor_ink_spelling.dart';
part 'editor_extensions.dart';
part 'editor_find.dart';
part 'editor_scan.dart';
part 'editor_document_files.dart';
part 'editor_split.dart';
part 'editor_lock.dart';
part 'editor_outline.dart';
part 'editor_present.dart';
part 'editor_diagram.dart';
part 'editor_truth_table.dart';
part 'editor_connectors.dart';
part 'editor_audio.dart';
part 'editor_translate.dart';
part 'editor_layout.dart';
part 'editor_toolbar.dart';
part 'editor_canvas.dart';
part 'editor_pen_tool.dart';
part 'editor_arrange.dart';
part 'editor_align.dart';
part 'editor_stamps.dart';
part 'editor_shape_ops.dart';
part 'editor_groups.dart';
part 'editor_eyedropper.dart';
part 'editor_fill_bucket.dart';
part 'editor_onion_skin.dart';
part 'editor_free_transform.dart';
part 'editor_ora_export.dart';

/// What the clipboard holds that a note can take: a picture, files (pictures
/// copied in a file manager) or text.
typedef ClipboardContent = ({Uint8List? image, List<String> files, String? text});

const double basePageWidth = 800.0;

const double _bannerHeight = 190;

const double documentMargin = 56.0;
const int _maxCustomColors = 12;

const double _highlighterOpacity = 0.35;
/// Whether at least half of [rect] is inside the lasso [shape].
bool _rectMostlyInside(Rect rect, List<Offset> shape) {
  if (shape.length < 3) return false;
  var inside = 0;
  const n = 6;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      final p = Offset(rect.left + rect.width * (i + 0.5) / n, rect.top + rect.height * (j + 0.5) / n);
      if (pointInPolygon(p, shape)) inside++;
    }
  }
  return inside * 2 >= n * n;
}

/// Wide windows get a panel beside the note, narrow ones a page over it.
const _sidePanelFrom = 900.0;

const double _eraserRadius = 10.0;
const double _minZoom = 0.5, _maxZoom = 5.0;

/// Pages read ahead of the scrolling (and a couple behind): the list itself
/// only builds what is nearly on screen, which is too late on a slow PDF.
const _pagesAhead = 5, _pagesBehind = 2;

bool _looksLikePng(Uint8List b) => b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

const _shapeIcons = {
  ShapeTool.freehand: Icons.draw_outlined,
  ShapeTool.line: Icons.horizontal_rule,
  ShapeTool.arrow: Icons.arrow_right_alt,
  ShapeTool.connector: Icons.account_tree_outlined,
  ShapeTool.rectangle: Icons.crop_square,
  ShapeTool.ellipse: Icons.circle_outlined,
  ShapeTool.triangle: Icons.change_history,
  ShapeTool.diamond: Icons.diamond_outlined,
  ShapeTool.bezier: Icons.polyline_outlined,
};

/// The icon of a shape: a Material one where there is one, else the outline of the shape itself.
Widget _shapeIcon(ShapeTool tool, {Color? color}) {
  final icon = _shapeIcons[tool];
  if (icon != null) return Icon(icon, size: 20, color: color);
  return SizedBox(
    width: 20,
    height: 20,
    child: CustomPaint(painter: _ShapeOutlinePainter(tool, color ?? const Color(0xFF444444))),
  );
}

class _ShapeOutlinePainter extends CustomPainter {
  final ShapeTool tool;
  final Color color;

  const _ShapeOutlinePainter(this.tool, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final points = shapePoints(tool, const Offset(2.5, 3), Offset(size.width - 2.5, size.height - 3), step: 2);
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ShapeOutlinePainter old) => old.tool != tool || old.color != color;
}

const double _minBoxWidth = 100;


/// Reads the system clipboard. [onProblem] is told when the clipboard cannot be
/// read at all (rather than just holding nothing we can use).
Future<ClipboardContent> readSystemClipboard({void Function(String problem)? onProblem}) async {
  Uint8List? image;
  var files = <String>[];
  String? text;
  void failed(String what, Object e) {
    debugPrint('reading $what from the clipboard failed: $e');
    onProblem?.call(e is MissingPluginException
        ? tr('The clipboard plugin is not part of this running copy of the app yet: stop it and start it again (a full rebuild).')
        : tr('The clipboard could not be read: {error}', {'error': e}));
  }

  try {
    image = await Pasteboard.image;
  } catch (e) {
    failed('a picture', e);
  }
  if (image == null) {
    try {
      files = await Pasteboard.files();
    } catch (e) {
      failed('files', e);
    }
  }
  try {
    text = await Pasteboard.text ?? (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } catch (e) {
    debugPrint('reading text from the clipboard failed: $e');
  }
  return (image: image, files: files, text: text);
}

/// The editor of a note: pages (blank, a PDF, or written text) with pen, shapes, text boxes, images, comments and the assistant.
/// Its parts are split over the `editor_*.dart` files (they share this state).
class FixedPageNoteEditor extends StatefulWidget {
  final String noteId;
  final NoteRepository repository;

  /// Reads handwriting (the lasso's "convert to text"); null where unavailable.
  final InkRecognizer? handwriting;

  /// Reads formulas as LaTeX; null where unavailable.
  final InkRecognizer? math;

  /// How a looked-up web page is shown (a web view; the tests pass a stand-in).
  final WebPageBuilder? webPage;

  /// Opens another note, when a link to it is tapped.
  final ValueChanged<String>? onOpenNote;

  /// Called when a PDF has been imported into the note.
  final VoidCallback? onPdfImported;

  /// Writes summaries of highlighted text (the AI providers); null where unavailable.
  final AiService? ai;

  /// Saving the note as a file; null hides the button.
  final NoteFileService? noteFiles;

  /// Live sessions with others; null hides the button.
  final CollabService? collab;

  /// Earlier versions of the note; null hides the button.
  final NoteHistory? history;

  /// The tags of notes; the assistant gives a note tags through it. Null: it cannot.
  final TagRepository? tags;

  /// The tasks; the assistant lists, changes and ticks them off through it. Null: it cannot.
  final TaskRepository? tasks;

  /// The calendars; the assistant looks at their events and adds events through it. Null: it cannot.
  final CalendarAccess? calendar;

  /// Looks whether a newer copy of the note is in the cloud folder and takes it in if so (the callback is asked for permission at
  /// the moment the note would be replaced); true if it was. Null: the notes are not synced through a cloud folder.
  final Future<bool> Function(String noteId, bool Function() allow)? pullLatest;

  /// Which tools are on; null: all of them.
  final FeatureSettings? features;

  /// The spelling dictionaries; null: no spell checking.
  final SpellService? spell;

  /// The extensions: their tools are in the menu of selected text; null: none.
  final ExtensionService? extensions;

  /// Reads the text in pictures (the scanner and "read text from a picture"); null: scanning still works, reading does not.
  final OcrService? ocr;

  /// Finds the subject of a picture, to take its background out; null: only a colour can be taken out.
  final SubjectService? subject;

  /// How the pen is used (pressure, its button, fingers); null: the usual.
  final StylusSettings? stylus;

  /// Which keys do what in the editor; null: the default shortcuts.
  final ShortcutService? shortcuts;

  /// Locking the note; null hides the button.
  final NoteLockService? locks;

  /// Asks the screen to leave this note (it was locked and must be put away).
  final VoidCallback? onLeave;

  /// Opens another note beside this one (a split view); null hides the button.
  final ValueChanged<String>? onOpenBeside;

  /// Set on the note that is shown beside another: closes it (the split view ends).
  final VoidCallback? onCloseSplit;

  /// Whether this is the note that the keyboard shortcuts are for, when two notes are shown; null: it is the only one.
  final bool Function()? paneActive;

  /// A search to open the note with (from the search of all notes), and the page to start at.
  final SearchQuery? initialFind;
  final int initialPage;

  /// Adds a task (with a day) to the calendar, for the tasks the AI finds in the note; null: not offered.
  final Future<void> Function(String title, DateTime? due)? onAddTask;

  /// Reads text out loud; null: not offered.
  final ReadAloud? readAloud;

  /// Writes down what is said, for dictating into the note; null: not offered.
  final SpeechToText? speech;

  /// Flashcards kept for spaced repetition; null: not offered.
  final CardRepository? cards;

  /// The bookmarked pages and the notes that link here (the Outline in the top bar); null: not offered.
  final BookmarkRepository? bookmarks;
  final LinkRepository? links;

  /// "Remind me" about this note (a bell in the top bar); null: not offered.
  final ReminderService? reminders;

  /// Sound kept with the note (the Sound button in the top bar, "keep the sound" when dictating); null: not offered.
  final AudioRepository? audio;

  /// Makes the player for the sounds of the note; null: the one of this system.
  final SoundPlayer Function()? soundPlayer;

  /// Told when the pen's side button is pressed and is set to run a trigger (1 to 3, see `AutomationEvent.triggerPressed`); null: nothing.
  final void Function(int trigger)? onTrigger;

  /// Makes the microphone for recording while writing (the lecture button); null: the one of this system.
  final MicRecorder Function()? lectureMic;

  /// Opens another note at a page (zero-based); without it [onOpenNote] is used and the page is ignored.
  final void Function(String noteId, int? page)? onOpenNoteAt;

  /// How long the writing has to be left alone before it is read ahead of time.
  final Duration inkIdle;

  /// Reads what is on the clipboard when the person pastes (the tests pass a stand-in).
  final Future<ClipboardContent> Function()? readClipboard;

  const FixedPageNoteEditor({
    super.key,
    required this.noteId,
    required this.repository,
    this.handwriting,
    this.math,
    this.webPage,
    this.onOpenNote,
    this.onPdfImported,
    this.ai,
    this.noteFiles,
    this.collab,
    this.history,
    this.tags,
    this.tasks,
    this.calendar,
    this.pullLatest,
    this.features,
    this.spell,
    this.extensions,
    this.ocr,
    this.subject,
    this.stylus,
    this.shortcuts,
    this.locks,
    this.onLeave,
    this.onOpenBeside,
    this.onCloseSplit,
    this.paneActive,
    this.initialFind,
    this.initialPage = 0,
    this.onAddTask,
    this.readAloud,
    this.speech,
    this.cards,
    this.bookmarks,
    this.links,
    this.reminders,
    this.audio,
    this.soundPlayer,
    this.lectureMic,
    this.onTrigger,
    this.onOpenNoteAt,
    this.inkIdle = const Duration(milliseconds: 2500),
    this.readClipboard,
  });

  @override
  State<FixedPageNoteEditor> createState() => _FixedPageNoteEditorState();
}

class _FixedPageNoteEditorState extends State<FixedPageNoteEditor> with WidgetsBindingObserver implements NoteEditorHandle, InkPreparer, TitleSetter, ImageExporter, AgentEditable {
  /// Reads the writing of the note in the background: ahead of time, line by line for the maths check, and for the search (see
  /// `editor_ink_prefetch.dart`).
  late final NoteInkReader _reader = NoteInkReader(
    noteId: widget.noteId,
    handwriting: widget.handwriting,
    math: widget.math,
    idle: widget.inkIdle,
    strokes: () => _strokesPerPage,
    visiblePage: () => _visiblePage().$1,
    isQuiet: _inkQuiet,
    isOpen: () => mounted,
    isLocked: () => _lockMode != LockMode.none,
    ready: () => _ready.future,
    // (read behind the writing when the search wants it, and also when the exported PDFs carry the text: the export then finds it read)
    indexWanted: () async =>
        _inSettings(Feature.handwriting) &&
        widget.handwriting != null &&
        (await widget.repository.settings.get(inkIndexSetting) != '0' || await widget.repository.settings.get(pdfInkTextSetting) != '0' || _spellInkOn),
    saveIndex: widget.repository.text.saveInkText,
    saveReads: widget.repository.text.saveInkReads,
    loadSaved: (id) async => (
          texts: {for (final t in await widget.repository.text.inkTexts(id)) t.key: t.text},
          reads: await widget.repository.text.inkReads(id),
        ),
    onProgress: _inkProgressed,
  );

  /// The lines of maths that were checked, and who checks.
  final _marker = MathMarker();
  List<MathMark> _marks = const [];

  /// The words of the handwriting that are not spelled right, and the timer that works them out again soon after a change.
  List<InkMisspelling> _inkSpelling = const [];
  Timer? _spellTimer;

  /// The misspellings of each block of writing that has been read (by its page, key and text): a reading that arrives checks only
  /// its own block, not the whole note again. Cleared when the dictionaries change.
  final Map<String, List<InkMisspelling>> _inkSpellByBlock = {};

  /// Whether the refresh after readings arrived is due at the next frame (see [_inkProgressed]).
  bool _inkRefreshDue = false;

  /// The dictionaries changed (a word added, a language on or off): every block is checked again. A method of the state, not of an
  /// extension, so that it is the same listener when it is taken off again.
  void _inkDictionaryChanged() {
    _inkSpellByBlock.clear();
    _refreshInkSpelling();
  }

  @override
  Future<String> prepareInk({required bool text, required bool math}) => _reader.prepare(text: text, math: math);

  /// Whether a tool is on in the settings (all are when the person was never asked).
  bool _inSettings(Feature f) => widget.features?.on(f) ?? true;

  /// Whether a tool is on here: on in the settings, and used by the toolbar profile in use. A profile only ever leaves out tools
  /// of the settings; a tool that is off there is off in every profile.
  bool _on(Feature f) => _inSettings(f) && (_toolbarProfiles.where((p) => p.id == _activeToolbarProfile).firstOrNull?.tools.contains(f) ?? true);

  final Completer<void> _ready = Completer<void>();

  /// Where an automation wants the exported PDF, and what went wrong with it.
  String? _exportTo;

  /// What the handwriting says, for the text under it in the PDF being made (see `pdf_ink_text.dart`).
  PdfInkText? _inkText;
  String? _exportError;

  @override
  Future<void> get ready => _ready.future;

  /// Done once the look for a newer copy in the cloud folder is over (see [_lookForNewerCopy]).
  final Completer<void> _looked = Completer<void>();

  /// The note is loaded and, as far as can be known soon, the newest copy: a session started here starts from that. A session on the
  /// screen keeps a newer copy from replacing the note, and the folder may be slow or out of reach, so this waits a little at most.
  Future<void> _upToDate() async {
    await ready;
    await _looked.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  }

  @override
  String get noteTitle => _titleController.text.trim();

  @override
  Future<void> saveNow() => _saveNow();

  @override
  ExtensionApi get agentApi => _EditorAgentApi(this);

  @override
  Future<void> agentSetDocument(String text) async => _agentEdit(() {
        if (!_isBlank || _infinite) throw ExtensionError('This note has no written document: it is a PDF or an infinite canvas.');
        _documentController.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      });

  @override
  void setNoteTitle(String title) {
    if (!mounted) return;
    setState(() => _titleController.text = title); // (a change like any other: it is saved a moment later)
  }

  @override
  Future<List<String>> pdfTextLines() async {
    await ready;
    final doc = _pdfDocument;
    if (doc == null) return const [];
    final lines = <String>[];
    // a long document is read from its start: dates are mostly up front
    for (var i = 0; i < doc.pages.length && i < 200 && mounted && identical(doc, _pdfDocument); i++) {
      try {
        final text = await doc.pages[i].loadStructuredText();
        final page = linesOf(text.fragments.map((f) => PdfFragment(f.text, [for (final r in f.charRects) r.toRect(page: doc.pages[i])])));
        lines.addAll(page.map((l) => l.text));
      } catch (e) {
        debugPrint('reading the text of page $i failed: $e');
      }
    }
    return lines;
  }

  /// Makes a picture (PNG) of every page in the size of [preset] and saves them in the folder [dir], named after the note (and the
  /// page when there are several). Says what it did.
  @override
  Future<String> exportImagesInto(String dir, ImagePreset preset) async {
    await ready;
    if (!mounted) return tr('The note was closed');
    final pages = _picturePages;
    final name = fileNameOf(_titleController.text);
    final digits = '${pages.last + 1}'.length;
    try {
      for (final page in pages) {
        if (!mounted) return tr('The note was closed');
        final bytes = await _picturePage(page, preset, seeThrough: false);
        await File(p.join(dir, pages.length == 1 ? '$name.png' : '$name-${'${page + 1}'.padLeft(digits, '0')}.png')).writeAsBytes(bytes);
      }
    } catch (e) {
      return tr('Could not save the pictures: {error}', {'error': e});
    }
    return trCount(pages.length, 'Saved 1 picture in {dir}', 'Saved {n} pictures in {dir}').replaceAll('{dir}', dir);
  }

  /// Makes pictures of the pages in the size of [preset] and saves them at [path] (a PNG for one page, else a ZIP of them); null, or
  /// what went wrong.
  Future<String?> exportImagesTo(String path, {ImagePreset preset = ImagePreset.web, bool allPages = false, bool seeThrough = false}) async {
    await ready;
    if (!mounted) return 'the note was closed';
    _exportTo = path;
    _exportError = null;
    try {
      final pages = _picturePages;
      await _exportPictures(preset, allPages ? pages : [pages.contains(_visiblePage().$1) ? _visiblePage().$1 : pages.first], seeThrough: seeThrough);
    } finally {
      _exportTo = null;
    }
    if (_exportError != null) return _exportError;
    return File(path).existsSync() ? null : 'nothing was written';
  }

  /// Saves the page as an OpenRaster file with layers at [path] (a ZIP of them for several pages); null, or what went wrong.
  Future<String?> exportOraTo(String path, {bool allPages = false, bool seeThrough = false, ImagePreset preset = ImagePreset.web}) async {
    await ready;
    if (!mounted) return 'the note was closed';
    _exportTo = path;
    _exportError = null;
    try {
      final pages = _picturePages;
      await _exportOraPages(preset, allPages ? pages : [pages.contains(_visiblePage().$1) ? _visiblePage().$1 : pages.first], seeThrough: seeThrough);
    } finally {
      _exportTo = null;
    }
    if (_exportError != null) return _exportError;
    return File(path).existsSync() ? null : 'nothing was written';
  }

  /// Saves the pages as SVG at [path] (an SVG for one page, else a ZIP of them); null, or what went wrong.
  Future<String?> exportSvgTo(String path, {bool allPages = false, bool seeThrough = false}) async {
    await ready;
    if (!mounted) return 'the note was closed';
    _exportTo = path;
    _exportError = null;
    try {
      final pages = _picturePages;
      await _exportSvgPages(allPages ? pages : [pages.contains(_visiblePage().$1) ? _visiblePage().$1 : pages.first], seeThrough: seeThrough);
    } finally {
      _exportTo = null;
    }
    if (_exportError != null) return _exportError;
    return File(path).existsSync() ? null : 'nothing was written';
  }

  @override
  Future<String?> exportPdfTo(String path) async {
    await ready;
    if (!mounted) return 'the note was closed';
    _exportTo = path;
    _exportError = null;
    try {
      await _exportPdf();
    } finally {
      _exportTo = null;
    }
    if (_exportError != null) return _exportError;
    return File(path).existsSync() ? null : 'nothing was written';
  }


  /// Banner at the top of the note (a copy of a picture in the app's storage).
  String? _themeImage;

  /// The folder's banner, shown while the note has none of its own.
  String? _folderThemeImage;
  String? get _bannerImage => _themeImage ?? _folderThemeImage;


  /// Distance from the top of the scrolling content to the first page: the
  /// banner (it scrolls away with the pages) and a gap.
  double get _bannerExtent =>
      (_bannerImage == null ? 0 : _bannerHeight) + 16; // + the gap above page 1

  PageFormat _pageFormat = PageFormat.a4;
  bool _landscape = false;

  /// The width of a page in the page space: the size of the paper of the blank notebook (an A4 sheet is 800 across, an A5 one
  /// narrower, an A3 one wider), and always 800 for the pages of an imported PDF, which are fitted to it.
  /// An infinite canvas has one page, the whole surface ([canvasExtent] across), shown through a window that is moved and zoomed
  /// (editor_canvas.dart) instead of pages that scroll.
  double get _paperWidth => _infinite ? canvasExtent : (_pdfFilePath != null ? basePageWidth : _pageFormat.widthUnits(landscape: _landscape));

  /// Height of a page of the blank notebook (and a placeholder until a PDF
  /// page's real size is known).
  double get basePageHeight => _infinite ? canvasExtent : _paperWidth * _pageFormat.aspect(landscape: _landscape);

  /// Real displayed height per page: a PDF page is [basePageWidth] wide
  /// and keeps the aspect ratio of the original PDF page.
  final Map<int, double> _pageHeights = {};

  double _heightOf(int pageIndex) {
    if (_isDocumentPage(pageIndex)) {
      return math.max(
        basePageHeight,
        _documentContentHeight + _marginTop + _marginBottom,
      );
    }
    return _pageHeights[pageIndex] ?? basePageHeight;
  }

  /// The first page of the blank notebook carries the written document.
  bool _isDocumentPage(int pageIndex) => pageIndex == 0 && _hasDocument;

  /// The space between the sheets a long written document is shown on (the same as between pages).
  static const double _sheetGap = 24;

  /// How tall page [pageIndex] is on screen. A written document that is longer than a page is shown as the sheets it is, a gap between
  /// each (while it is written, `DocumentSheet` has them); any other page is [_heightOf].
  double _shownPageHeight(int pageIndex) {
    if (_isDocumentPage(pageIndex) && _sheetsOfDocument > 1) return _sheetsOfDocument * basePageHeight + (_sheetsOfDocument - 1) * _sheetGap;
    return _heightOf(pageIndex);
  }

  /// How many sheets the written document is on while it is written, as `DocumentSheet` has it.
  int _writtenSheets = 1;
  final GlobalKey<BlockEditorState> _documentEditor = GlobalKey();

  /// Takes the screen to the place [at] of the written document.
  void _jumpToText(int at) {
    final writing = _documentEditor.currentState;
    writing != null ? writing.goTo(at) : _readHeading(at);
  }

  /// How many sheets the written document is on as it is shown now.
  int get _sheetsOfDocument => !_hasDocument ? 1 : (_mode == CanvasInteractionMode.document ? _writtenSheets : _documentSheets);

  /// How many stops the scrollbar has: what is a page to the reader, so each sheet of the written document and each other page.
  int get _scrollStops => _pageCount + _sheetsOfDocument - 1;

  /// Scrolls to stop [stop] of the scrollbar.
  void _jumpToStop(int stop) {
    final sheets = _sheetsOfDocument;
    if (stop >= sheets) return _jumpToPage(stop - sheets + 1);
    if (stop == 0 || !_pageScroll.hasClients) return _jumpToPage(0);
    _pageScroll.jumpTo((_pageTop(0) + _rulerExtent + stop * (basePageHeight + _sheetGap) * _pageScale).clamp(0.0, _pageScroll.position.maxScrollExtent));
  }

  /// How far the pages scroll at the zoom there is now, which the list may not have been laid out for yet (once it is, it says the same).
  double _scrollReach() => math.max(0.0, _pageTop(_pageCount) + 16 - (_pageScroll.hasClients ? _pageScroll.position.viewportDimension : 0.0));

  /// Where [y], a distance down the text of the written document, is on page 1 as it is laid out (below the sheets before it).
  double _documentY(double y) {
    if (_documentSheets <= 1) return y;
    var k = 0;
    while (k < _docBreaks.length && y >= _docBreaks[k]) {
      k++;
    }
    return k * (basePageHeight + _sheetGap) + _marginTop + y - (k == 0 ? 0.0 : _docBreaks[k - 1]);
  }

  /// The entry of the table of contents for the heading at [at] in the written document, tapped while it is only read: the screen goes
  /// there. Where the heading is comes from the piece it is in once that is laid out (a piece begins where the one before it ended, a
  /// line break after); until then, from how far down the text it is.
  void _readHeading(int at) {
    final length = _documentController.text.length;
    if (length == 0) return;
    double? y;
    final context = _documentMeasureKey.currentContext, box = context?.findRenderObject();
    if (context != null && box is RenderBox && box.hasSize) {
      final paragraphs = <int, RenderParagraph>{};
      void look(Element e) {
        if (e.widget.key case LivePieceKey(:final value,) when e.renderObject is RenderParagraph) paragraphs[value] = e.renderObject as RenderParagraph;
        e.visitChildren(look);
      }

      (context as Element).visitChildren(look);
      var from = 0;
      for (final i in paragraphs.keys.toList()..sort()) {
        final paragraph = paragraphs[i]!;
        final end = from + paragraph.text.toPlainText(includeSemanticsLabels: false).length;
        if (at <= end || i == paragraphs.keys.reduce(math.max)) {
          if (paragraph.hasSize) y = paragraph.localToGlobal(paragraph.getOffsetForCaret(TextPosition(offset: (at - from).clamp(0, end - from)), Rect.zero), ancestor: box).dy;
          break;
        }
        from = end + 1;
      }
    }
    _scrollTo(0, _documentY(y ?? _documentContentHeight * at / length));
  }

  /// How many sheets the written document is shown on.
  int get _documentSheets => _mode == CanvasInteractionMode.document ? 1 : _docBreaks.length + 1;

  /// How far from the left of the page the part on screen starts (a page is always seen from its left edge).
  double get _visibleLeft => _infinite ? _viewCorner.dx : 0.0;

  /// How much of the list page [index] takes up at [scale]: the ruler above it, the page, and the gap below it.
  double _pageExtent(int index, double scale) => _rulerExtent + (_shownPageHeight(index) + 24) * scale;

  /// Distance from the top of the list to the top of page [index].
  double _pageTop(int index) {
    final scale = _pageScale;
    var top = _bannerExtent;
    for (var i = 0; i < index; i++) {
      top += _pageExtent(i, scale);
    }
    return top;
  }

  /// The page that is at [y] down the list, and how far down it, in units of the page.
  (int, double) _placeInPages(double y) {
    final scale = _pageScale;
    var top = _bannerExtent;
    for (var i = 0; i < _pageCount - 1; i++) {
      final next = top + _pageExtent(i, scale);
      if (y < next) return (i, (y - top - _rulerExtent) / scale);
      top = next;
    }
    return (math.max(0, _pageCount - 1), (y - top - _rulerExtent) / scale);
  }

  void _jumpToPage(int index) {
    if (_infinite) return _fitCanvas();
    if (!_pageScroll.hasClients) return;
    _pageScroll.jumpTo(
      (index == 0 ? 0.0 : _pageTop(index)).clamp(
        0.0,
        _pageScroll.position.maxScrollExtent,
      ),
    );
  }


  /// Left and right margin of the written document (adjusted with the ruler).
  double _marginLeft = documentMargin;
  double _marginRight = documentMargin;
  double _marginTop = documentMargin;
  double _marginBottom = documentMargin;
  final GlobalKey _documentMeasureKey = GlobalKey();
  double _documentContentHeight = 0;

  /// Where the sheets of the written document end, down from the top of its text: each at the end of a line (or at a page break), a
  /// sheet's height without its margins after the one before. Empty while the text fits on one.
  List<double> _docBreaks = const [];

  /// Where each piece of the written document begins, down from the top of its text (see `liveMarkdownPieces`).
  List<double> _docPieceTops = const [];

  /// The pieces of the written document that is only read: the first are there when the note opens, the others follow (see [LivePieces]).
  late final LivePieces _readPieces = LivePieces(atOnce: widget.initialFind != null || widget.initialPage > 0)..addListener(_morePieces);
  final Stopwatch _sinceMeasured = Stopwatch()..start();

  /// Which sheets of the written document show their text, the first and the last: a document can have hundreds, and the page is one item.
  final ValueNotifier<(int, int)> _sheetsNear = ValueNotifier((0, 8));
  late final Listenable _readSheets = Listenable.merge([_readPieces, _sheetsNear]);

  void _lookForSheets() {
    if (!_pageScroll.hasClients) return;
    final step = (basePageHeight + _sheetGap) * _pageScale;
    if (step <= 0) return;
    final first = (_pageScroll.offset / step).floor();
    _sheetsNear.value = (first - 2, first + (_pageScroll.position.viewportDimension / step).ceil() + 2);
  }

  // (working out where the sheets end again for each piece that comes in would take as long as making them)
  void _morePieces() {
    if (!_readPieces.working || _sinceMeasured.elapsedMilliseconds >= 250) _measureDocument();
  }

  /// What is known of the lines of the pieces, for the width they were measured at.
  final Map<InlineSpan, List<double>> _docLines = Map.identity();
  double _docLinesWidth = 0;

  /// Measures the written document as it is shown (one piece, however many sheets it is on) and works out where its sheets end.
  void _measureDocument() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lookForSheets();
      final context = _documentMeasureKey.currentContext;
      final box = context?.findRenderObject();
      if (context == null || box is! RenderBox || !box.hasSize) return;
      final h = box.size.height;
      if (box.size.width != _docLinesWidth) _docLines.clear();
      _docLinesWidth = box.size.width;
      _sinceMeasured.reset();
      final (:breaks, :pieceTops) = documentSheetBreaks(box, context, basePageHeight - _marginTop - _marginBottom, _docLines);
      bool same(List<double> a, List<double> b) => a.length == b.length && !a.asMap().entries.any((e) => (e.value - b[e.key]).abs() > 0.5);
      if ((h - _documentContentHeight).abs() > 1 || !same(breaks, _docBreaks) || !same(pieceTops, _docPieceTops)) {
        setState(() {
          _documentContentHeight = h;
          _docBreaks = breaks;
          _docPieceTops = pieceTops;
        });
      }
    });
  }

  late TextEditingController _titleController;

  CanvasInteractionMode _mode = CanvasInteractionMode.selectText;

  String? _importedPdfName;

  /// The style this note is cited in when it is not the one for every note: its own, else its folder's (null: the one for every note).
  CitationStyle? _citationStyle;

  /// The style this note has chosen for itself (null: none).
  CitationStyle? _ownCitationStyle;
  String? _pdfFilePath;
  int _totalPages = 0;

  // editing the imported PDF itself in document mode (editor_pdf_edit.dart)
  PdfContentEditor? _pdfEditor;
  bool _pdfEditOpening = false;
  bool _pdfEditBusy = false;
  Future<void>? _pdfEditWork; // (the edit being made, if any: the editor stays open until it is done)
  final Map<int, List<PdfEditObject>> _pdfEditObjects = {};
  final Set<int> _pdfEditLoading = {};
  (int, PdfEditObject)? _pdfEditSelected;
  (int, PdfEditObject, TextEditingController, FocusNode)? _pdfInline;
  ({String family, double factor, TextStyle style})? _pdfInlineFit;
  /// Where the picked object is while it is dragged or resized (in screen units); null when it is at rest.
  final ValueNotifier<Rect?> _pdfEditBox = ValueNotifier(null);
  final ValueNotifier<double?> _pdfEditTurn = ValueNotifier(null); // degrees while a picture is being turned
  Offset _pdfTurnMoved = Offset.zero;
  Rect? _pdfResizeStart;
  Offset _pdfResizeMoved = Offset.zero;
  PdfEditObject? _pdfEditInfoFor;
  Future<PdfFontInfo>? _pdfEditInfo;

  /// The files the PDF was in before each edit, latest last, to take edits back.
  final List<(String, String?)> _pdfEditUndo = [];

  /// The pages of the PDF that are notebook pages (added ones): the paper of the note shows on them, not the file.
  Set<int> _nativePages = {};

  /// The files the PDF was in before and after its pages were changed, kept for taking that back and doing it again.
  final Set<String> _pdfShaped = {};

  /// Counts the swaps of the PDF for another file, so that only the last one asked for happens.
  int _pdfSwapTurn = 0;

  /// Pages of the blank notebook shown while no PDF is imported.
  final LiveMarkdownController _documentController = LiveMarkdownController();

  /// Whether there is a written document at all, which is what the pages around it go by while it is being written.
  final ValueNotifier<bool> _documentThere = ValueNotifier(false);

  /// What the list of pages follows: every change of the text while the text on them is only shown; while it is written, what is typed
  /// is the business of the editor (a key would otherwise build all of the page again around it).
  Listenable get _textChanges => _mode == CanvasInteractionMode.document && _isBlank ? _documentThere : _documentController;
  PageBackground _background = PageBackground.blank;
  bool get _hasDocument =>
      _isBlank && !_infinite && _documentController.text.trim().isNotEmpty;
  bool get _isBlank => _pdfFilePath == null;

  /// The note is an infinite canvas: no pages, no paper, no PDF.
  bool get _infinite => _pageFormat.isInfinite && _isBlank;
  int get _pageCount => _infinite ? 1 : (_isBlank ? _lastUsedBlankPage + 2 : _totalPages);

  /// Whether anything was placed on notebook page [i] (the document counts for
  /// the first page).
  bool _blankPageHasContent(int i) =>
      _isDocumentPage(i) ||
      (_strokesPerPage[i] ?? []).isNotEmpty ||
      (_textBoxesPerPage[i] ?? []).isNotEmpty ||
      (_highlightsPerPage[i] ?? []).isNotEmpty ||
      (_imagesPerPage[i] ?? []).isNotEmpty;

  /// Index of the last notebook page with content, -1 if none. The notebook
  /// always shows one empty page after it.
  int get _lastUsedBlankPage {
    final indices = {
      ..._strokesPerPage.keys,
      ..._textBoxesPerPage.keys,
      ..._highlightsPerPage.keys,
      ..._imagesPerPage.keys,
      0,
    };
    var last = -1;
    for (final i in indices) {
      if (i > last && _blankPageHasContent(i)) last = i;
    }
    return last;
  }

  /// The open PDF (renders pages, extracts their text). Same on all platforms.
  PdfDocument? _pdfDocument;
  bool _isLoadingPdf = false;

  String? _currentSelectedText;

  /// The colour the next highlight of text gets.
  Color _highlightColor = highlightColors.first.$2;
  int? _currentSelectedPageIndex;

  final Map<int, Future<PdfPageData>> _pageFutures = {};

  /// The pages of [_pageFutures] that are read. The editor holds the handle of each one's picture and lets go of it when the page is
  /// far from the one in view and the pages kept take too much (see [pagesToDrop]), or when the PDF changes.
  final Map<int, PdfPageData> _pagesRead = {};

  /// Counts the times the pages were forgotten, to tell a page that was read before from one read for the PDF as it is.
  int _pagesEpoch = 0;

  Color _selectedPenColor = Colors.black;

  /// Colours the user added with the wheel (saved with the app settings).
  List<Color> _customColors = [];

  /// The order of the toolbar's sections and the ones the user hid (saved with the app settings).
  List<String> _toolbarOrder = [];
  List<String> _toolbarBottom = [];
  Set<String> _toolbarHidden = {};

  /// The named arrangements of the toolbars (none until the user makes a second one) and the one in use.
  List<ToolbarProfile> _toolbarProfiles = [];
  String? _activeToolbarProfile;

  /// Lines drawn nearly straight come out straight (a setting, on by default).
  bool _straighten = true;

  /// The draw bar shows its rarely used tools (guides, stabiliser, symmetry, onion skin, straightening, clearing the page, a plot).
  bool _moreTools = false;

  /// How steady the line is kept (0: the pen as it is, 1: a long string; saved with the settings), and the stabiliser of the line
  /// being drawn.
  double _stabiliserStrength = 0;
  LineStabiliser? _stabiliser;

  /// The guides: an overlay (thirds...), the vanishing points of a perspective drawing (as parts of the page, so that they are the same on
  /// every page), a ruler or set square on one page, whether lines follow them, and what the line being drawn follows.
  GuideOverlay _guideOverlay = GuideOverlay.none;
  List<Offset> _vanishing = const [];
  DrawingAid? _aid;
  bool _snapToGuides = true;
  GuideSnapper? _snapper;

  /// The layers of the note, and the one new lines are drawn on (see `layers.dart`).
  LayerStack _layers = LayerStack.plain;
  String _activeLayer = baseLayerId;

  /// What a line is repeated as (see [Symmetry]) and the repeats of the line being drawn, which are lines of their own.
  Symmetry _symmetry = Symmetry.off;
  List<DrawingStroke> _symmetryCopies = [];
  List<Offset Function(Offset)> _symmetryMaps = const [];

  /// Where the mirror or the centre of the turns is, as a part of the page's width and height (the middle to begin with); it is
  /// pulled by its handle on the page.
  Offset _symmetryAt = const Offset(0.5, 0.5);
  DateTime? _lastHandleTap;

  /// The line the pen for curves is making (null: none), the page it is on, what is being pulled at, where the pen was last and where
  /// it hovers.
  CurvedPath? _penPath;
  int _penPage = 0;
  ({int node, PathPart part, bool created})? _penGrab;
  Offset _penLast = Offset.zero;
  Offset? _penHover;

  /// The line whose points are being bent again with the pen for curves (it stays on the page, but is not drawn while its points are
  /// shown), or null.
  DrawingStroke? _penEditing;

  double _strokeWidth = 3.0;

  /// Highlighter: a wide, see-through pen in the chosen colour.
  bool _highlighter = false;
  double _highlighterWidth = 18;

  /// The brush the pen draws with, by [Brush.id]: the pen, the roller, or one from an extension.
  String _brush = penBrushId;

  /// The drawing tool of an extension that is chosen: a drag with the pen is handed to it, which draws in its place.
  ({InstalledExtension extension, ExtensionDrawTool tool})? _chosenDrawTool;

  /// The chosen drawing tool, if its extension is still on and may draw.
  ({InstalledExtension extension, ExtensionDrawTool tool})? get _activeDrawTool {
    final chosen = _chosenDrawTool;
    if (chosen == null || _erasing || _lassoing || _highlighter) return null;
    for (final t in widget.extensions?.drawTools ?? const <({InstalledExtension extension, ExtensionDrawTool tool})>[]) {
      if (t.extension.id == chosen.extension.id && t.tool.id == chosen.tool.id) return t;
    }
    return null;
  }

  /// The brushes or the drawing tools there are changed (an extension was switched on or off, or given leave).
  void _onBrushesChanged() {
    if (!mounted) return;
    setState(() {
      if (Brushes.byId(_brush) == null) _brush = penBrushId;
    });
  }

  /// Eraser instead of pen: removes the strokes it touches, nothing else.
  bool _erasing = false;

  /// The eyedropper is on (see `editor_eyedropper.dart`): the pointer that picks, where it is, the picture of the area it reads
  /// (and its taking, while under way), and the ring that shows the colour.
  bool _picking = false;
  int _pickPointer = -1;
  Offset _pickAt = Offset.zero;
  ({ByteData bytes, int width, int height, double ratio, RenderRepaintBoundary box})? _pickShot;
  Future<void>? _pickShooting;
  final ValueNotifier<({Offset at, Color? color})?> _pickLoupe = ValueNotifier(null);

  /// The fill bucket is on (see `editor_fill_bucket.dart`), and how big a gap in the lines it still closes.
  bool _bucket = false;
  FillGap _fillGap = FillGap.medium;

  /// The onion skin (see `editor_onion_skin.dart`): how many earlier pages show through, and whether the next one does.
  int _onionBack = 0;
  bool _onionNext = false;

  /// The pages (or the canvas) as they are shown, without the tools over them: what the eyedropper reads.
  final GlobalKey _surfaceKey = GlobalKey();

  /// What a drag with the pen draws (a line of the hand, or a shape), and where it began.
  ShapeTool _shape = ShapeTool.freehand;

  /// How the next shapes look besides the pen's colour and width: dashes and the colour inside.
  StrokeDash _shapeDash = StrokeDash.solid;
  Color? _shapeFill;

  /// Whether the fill of the next shapes runs to another colour (see `gradient.dart`).
  FillGradient? _shapeGradient;

  /// How the next connectors run; the item and side the connector being drawn began at, the item it is over now, and (for each
  /// connector) what the items were like when it was last made, to see when they have moved.
  ConnectorRoute _connectorRoute = ConnectorRoute.elbow;
  _ConnectHit? _connectFrom, _connectOver;
  final Map<String, int> _connectorSeen = {};

  /// An end of the selected connector being pulled to another item (or let go): the line, which end, and how it was.
  ({DrawingStroke stroke, bool start, StrokeLink link, List<Offset> points})? _endGrab;

  /// When a box was last grown from the side of another one (see [_growBoxFrom]).
  DateTime? _grewBoxAt;
  Offset _shapeStart = Offset.zero;

  /// A pen/mouse is on the page: the list must not scroll under it.
  bool _penDown = false;
  /// The pointer that set [_penDown]; whichever way it ends (even where the widget that took it is gone) the flag is cleared.
  int _penPointer = -1;

  /// The pressure of the pen a moment ago (smoothed), and where it hovers, for the ring that shows the size of the line.
  double? _lastPressure;
  final ValueNotifier<({int page, Offset at, double radius, bool erasing})?> _hover = ValueNotifier(null);

  /// Once a stylus has touched the screen, fingers and palms no longer draw
  /// (they only scroll).
  bool _stylusSeen = false;

  /// The pen itself (not a finger or palm) is touching the screen.
  bool _stylusDown = false;

  /// A drawing picked with a short tap: it can be dragged or deleted.
  List<DrawingStroke> _selection = [];
  int _selectedStrokePage = -1;

  /// The lines shown while something is moved, where it lines up with another thing, and the page they are on.
  List<AlignLine> _alignLines = const [];
  int _alignPage = -1;

  /// What else the lasso took in: text boxes and pictures. They are moved and
  /// deleted together with the drawings, all on [_selectedStrokePage].
  List<TextBoxWidgetModel> _groupBoxes = [];
  List<ImageItem> _groupImages = [];


  /// The lasso tool: a shape drawn around drawings selects them.
  bool _lassoing = false;
  List<Offset>? _lassoPath;
  int _lassoPage = -1;
  bool _draggingStroke = false;

  /// What the selection was like when a corner handle was taken (to scale from, and to take the resize back), and how far
  /// the handle has been pulled since, in page units.
  ({
    List<DrawingStroke> strokes,
    List<List<Offset>> points,
    List<TextBoxWidgetModel> boxes,
    List<(Offset, Size)> boxGeometry,
    List<ImageItem> images,
    List<(Offset, Size)> imageGeometry,
    Offset corner,
    Offset anchor,
    int page,
  })? _resizeStart;
  Offset _resizePulled = Offset.zero;

  /// The free transform that is going on (see `editor_free_transform.dart`); null when none is.
  _TransformSession? _xform;
  Offset _downAt = Offset.zero;
  DateTime _downTime = DateTime.now();
  double _travel = 0;

  _ElementDrag? _drag;
  Offset _dragGlobal = Offset.zero;
  Timer? _dragScroll;
  int _lastPointerDown = -1;

  /// The page under [global] and the point on it in page units. Above the first
  /// page and below the last one, those pages.
  ({int page, Offset local})? _pageAt(Offset global) {
    if (_pageCount == 0) return null;
    final p = _localInArea(global);
    if (_infinite) return (page: 0, local: _areaToCanvas(p));
    final scale = _pageScale;
    final y =
        (_pageScroll.hasClients ? _pageScroll.offset : 0.0) +
        p.dy -
        _bannerExtent;
    var top = 0.0, page = 0;
    for (var i = 0; i < _pageCount; i++) {
      page = i;
      final h = _heightOf(i) * scale;
      if (y < top + _rulerExtent + h + 12 * scale || i == _pageCount - 1) {
        break; // pages own half of the gap below them
      }
      top += _rulerExtent + h + 24 * scale;
    }
    final scrolled = _hScroll.hasClients ? _hScroll.offset : 0.0;
    final left = _pagesLeft - scrolled;
    return (
      page: page,
      local: Offset((p.dx - left) / scale, (y - top - _rulerExtent) / scale),
    );
  }

  List<NoteSummary> _noteChoices = const [];
  bool _choicesLoaded = false;

  /// The word(s) being looked up in the side panel, if any.
  ({String term, LookupSource source, Uri? address})? _lookup;
  double _lookupWidth = 420;

  /// The language "Translate" goes to: the saved choice, else the device's.
  String _translateTo = translateLanguages.containsKey(ui.PlatformDispatcher.instance.locale.languageCode)
      ? ui.PlatformDispatcher.instance.locale.languageCode
      : 'en';



  final Map<int, List<DrawingStroke>> _strokesPerPage = {};
  DrawingStroke? _currentActiveStroke;

  /// Ticks at every move of the pen while a line (or the lasso) is drawn: only what is being drawn is painted again, nothing is
  /// built (a page full of writing, or of the words of a PDF, would make every move slow).
  final _inkTick = ValueNotifier<int>(0);

  /// The marks of the maths check are looked at again a moment after a change, not at every one.
  Timer? _marksTimer;

  final Map<int, List<TextBoxWidgetModel>> _textBoxesPerPage = {};
  TextBoxWidgetModel? _activeSelectedBox;

  final Map<int, List<PdfHighlight>> _highlightsPerPage = {};
  final Map<int, List<ImageItem>> _imagesPerPage = {};
  ImageItem? _selectedImage;
  final _ZoomScrollController _pageScroll = _ZoomScrollController();
  final _ZoomScrollController _hScroll = _ZoomScrollController();
  final GlobalKey _areaKey = GlobalKey();

  /// The render box of each page's tile, to find where something on a page is on the screen.
  final Map<int, GlobalKey> _tileKeys = {};

  /// Zoom of the pages, 1 = as wide as fits (at most [_paperWidth] wide).
  double _zoom = 1.0;
  bool _zoomLocked = false;
  bool _pinching = false;
  double _viewportW = 800;

  double get _fitWidth {
    final room = _commentRoom;
    return math.min(_paperWidth, _viewportW - room.left - room.right);
  }

  /// Room kept free beside the pages for the bubbles of comments: on both sides in a wide window (the pages stay in the
  /// middle), only on the right in a narrow one such as a tablet held upright, and none on a phone, where the page would get too small.
  ({double left, double right}) get _commentRoom {
    if (_infinite || _viewportW < 480 || _commentBoxIds().isEmpty) return (left: 0.0, right: 0.0);
    return _viewportW >= 700 ? (left: 210.0, right: 210.0) : (left: 0.0, right: 180.0);
  }

  /// Screen pixels per page unit. On an infinite canvas a zoom of 1 shows 800 units across, as wide as a page would be.
  double get _pageScale => _infinite ? math.min(basePageWidth, _viewportW) / basePageWidth * _zoom : _fitWidth / _paperWidth * _zoom;

  /// How many pixels of the screen a unit of a page is. Null on an infinite canvas, whose lines are never made into pixels.
  double? get _inkPixelScale => _infinite ? null : _pageScale * MediaQuery.devicePixelRatioOf(context);

  /// About half a pixel on the screen, in page units: points of a line closer than this to where it already goes show nothing
  /// (zoomed in, it is less, so writing small and close up stays as fine as it was drawn).
  double get _inkTolerance => (0.5 / (_pageScale <= 0 ? 1 : _pageScale)).clamp(0.05, 0.5);

  /// Width of what scrolls sideways: the pages, or the screen if they are narrower. Zoomed in, the room kept for
  /// the bubbles of comments is kept beside the pages too, so that they stay next to the page instead of going onto it.
  double get _contentWidth {
    final room = _commentRoom;
    return math.max(_viewportW, _paperWidth * _pageScale + room.left + room.right);
  }

  /// Where the pages start in what scrolls sideways: in the middle of it, apart from the room kept for comments.
  double get _pagesLeft {
    final room = _commentRoom;
    return room.left + (_contentWidth - room.left - room.right - _paperWidth * _pageScale) / 2;
  }

  bool get _canZoom =>
      !_zoomLocked &&
      !_penDown &&
      (_mode != CanvasInteractionMode.draw || _fingersScroll);

  // two fingers pinch, a trackpad pinches, Ctrl and the wheel zoom
  final Map<int, Offset> _touches = {};
  double _pinchStartDistance = 1, _pinchStartZoom = 1;
  double _panZoomStartZoom = 1;
  DateTime _boxMadeAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _zoomLaidOutSoon = false;

  Offset _areaDownAt = Offset.zero;
  DateTime _areaDownTime = DateTime.now();
  double _areaTravel = 0;

  /// What is on screen of each page, rendered as sharp as the current zoom needs, over the normal picture.
  final Map<int, _SharpPatch> _hiRes = {};
  final Set<int> _hiResPending = {};

  /// Pixel width the whole of a page would have at the current zoom; 0 = the normal picture will do.
  int _hiResWidth = 0;
  Timer? _zoomSettle;
  Timer? _sharpenTimer;

  /// Everything PDFium is asked to do for the pages, one thing at a time and what is on screen first (see [PageJobs]).
  late final PageJobs _jobs = PageJobs(ranker: _jobRanker, hold: _flingingPast);

  /// The pages that are built now (on screen or about to be), with how many places show each: their work is never dropped.
  final Map<int, int> _builtPages = {};

  /// The words of the pages, read after their pictures; each page's text layer listens to its own.
  final Map<int, ({Future<PdfPageWords> future, bool urgent})> _wordFutures = {};
  final Map<int, ValueNotifier<PdfPageWords?>> _wordsOf = {};

  /// Small pictures of pages for the preview beside the scrollbar, and the page it shows now (only that one is worth making).
  final Map<int, Future<PdfPageData>> _thumbFutures = {};
  final Map<int, PdfPageData> _thumbs = {};
  int? _thumbWanted;

  /// The resolution of the settings (the most a page is rendered at), read once.
  late final Future<int> _dpiSetting = pdfRenderDpi(widget.repository)..then((d) => _dpi = d, onError: (Object _) {});
  int _dpi = 200;

  /// The screen's pixels per logical pixel, as the pages were last laid out.
  double _devicePixelRatio = 1;

  /// Which way the pages were last scrolled: what is ahead is read before what is behind.
  bool _scrollingBack = false;
  double _lastScrollOffset = 0;
  Timer? _scrollLook;

  /// Page that is mostly on screen, and how far down it the screen starts.
  (int, double) _visiblePage() {
    if (_infinite) return (0, _viewCorner.dy);
    final offset = _pageScroll.hasClients ? _pageScroll.offset : 0.0;
    var top = _bannerExtent;
    for (var i = 0; i < _pageCount; i++) {
      final h = _shownPageHeight(i) * _pageScale;
      if (top + _rulerExtent + h > offset + 100 || i == _pageCount - 1) {
        return (i, math.max(0.0, (offset - top - _rulerExtent) / _pageScale));
      }
      top += _rulerExtent + h + 24 * _pageScale; // the ruler above the page, and the gap between pages
    }
    return (0, 0);
  }

  /// Where the window on an infinite canvas is: the point of the surface at the top left of the area, in page units, and
  /// whether it was put at the start yet. [_viewTick] says that it moved (only the ruling and the position are drawn again).
  Offset _viewTopLeft = canvasOrigin;
  bool _viewPlaced = false;
  double _viewportH = 600;
  final _viewTick = ValueNotifier<int>(0);

  /// The pointer that pans the canvas with the middle button of the mouse, and what the fingers that pinch it started from.
  int _middlePan = -1;
  double _scaleBaseZoom = 1;
  int _scaleCount = 0;

  /// How far the canvas is turned on the screen (radians, clockwise), about the middle of the window; what two fingers turned it
  /// from, and what a trackpad's turn started from. Only the view turns: nothing on the canvas changes.
  double _viewTurn = 0;
  double _scaleBaseTurn = 0;
  double _panZoomStartTurn = 0;
  bool _scaleGo = false;
  double _panZoomLastScale = 1;

  bool _loaded = false;
  Object? _loadError;
  String? _pdfSha256;
  Timer? _saveTimer;
  Future<void> _saveChain = Future.value();
  int? _lastSavedSignature;

  /// How many saves failed one after the other (0: the last one went through).
  int _saveFailures = 0;
  CollabSession? _live;
  int _announcedPeople = 0; // how many were in the session when the page was last told
  int? _announcedPage; // the page last told to the others in a live session
  int _announcedSheet =
      0; // and which sheet of it (the written document can be shown as several)
  SessionState? _lastLiveState;
  /// The extensions whose brushes the note has lines of and that were told about already (once for each, as long as the editor is open).
  final _toldAboutExtensions = <String>{};
  EditorHooks? _hooks;

  @override
  void initState() {
    super.initState();
    unawaited(DocumentImages.init().catchError((Object _) {}));
    _pageScroll.addListener(_schedulePrefetch);
    _pageScroll.addListener(_announceView);
    _pageScroll.addListener(_lookForSheets);
    Brushes.changes.addListener(_onBrushesChanged);
    widget.extensions?.addListener(_onBrushesChanged);
    widget.repository.settings.get('translate_to').then((v) {
      if (mounted && v != null && translateLanguages.containsKey(v)) setState(() => _translateTo = v);
    });
    widget.repository.settings.get(_EditorAssistant._agentModeSetting).then((v) {
      _agentMode = v == '1';
      if (mounted && _agentMode) _assistant?.acting = true;
    });
    _shortcuts.addHandler(_onShortcut);
    WidgetsBinding.instance.addObserver(this);
    widget.features?.addListener(_syncMathCheck);
    widget.spell?.addListener(_inkDictionaryChanged);
    _syncMathCheck();
    _documentController.useSpelling(widget.spell);
    _titleController = TextEditingController();
    _documentController.addListener(_scheduleSave);
    _documentController.addListener(() => _documentThere.value = _documentController.text.isNotEmpty);
    _documentController.addListener(() => _echoesSoon(() => withoutParagraphFormats(_documentController.text)));
    if (widget.ai != null) _assistant = _newAssistant();
    if (widget.collab != null) {
      // someone opened a copy of this note: the session is started here, with the note as it is on screen
      widget.collab!.registerEditor(
          widget.noteId,
          _hooks = EditorHooks(
            start: (invite) async {
              await _upToDate();
              if (mounted) await _startLive(invite);
            },
            startOwn: (invite, transport) async {
              await _upToDate();
              if (mounted) await _startLive(invite, transport, true);
            },
            bind: () {
              if (mounted) _bindLive();
            },
            merge: (ops) async {
              await ready;
              if (mounted) _mergeOffline(ops);
            },
            save: () async {
              await ready;
              if (mounted) await _saveNow();
            },
          ));
    }
    _loadCustomColors();
    _load();
  }

  // ---- comments beside the page

  AssistantChat? _assistant;

  /// Whether the assistant was left acting on notes instead of answering (kept in the settings).
  bool _agentMode = false;
  bool _assistantOpen = false;

  /// The history of the note is open beside it.
  bool _historyOpen = false;

  /// The layers, the outline and the sounds of the note are open beside it (see [_EditorSidePanels]).
  bool _layersOpen = false;
  bool _outlineOpen = false;
  bool _audioOpen = false;

  /// The stamp library is open beside the note; [_stampsTick] counts up when a stamp was added.
  bool _stampsOpen = false;

  /// The picture being edited in the panel beside the note, and what waits for the answer.
  ({Uint8List bytes, Completer<PictureEditResult?> done})? _pictureEditing;
  final _stampsTick = ValueNotifier<int>(0);

  /// What the AI made of the note is open beside it; [_generatedTick] counts up when that changed.
  bool _generatedOpen = false;
  final _generatedTick = ValueNotifier<int>(0);

  @override
  void didUpdateWidget(FixedPageNoteEditor old) {
    super.didUpdateWidget(old);
    if (old.spell != widget.spell) {
      old.spell?.removeListener(_inkDictionaryChanged);
      widget.spell?.addListener(_inkDictionaryChanged);
      _inkDictionaryChanged();
      _documentController.useSpelling(widget.spell);
      for (final boxes in _textBoxesPerPage.values) {
        for (final b in boxes) {
          b.controller.useSpelling(null); // (a box that is edited again takes it up again)
        }
      }
    }
    if (old.features != widget.features) {
      old.features?.removeListener(_syncMathCheck);
      widget.features?.addListener(_syncMathCheck);
    }
    if (old.features != widget.features || old.math != widget.math || old.handwriting != widget.handwriting) _syncMathCheck();
    // the AI was switched off or on while the note is open
    if (widget.ai == null && _assistant != null) {
      final gone = _assistant!;
      _assistant = null;
      _assistantOpen = false;
      _generatedOpen = false;
      gone.stop();
      // the panel that shows it is still in this frame
      WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
    } else if (widget.ai != null && _assistant == null) {
      _assistant = _newAssistant();
    }
  }

  /// The text of each PDF page, read once (it does not change).
  List<String>? _pdfPageTexts;

  // undoing every kind of change (editor_undo.dart)
  _Meta? _metaBase;
  Timer? _metaTimer;
  bool _recordingMeta = false;
  bool _favorite = false;

  /// Plays the sounds of the note (made when first needed).
  SoundPlayer? _soundPlayer;

  /// The recording that goes on while the note is written (the lecture button), and where each element was written in the recordings
  /// that were made (by the element's id).
  LectureRecorder? _lecture;
  Map<String, SoundPoint> _soundMarks = const {};
  final Map<int, int> _lectureCounts = {};

  /// Following the sound that plays: which recording it is (null: not one with marks, or not known yet), its marks in order, the
  /// elements lit at this moment and the page they are on.
  String? _followPath, _followAudioId;
  SoundTimeline? _followTimeline;
  final ValueNotifier<Set<String>> _followIds = ValueNotifier(const {});
  int? _followPage;

  /// Other notes that have facts about what was written last (see [EchoIndex]), and the text that is looked through.
  List<Echo> _echoes = const [];
  EchoIndex? _echoIndex;
  DateTime? _echoIndexAt;
  Timer? _echoTimer;
  String Function()? _echoText;
  String? _echoLooked;
  Map<String, String> _echoTitles = const {};
  bool _echoHidden = false;

  /// The note is being presented: its pages are not drawn here (the presentation draws them, with the same keys).
  bool _presenting = false;

  /// The bookmarked pages of the note.
  final ValueNotifier<List<PageBookmark>> _bookmarks = ValueNotifier(const []);
  LockMode _lockMode = LockMode.none;

  /// The note was encrypted and its content taken out of the database: nothing of it may be written back.
  bool _sealedAway = false;
  final ValueNotifier<int> _undoTick = ValueNotifier(0);

  // finding words in the note (editor_find.dart)
  bool _findOpen = false;
  SearchQuery _findQuery = const SearchQuery('');
  List<_FindMatch> _found = const [];
  int _foundAt = -1;
  String? _findNote;
  final TextEditingController _findField = TextEditingController();
  final FocusNode _findFocus = FocusNode();
  bool _replaceOpen = false;
  final TextEditingController _replaceField = TextEditingController();
  final FocusNode _replaceFocus = FocusNode();
  Timer? _findDebounce;
  int _findRun = 0;

  Future<void> _load({bool reload = false}) async {
    try {
      final note = await widget.repository.loadNote(widget.noteId);
      if (note == null) {
        throw StateError('note ${widget.noteId} no longer exists');
      }

      var pdfPath = note.pdfPath;
      String? warning;
      PdfDocument? doc;
      if (pdfPath != null && !await File(pdfPath).exists()) {
        warning = tr('The PDF of this note is missing ({name}); its annotations were kept.', {'name': note.pdfName});
        pdfPath = null;
      } else if (pdfPath != null) {
        try {
          doc = await openPdfFile(pdfPath);
        } catch (e) {
          warning = tr('The PDF of this note could not be opened: {error}', {'error': e});
          pdfPath = null;
        }
      }

      if (!mounted) {
        doc?.dispose();
        return;
      }
      setState(() {
        _titleController.text = note.title;
        _background = note.background;
        _layers = note.layers;
        _pageFormat = note.pageFormat;
        _themeImage = note.themeImage;
        _folderThemeImage = note.folderThemeImage;
        _landscape = note.landscape;
        _nativePages = Set.of(note.nativePages);
        _marginLeft = note.marginLeft;
        _marginRight = note.marginRight;
        _marginTop = note.marginTop;
        _marginBottom = note.marginBottom;
        _documentController.text = note.documentText;
        _documentController.attributes
          ..clear()
          ..addAll(note.documentSpans);
        _undoStack.clear();
        _strokesPerPage
          ..clear()
          ..addAll(note.strokes);
        _highlightsPerPage
          ..clear()
          ..addAll(note.highlights);
        _imagesPerPage
          ..clear()
          ..addAll(note.images);
        _textBoxesPerPage
          ..clear()
          ..addAll(note.textBoxes);
        for (final boxes in note.textBoxes.values) {
          boxes.forEach(_attachBox);
        }
        _importedPdfName = pdfPath == null ? null : note.pdfName;
        _pdfFilePath = pdfPath;
        _pdfSha256 = note.pdfSha256;
        _pdfDocument = doc;
        _totalPages = doc?.pages.length ?? 0;
        if (doc != null) _applyPageSizes(doc);
        _loaded = true;
        if (!_ready.isCompleted) _ready.complete();
        _lastSavedSignature = _signature();
        _metaBase = _captureMeta();
        _readCitationStyle();
        widget.locks?.modeOf(widget.noteId).then((m) {
          if (mounted && m != _lockMode) setState(() => _lockMode = m);
        });
        _loadSoundMarks();
        widget.repository.isFavorite(widget.noteId).then((v) {
          if (mounted && v != _favorite) setState(() => _favorite = v);
        });
        widget.bookmarks?.list(widget.noteId).then((marks) {
          if (mounted) _bookmarks.value = marks;
        });
        _undoStack.onPush = _absorbMeta;
      });
      _warnMissingExtensionBrushes();
      if (reload) return;
      if (widget.collab != null) _bindLive();
      unawaited(_lookForNewerCopy());
      unawaited(_reader.restore().then((_) => _reader.startIndex()));
      final find = widget.initialFind;
      if (find != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _openFind(query: find, page: math.max(0, widget.initialPage)) : null);
      } else if (widget.initialPage > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _jumpToPage(widget.initialPage) : null);
      }
      if (warning != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(warning)));
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
      if (!_ready.isCompleted) _ready.complete();
      if (!_looked.isCompleted) _looked.complete();
    }
  }

  /// The note is on the screen as it is here; a look whether the cloud folder has a newer copy, which replaces it if the person has not
  /// started on the note by then (nor a live session) - the note never waits for this.
  Future<void> _lookForNewerCopy() async {
    final pull = widget.pullLatest;
    if (pull == null) {
      if (!_looked.isCompleted) _looked.complete();
      return;
    }
    final before = _lastSavedSignature;
    try {
      final taken = await pull(widget.noteId, () => mounted && _live == null && _lastSavedSignature == before && _signature() == before);
      if (!taken || !mounted) return;
      await _load(reload: true);
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('Updated: a newer copy of this note came from the cloud'))));
    } catch (e) {
      debugPrint('[cloud] newer copy of ${widget.noteId}: $e');
    } finally {
      if (!_looked.isCompleted) _looked.complete();
    }
  }

  /// Every setState is a possible change: save shortly after the last one.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleSave();
    _observeLecture();
    // a line of the pen for curves is finished when the pen is put down (another tool, another mode)
    if (_penPath != null && !_penToolOn && _penGrab == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _penPath != null && !_penToolOn) _finishPenPath();
      });
    }
  }

  void _scheduleSave() {
    if (!_loaded) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _saveNow);
    _metaSoon(); // so is what changed that is not a stroke, for the undo button
    _ink?.changed(); // the writing that changed is read again, a moment later
    _refreshInkSpellingSoon();
    if (_checkOn) {
      _marksTimer?.cancel();
      _marksTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted && _checkOn) _refreshMarks();
      });
    }
    _live?.localChanged(); // what changed goes to the others, a moment later
  }

  NoteData _snapshot() => NoteData(
    id: widget.noteId,
    title: _titleController.text,
    background: _background,
    layers: _layers,
    pageFormat: _pageFormat,
    landscape: _landscape,
    marginLeft: _marginLeft,
    marginRight: _marginRight,
    marginTop: _marginTop,
    marginBottom: _marginBottom,
    documentText: _documentController.text,
    documentSpans: List.of(_documentController.attributes),
    pdfName: _pdfFilePath == null ? null : _importedPdfName,
    pdfPath: _pdfFilePath,
    pdfSha256: _pdfFilePath == null ? null : _pdfSha256,
    pdfPageCount: _pdfFilePath == null ? null : _totalPages,
    nativePages: _pdfFilePath == null ? null : Set.of(_nativePages),
    strokes: _strokesPerPage,
    textBoxes: _textBoxesPerPage,
    highlights: _highlightsPerPage,
    images: _imagesPerPage,
  );

  /// Cheap fingerprint of everything that is saved, so that UI-only setStates
  /// (mode switches, selections) do not rewrite the note.
  int _signature() => Object.hashAll([
    _titleController.text,
    _background,
    _layers.fingerprint,
    _pageFormat,
    _landscape,
    _marginLeft,
    _marginRight,
    _marginTop,
    _marginBottom,
    _documentController.text,
    ..._documentController.attributes.map(
      (a) => a.fingerprint
    ),
    _pdfFilePath,
    _totalPages,
    ..._nativePages,
    for (final e in _strokesPerPage.entries)
      for (final s in e.value)
        Object.hash(e.key, s.stamp),
    for (final e in _textBoxesPerPage.entries)
      for (final b in e.value)
        Object.hash(
          e.key,
          b.id,
          b.layer,
          b.group,
          b.position,
          b.size,
          b.fontSize,
          b.style,
          b.controller.text,
          Object.hashAll(
            b.controller.attributes.map(
              (a) => a.fingerprint
            )
          ),
        ),
    for (final e in _highlightsPerPage.entries)
      for (final h in e.value) Object.hash(e.key, h.rect, h.color, h.commentBox),
    for (final e in _imagesPerPage.entries)
      for (final m in e.value) Object.hash(e.key, m.id, m.layer, m.group, m.position, m.size),
  ]);

  Future<void> _saveNow() {
    if (_sealedAway) return _saveChain; // (an encrypted note is not written back)
    final sig = _signature();
    if (!_loaded || sig == _lastSavedSignature) return _saveChain;
    _lastSavedSignature = sig;
    final note = _snapshot();
    // one save at a time, in order
    return _saveChain = _saveChain
        .then((_) => widget.repository.saveNote(note))
        .then((_) => _savedNow())
        .catchError((Object e) {
          _lastSavedSignature = null; // try again on the next change
          debugPrint('saving note failed: $e');
          _saveFailed(e);
        });
  }

  /// A save did not go through (no room left on the device, the database is locked): the person is told, once, and it is tried again
  /// after 3 seconds, then 10, then every 30, for as long as the note is open, and not only when something changes.
  void _saveFailed(Object e) {
    _saveFailures++;
    if (!mounted) return;
    if (_saveFailures == 1) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 30),
        content: Text.verbatim(tr('The note could not be saved: {error}. It is tried again.', {'error': e})),
        action: SnackBarAction(label: tr('Try now'), onPressed: () => unawaited(_saveNow())),
      ));
    }
    const waits = [3, 10, 30];
    _saveTimer?.cancel();
    _saveTimer = Timer(Duration(seconds: waits[math.min(_saveFailures, waits.length) - 1]), () => unawaited(_saveNow()));
  }

  /// A save went through; after failed ones, the person is told that the note is safe.
  void _savedNow() {
    if (_saveFailures == 0) return;
    _saveFailures = 0;
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tr('The note is saved again'))));
  }

  /// A system that moves the app out of sight may stop it without warning (Android does, to free
  /// memory): what was drawn in the last moments is written now, not when the timer would fire.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _saveTimer?.cancel();
      _saveNow();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // (asking for the library makes this run again when it changes: after a sync, or a folder was given a style)
    if (CitationScope.maybeOf(context) != null && _loaded) _readCitationStyle();
  }

  @override
  void dispose() {
    _soundPlayer?.dispose();
    _followIds.dispose();
    _finishLectureOnClose();
    _echoTimer?.cancel();
    _bookmarks.dispose();
    Brushes.changes.removeListener(_onBrushesChanged);
    widget.extensions?.removeListener(_onBrushesChanged);
    if (_hooks != null) widget.collab?.unregisterEditor(widget.noteId, _hooks!);
    _releaseLive();
    WidgetsBinding.instance.removeObserver(this);
    _shortcuts.removeHandler(_onShortcut);
    widget.readAloud?.stop(); // (the reading stops with the note)
    _assistant?.dispose();
    _generatedTick.dispose();
    _stampsTick.dispose();
    _endPictureEdit(null);
    widget.features?.removeListener(_syncMathCheck);
    _reader.dispose();
    _saveTimer?.cancel();
    _scrollLook?.cancel();
    _sharpenTimer?.cancel();
    _jobs.dispose();
    _pageScroll.removeListener(_schedulePrefetch);
    _pageScroll.removeListener(_announceView);
    _pageScroll.removeListener(_lookForSheets);
    _pageScroll.dispose();
    _hScroll.dispose();
    _findDebounce?.cancel();
    _hover.dispose();
    _pickLoupe.dispose();
    _inkTick.dispose();
    _viewTick.dispose();
    _marksTimer?.cancel();
    _spellTimer?.cancel();
    widget.spell?.removeListener(_inkDictionaryChanged);
    _metaTimer?.cancel();
    _undoTick.dispose();
    _findField.dispose();
    _findFocus.dispose();
    _replaceField.dispose();
    _replaceFocus.dispose();
    _zoomSettle?.cancel();
    _dragScroll?.cancel();
    for (final patch in _hiRes.values) {
      patch.dispose();
    }
    for (final words in _wordsOf.values) {
      words.dispose();
    }
    for (final data in _thumbs.values) {
      data.release();
    }
    _closePdfEditor();
    // (the files the PDF was in before its edits and page changes go once the note is saved with the one it is in now: if that save
    // fails, the note still has a file to open)
    final keep = _pdfFilePath;
    final superseded = [for (final (path, _) in _pdfEditUndo) path, ..._pdfShaped].where((path) => path != keep).toList();
    _pdfEditUndo.clear();
    _pdfShaped.clear();
    _pdfEditBox.dispose();
    _pdfEditTurn.dispose();
    for (final data in _pagesRead.values) {
      data.release();
    }
    _pagesRead.clear();
    _pdfDocument?.dispose();
    // flush, and only free the controllers once the save has read them
    _saveNow().whenComplete(() {
      if (_lastSavedSignature != null) {
        for (final path in superseded) {
          File(path).delete().catchError((Object _) => File(path));
        }
      }
      _titleController.dispose();
      for (var pageBoxes in _textBoxesPerPage.values) {
        for (var box in pageBoxes) {
          box.controller.dispose();
          box.focusNode.dispose();
        }
      }
      _documentController.dispose();
      _documentThere.dispose();
      _readPieces.dispose();
      _sheetsNear.dispose();
    });
    super.dispose();
  }


  final Map<int, GlobalKey<SelectionAreaState>> _areaKeys = {};

  final Map<(int, int, int), GlobalKey> _wordKeys = {};

  /// Whether this is a computer with a mouse (a double tap is for touch screens).
  bool get _desktop =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS);

  int _clicks = 0;
  DateTime _lastClickTime = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastClickAt = Offset.zero;

  String? _lastClipboardProblem;

  /// How high the buttons of the top bar are, wrapped onto as many rows as they need, and how wide they are in one row.
  double _topBarHeight = kToolbarHeight;
  double _topButtonsWidth = 0;

  /// The buttons of the top bar, in as many rows as they need (the bar is made as high as they are).
  Widget _topButtons(List<Widget> buttons, Alignment at) => SizedBox(
        height: _topBarHeight,
        child: OverflowBox(
          alignment: at,
          minHeight: 0,
          maxHeight: double.infinity,
          child: HeightReporter(
            onHeight: (h) {
              if (mounted && (h - _topBarHeight).abs() > 0.5) setState(() => _topBarHeight = h);
            },
            onWidth: (w) {
              if (mounted && (w - _topButtonsWidth).abs() > 0.5) setState(() => _topButtonsWidth = w);
            },
            child: Wrap(
              alignment: at == Alignment.center ? WrapAlignment.center : WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: buttons,
            ),
          ),
        ),
      );

  void _setLoadingPdf(bool v) => setState(() => _isLoadingPdf = v);

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        body: Center(
          child: _loadError != null
              ? Text.verbatim(tr('Could not open the note: {error}', {'error': _loadError}))
              : const CircularProgressIndicator.adaptive(),
        ),
      );
    }
    // the title gets the room it needs (up to half the width); the buttons take the rest and scroll sideways if it is too little
    final screenWidth = MediaQuery.sizeOf(context).width;
    final titlePainter = TextPainter(
      text: TextSpan(text: _titleController.text.isEmpty ? tr('Note Title...') : _titleController.text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final titleWidth = (titlePainter.width + 24).clamp(220.0, math.max(220.0, screenWidth / 2)).toDouble();
    titlePainter.dispose();
    final buttons = _toolbarButtons(context);
    final buttonsWidth = math.max(200.0, screenWidth - titleWidth - 180 - (_toolbarProfiles.length > 1 ? _profileMenuWidth : 0));
    // (beside the title when they fit there in one row, else a row of their own, with as many rows as they need)
    final buttonsBelow = _topButtonsWidth > buttonsWidth;
    return CitationStyleScope(
      style: _citationStyle,
      wholeText: _noteCitationText,
      child: Scaffold(
      appBar: AppBar(
        toolbarHeight: buttonsBelow ? kToolbarHeight : math.max(kToolbarHeight, _topBarHeight + 8),
        // on a phone the note has the whole screen, so the way back to the notes is here
        leading: widget.onLeave != null && MediaQuery.sizeOf(context).width < 600
            ? IconButton(key: const ValueKey('editor-back'), tooltip: tr('Back'), icon: const BackButtonIcon(), onPressed: widget.onLeave)
            : null,
        title: SizedBox(
          width: titleWidth,
          child: TextField(
            controller: _titleController,
            onChanged: (_) {
              _scheduleSave();
              setState(() {}); // the field grows with the title
            },
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              hintText: tr('Note Title...'),
              filled: false, border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        actions: [
          // (beside the buttons, so that it is always in reach)
          ?_toolbarProfileMenu(),
          // the buttons take more rows when the screen is too narrow for them in one
          if (!buttonsBelow) SizedBox(width: buttonsWidth, child: _topButtons(buttons, Alignment.centerRight)),
        ],
        // (too many to fit beside the title: a row of their own under it, as many rows as they need)
        bottom: buttonsBelow
            ? PreferredSize(
                preferredSize: Size.fromHeight(math.max(0, _topBarHeight)),
                child: SizedBox(width: screenWidth, child: _topButtons(buttons, Alignment.center)),
              )
            : null,
      ),
      // formatting bar for whatever Markdown is being edited right now
      bottomNavigationBar: _bottomBars(),
      body: _withDrawBar(
        Column(
          children: [
            if (_findOpen && !_roomForSidePanel) _findBar(),
            Expanded(
              child: Stack(
                key: _areaKey,
                children: [
                  RepaintBoundary(key: _surfaceKey, child: LayoutBuilder(builder: (context, box) => _infinite ? _canvasArea(box) : _pagesArea(box))),
                  ..._toolsOverSurface(),
                  Positioned(left: 8, top: 8, child: _buildZoomControls()),
                  if (_echoes.isNotEmpty && !_echoHidden) Positioned(left: 8, bottom: 8, right: 56, child: _echoChip()),
                  if (!_infinite)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: 40,
                    child: AnimatedBuilder(
                      animation: _textChanges,
                      builder: (context, _) => PageScrollbar(
                        controller: _pageScroll,
                        pageCount: _scrollStops,
                        onJumpToPage: _jumpToStop,
                        previewBuilder: _stopPreview,
                        markers: _presenceMarkers(),
                      ),
                    ),
                  ),
                  if (_pickingOn) _eyedropperLayer(),
                  _eyedropperLoupe(),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  final UndoStack _undoStack = UndoStack();

  /// Strokes rubbed out during the current stroke of the eraser, with where
  /// they were; one gesture is one step.
  final List<({int page, int index, DrawingStroke stroke})> _erased = [];

  /// Where the drawings being moved were, to take the move back.
  ({
    List<DrawingStroke> strokes,
    List<List<Offset>> points,
    List<TextBoxWidgetModel> boxes,
    List<Offset> boxAt,
    List<ImageItem> images,
    List<Offset> imageAt,
    int page,
  })? _strokeDragStart;


  /// The shape of each text box as it is drawn, to export it as big as it is here.
  final Map<String, GlobalKey> _boxKeys = {};

  /// Where a pull on the corner handle of [box] started: its height then.
  double? _resizeFrom;


}

/// Something being moved with the pointer: a text box, a picture or the selected drawings.
class _ElementDrag {
  final int pointer;
  final Object element;

  /// Where the pointer took hold, from the top left of the thing, in page units.
  final Offset grab;

  _ElementDrag(this.pointer, this.element, this.grab);
}
