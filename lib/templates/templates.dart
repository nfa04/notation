import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart' show Icons, IconData;

import '../data/note_data.dart';
import '../data/note_file_service.dart';
import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../models/canvas_models.dart';
import '../models/page_background.dart';
import '../markdown/document_templates.dart';
import '../models/page_format.dart';
import 'template_documents.dart';

/// A page to start a note from that comes with the app.
class BuiltInTemplate {
  final String id;
  final String name;
  final String about;
  final IconData icon;

  /// Fills a new note (its title is set by the service).
  final void Function(NoteData note, DateTime today) fill;

  final TemplateGroup group;

  const BuiltInTemplate(this.id, this.name, this.about, this.icon, this.fill, {this.group = TemplateGroup.personal});
}

TextBoxWidgetModel _box(String id, double x, double y, double w, double h, String text, {double size = 15}) => TextBoxWidgetModel(
      id: id,
      position: Offset(x, y),
      size: Size(w, h),
      initialText: text,
      fontSize: size,
      style: const TextBoxStyle(background: Color(0xFFFFFFFF), opacity: 0, borderWidth: 1.5, borderColor: Color(0xFF9E9E9E), radius: 4),
    );

/// A frame to draw in: an empty box with a hard edge ([width] of the line), which the pen can draw over and the eraser leaves alone.
TextBoxWidgetModel _frame(String id, double x, double y, double w, double h, {double width = 2, String text = ''}) => TextBoxWidgetModel(
      id: id,
      position: Offset(x, y),
      size: Size(w, h),
      initialText: text,
      fontSize: 13,
      style: TextBoxStyle(background: const Color(0xFFFFFFFF), opacity: 0, borderWidth: width, borderColor: const Color(0xFF424242), radius: 0),
    );

/// The pages of a storyboard: [frames] 16:9 frames (two across), each with a box under it for what happens and what is said.
Map<int, List<TextBoxWidgetModel>> _storyboard(int frames) {
  const left = 30.0, gap = 20.0, width = 360.0, height = 202.5, caption = 56.0, pitch = height + caption + 24;
  return {
    0: [
      _box('title', left, 24, 740, 44, tr('**Storyboard**  ·  scene: ')),
      for (var i = 0; i < frames; i++) ...[
        _frame('frame${i + 1}', left + (i % 2) * (width + gap), 84 + (i ~/ 2) * pitch, width, height),
        _box('caption${i + 1}', left + (i % 2) * (width + gap), 84 + (i ~/ 2) * pitch + height + 4, width, caption, '${i + 1}.  ', size: 13),
      ],
      _box('notes', left, 84 + ((frames + 1) ~/ 2) * pitch, 740, 150, tr('**Notes**  ·  sound, music, dialogue\n')),
    ],
  };
}

/// A comic page: panels of different sizes with a gutter between them.
Map<int, List<TextBoxWidgetModel>> _comicPage() {
  const left = 30.0, top = 30.0, gutter = 10.0, whole = 740.0;
  const wide = 450.0, narrow = whole - wide - gutter, third = (whole - 2 * gutter) / 3;
  const row1 = 330.0, row2 = 360.0, row3 = 340.0;
  const y2 = top + row1 + gutter, y3 = y2 + row2 + gutter;
  return {
    0: [
      _frame('panel1', left, top, wide, row1, width: 3),
      _frame('panel2', left + wide + gutter, top, narrow, row1, width: 3),
      _frame('panel3', left, y2, whole, row2, width: 3),
      for (var i = 0; i < 3; i++) _frame('panel${i + 4}', left + i * (third + gutter), y3, third, row3, width: 3),
    ],
  };
}

/// Where a template is in the picker.
enum TemplateGroup { paper, school, work, personal, creative }

BuiltInTemplate _paper(String id, String name, String about, IconData icon, PageBackground background, {PageFormat? format}) =>
    BuiltInTemplate(id, name, about, icon, (n, d) {
      if (format != null) n.pageFormat = format;
      n.background = background;
    }, group: TemplateGroup.paper);

BuiltInTemplate _text(String id, TemplateGroup group, String name, String about, IconData icon, String Function(DateTime d) text, {PageBackground background = PageBackground.blank}) =>
    BuiltInTemplate(id, name, about, icon, (n, d) {
      n.background = background;
      n.documentText = text(d);
    }, group: group);

/// The written documents of [documentTemplates] (letters, essays, reports...) as pages to start from too.
BuiltInTemplate _document(String id, TemplateGroup group, String name) {
  final t = documentTemplates.firstWhere((e) => e.$1 == name);
  return BuiltInTemplate(id, tr(t.$1), tr(t.$2), t.$3, (n, d) {
    n.background = PageBackground.blank;
    n.documentText = t.$4;
  }, group: group);
}

/// The pages that come with the app. Words are looked up when a note is made, so they follow the language then in use.
List<BuiltInTemplate> builtInTemplates() => [
      _paper('canvas', tr('Infinite canvas'), tr('One surface without edges: move and zoom it, no pages (and no PDF export)'), Icons.all_inclusive, PageBackground.blank, format: PageFormat.infinite),
      _paper('lines', tr('Lined paper'), tr('Ruled lines, nothing else'), Icons.format_align_justify, PageBackground.lines),
      _paper('grid', tr('Graph paper'), tr('A grid for sketches, tables and maths'), Icons.grid_on, PageBackground.grid),
      _paper('dots', tr('Dot grid'), tr('Dots to guide lettering, sketches and journals'), Icons.apps, PageBackground.dots),
      _paper('isometric', tr('Isometric paper'), tr('A triangular grid for isometric drawings and 3D sketches'), Icons.view_in_ar_outlined, PageBackground.isometric),
      _paper('music', tr('Music paper'), tr('Staves for writing notes by hand'), Icons.music_note_outlined, PageBackground.staff),
      _paper('tab', tr('Guitar tab'), tr('Six-line tablature staves'), Icons.queue_music_outlined, PageBackground.tab),
      // School
      _text('lecture', TemplateGroup.school, tr('Lecture notes'), tr('Key ideas, definitions, examples and open questions, with the date filled in'), Icons.school_outlined, lectureText, background: PageBackground.lines),
      BuiltInTemplate('cornell', tr('Cornell notes'), tr('Cues on the left, notes on the right, a summary at the bottom: write the questions after the lecture'), Icons.view_sidebar_outlined, (n, d) {
        n.background = PageBackground.blank;
        n.textBoxes = {
          0: [
            _box('cues', 30, 40, 200, 700, '${tr('**Cues**')}\n${tr('(questions and keywords, written afterwards)')}\n'),
            _box('notes', 250, 40, 520, 700, '${tr('**Notes**')}  ·  ${templateDay(d)}\n'),
            _box('summary', 30, 760, 740, 180, '${tr('**Summary**')}\n${tr('(the page in two or three sentences)')}\n'),
          ],
        };
      }, group: TemplateGroup.school),
      _text('study', TemplateGroup.school, tr('Study sheet'), tr('What to know and a question and answer table that flashcards can be made from'), Icons.quiz_outlined, (d) => studyText()),
      _text('exam', TemplateGroup.school, tr('Exam planner'), tr('Subjects, dates and how far you are, worked out as a percentage'), Icons.event_note_outlined, (d) => examText()),
      _text('reading', TemplateGroup.school, tr('Reading notes'), tr('For a book or an article: the argument, quotes and what you think'), Icons.menu_book_outlined, readingText),
      _text('lab', TemplateGroup.school, tr('Lab report'), tr('Aim, method, a table of measurements with the mean worked out, result and error'), Icons.science_outlined, labText),
      _document('doc-essay', TemplateGroup.school, 'Essay'),
      // Work
      _text('meeting', TemplateGroup.work, tr('Meeting notes'), tr('Who was there, what was decided, and a table of who does what by when'), Icons.groups_outlined, meetingText),
      _text('project', TemplateGroup.work, tr('Project plan'), tr('Goal, milestones with a status, next actions, risks and a log'), Icons.flag_outlined, projectText),
      _text('weekly', TemplateGroup.work, tr('Weekly plan'), tr('Goals, a table for the seven days and a review at the end'), Icons.date_range_outlined, weeklyText),
      _document('doc-report', TemplateGroup.work, 'Report'),
      _document('doc-letter', TemplateGroup.work, 'Letter'),
      _document('doc-cover', TemplateGroup.work, 'Cover letter'),
      _document('doc-cv', TemplateGroup.work, 'CV'),
      // Personal
      _text('daily', TemplateGroup.personal, tr('Daily plan'), tr('The three things that matter, the day by the hour and a look back in the evening'), Icons.today_outlined, dailyText, background: PageBackground.lines),
      _text('todo', TemplateGroup.personal, tr('To-do list'), tr('Tasks to tick off: today, this week, some day'), Icons.checklist, (d) => todoText()),
      _text('habits', TemplateGroup.personal, tr('Habit tracker'), tr('A week of habits; the days you kept each one are counted for you'), Icons.published_with_changes_outlined, habitsText),
      _text('budget', TemplateGroup.personal, tr('Monthly budget'), tr('Income and expenses; what is left and the totals are worked out'), Icons.account_balance_wallet_outlined, budgetText),
      _text('trip', TemplateGroup.personal, tr('Trip planner'), tr('Packing list, day by day and what it costs in all'), Icons.luggage_outlined, tripText),
      _text('recipe', TemplateGroup.personal, tr('Recipe'), tr('Ingredients, steps and what to change next time'), Icons.restaurant_outlined, (d) => recipeText()),
      _text('journal', TemplateGroup.personal, tr('Journal'), tr('Three good things, what is on your mind, what you learned'), Icons.edit_note_outlined, journalText, background: PageBackground.lines),
      // Creative
      BuiltInTemplate('storyboard', tr('Storyboard'), tr('Six frames to draw in, each with a line for the action'), Icons.movie_creation_outlined, (n, d) {
        n.background = PageBackground.blank;
        n.textBoxes = _storyboard(6);
      }, group: TemplateGroup.creative),
      BuiltInTemplate('comic', tr('Comic page'), tr('Panels of different sizes with gutters between them'), Icons.dashboard_outlined, (n, d) {
        n.background = PageBackground.blank;
        n.textBoxes = _comicPage();
      }, group: TemplateGroup.creative),
      _text('character', TemplateGroup.creative, tr('Character sheet'), tr('Looks, wants, needs and fears, relationships and how they speak'), Icons.face_outlined, (d) => characterText()),
      _text('beats', TemplateGroup.creative, tr('Story outline'), tr('The three acts of a story, beat by beat, and the scenes left to write'), Icons.auto_stories_outlined, (d) => storyText(), background: PageBackground.lines),
      _text('song', TemplateGroup.creative, tr('Song sheet'), tr('Key, tempo and chords, with verses and a chorus to fill in'), Icons.lyrics_outlined, (d) => songText(), background: PageBackground.lines),
    ];

/// New notes from templates (the ones that come with the app and the ones the person saved), and saving a note as a template.
class TemplateService {
  final NoteRepository repository;
  final NoteFileService files;
  final DateTime Function() now;

  TemplateService(this.repository, this.files, {DateTime Function()? now}) : now = now ?? DateTime.now;

  List<BuiltInTemplate> get builtIn => builtInTemplates();

  Future<List<SavedTemplate>> saved() => repository.templates.list();

  /// A new note from a template of the app, in [folderId]. Returns its id.
  Future<String> createFrom(BuiltInTemplate t, {String? folderId}) async {
    final id = await repository.createNote(title: t.name, folderId: folderId);
    final note = (await repository.loadNote(id))!;
    t.fill(note, now());
    await repository.saveNote(note);
    return id;
  }

  /// A new note from a template the person saved. Returns its id, or null if the template is gone or cannot be read.
  Future<String?> createFromSaved(String templateId, {String? folderId}) async {
    final bytes = await repository.templates.bytes(templateId);
    if (bytes == null) return null;
    final result = await files.importBytes(bytes, folderId: folderId);
    return result.noteId;
  }

  /// Keeps the note [noteId] as a template called [name] (the strokes, text, pictures and the look of its pages).
  Future<bool> saveAsTemplate(String noteId, String name) async {
    final Uint8List? bytes = await files.exportBytes(noteId);
    if (bytes == null) return false;
    await repository.templates.save(name, bytes);
    return true;
  }

  Future<void> remove(String templateId) => repository.templates.delete(templateId);
}
