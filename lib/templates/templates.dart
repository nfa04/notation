import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart' show Icons, IconData;

import '../data/note_data.dart';
import '../data/note_file_service.dart';
import '../data/note_repository.dart';
import '../l10n/language.dart';
import '../models/canvas_models.dart';
import '../models/page_background.dart';
import '../models/page_format.dart';

/// A page to start a note from that comes with the app.
class BuiltInTemplate {
  final String id;
  final String name;
  final String about;
  final IconData icon;

  /// Fills a new note (its title is set by the service).
  final void Function(NoteData note, DateTime today) fill;

  const BuiltInTemplate(this.id, this.name, this.about, this.icon, this.fill);
}

String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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

/// The pages that come with the app. Words are looked up when a note is made, so they follow the language then in use.
List<BuiltInTemplate> builtInTemplates() => [
      BuiltInTemplate('canvas', tr('Infinite canvas'), tr('One surface without edges: move and zoom it, no pages (and no PDF export)'), Icons.all_inclusive, (n, d) {
        n.pageFormat = PageFormat.infinite;
        n.background = PageBackground.blank;
      }),
      BuiltInTemplate('lines', tr('Lined paper'), tr('Ruled lines, nothing else'), Icons.format_align_justify, (n, d) {
        n.background = PageBackground.lines;
      }),
      BuiltInTemplate('grid', tr('Graph paper'), tr('A grid for sketches, tables and maths'), Icons.grid_on, (n, d) {
        n.background = PageBackground.grid;
      }),
      BuiltInTemplate('lecture', tr('Lecture notes'), tr('Topic, key ideas, questions and a summary'), Icons.school_outlined, (n, d) {
        n.background = PageBackground.lines;
        n.documentText = '${tr('# Lecture')}\n\n${tr('**Course:**')} \n${tr('**Date:**')} ${_day(d)}\n\n${tr('## Key ideas')}\n\n- \n\n'
            '${tr('## Questions')}\n\n- \n\n${tr('## Summary')}\n\n';
      }),
      BuiltInTemplate('cornell', tr('Cornell notes'), tr('Cues on the left, notes on the right, a summary at the bottom'), Icons.view_sidebar_outlined, (n, d) {
        n.background = PageBackground.blank;
        n.textBoxes = {
          0: [
            _box('cues', 30, 40, 200, 700, '${tr('**Cues**')}\n'),
            _box('notes', 250, 40, 520, 700, '${tr('**Notes**')}  ·  ${_day(d)}\n'),
            _box('summary', 30, 760, 740, 180, '${tr('**Summary**')}\n'),
          ],
        };
      }),
      BuiltInTemplate('meeting', tr('Meeting notes'), tr('Who was there, what was decided, who does what'), Icons.groups_outlined, (n, d) {
        n.background = PageBackground.blank;
        n.documentText = '${tr('# Meeting')}\n\n${tr('**Date:**')} ${_day(d)}\n${tr('**Present:**')} \n\n${tr('## Agenda')}\n\n1. \n\n'
            '${tr('## Decisions')}\n\n- \n\n${tr('## Action items')}\n\n- [ ] \n';
      }),
      BuiltInTemplate('daily', tr('Daily plan'), tr('The day by the hour, with a list of things to do'), Icons.today_outlined, (n, d) {
        n.background = PageBackground.lines;
        n.documentText = '${tr('# Plan for')} ${_day(d)}\n\n${tr('## Priorities')}\n\n- [ ] \n- [ ] \n- [ ] \n\n${tr('## Schedule')}\n\n'
            '${[for (var h = 8; h <= 18; h += 2) '- ${h.toString().padLeft(2, '0')}:00  '].join('\n')}\n\n${tr('## Notes')}\n';
      }),
      BuiltInTemplate('todo', tr('To-do list'), tr('A list of tasks to tick off'), Icons.checklist, (n, d) {
        n.background = PageBackground.blank;
        n.documentText = '${tr('# To do')}\n\n${[for (var i = 0; i < 8; i++) '- [ ] '].join('\n')}\n';
      }),
      BuiltInTemplate('music', tr('Music paper'), tr('Staves for writing notes by hand'), Icons.music_note_outlined, (n, d) {
        n.background = PageBackground.staff;
      }),
      BuiltInTemplate('tab', tr('Guitar tab'), tr('Six-line tablature staves'), Icons.queue_music_outlined, (n, d) {
        n.background = PageBackground.tab;
      }),
      BuiltInTemplate('dots', tr('Dot grid'), tr('Dots to guide lettering, sketches and journals'), Icons.apps, (n, d) {
        n.background = PageBackground.dots;
      }),
      BuiltInTemplate('isometric', tr('Isometric paper'), tr('A triangular grid for isometric drawings and 3D sketches'), Icons.view_in_ar_outlined, (n, d) {
        n.background = PageBackground.isometric;
      }),
      BuiltInTemplate('storyboard', tr('Storyboard'), tr('Six frames to draw in, each with a line for the action'), Icons.movie_creation_outlined, (n, d) {
        n.background = PageBackground.blank;
        n.textBoxes = _storyboard(6);
      }),
      BuiltInTemplate('comic', tr('Comic page'), tr('Panels of different sizes with gutters between them'), Icons.dashboard_outlined, (n, d) {
        n.background = PageBackground.blank;
        n.textBoxes = _comicPage();
      }),
      BuiltInTemplate('character', tr('Character sheet'), tr('Who a character is: looks, wants, fears and history'), Icons.face_outlined, (n, d) {
        n.background = PageBackground.blank;
        n.documentText = '${tr('# Character')}\n\n${tr('**Name:**')} \n${tr('**Age:**')} \n${tr('**Role in the story:**')} \n\n${tr('## Looks')}\n\n\n'
            '${tr('## Personality')}\n\n- \n\n${tr('## Wants and fears')}\n\n${tr('**Wants:**')} \n${tr('**Needs:**')} \n${tr('**Fears:**')} \n\n'
            '${tr('## Relationships')}\n\n- \n\n${tr('## History')}\n\n${tr('## How they speak')}\n';
      }),
      BuiltInTemplate('beats', tr('Story outline'), tr('The three acts of a story, beat by beat'), Icons.auto_stories_outlined, (n, d) {
        n.background = PageBackground.lines;
        n.documentText = '${tr('# Story')}\n\n${tr('**Working title:**')} \n${tr('**One sentence:**')} \n\n${tr('## Act one: setup')}\n\n${tr('- The ordinary world')}\n'
            '${tr('- The call: what changes')}\n${tr('- The point of no return')}\n\n${tr('## Act two: confrontation')}\n\n${tr('- Trying and failing')}\n'
            '${tr('- The middle: everything shifts')}\n${tr('- The lowest point')}\n\n${tr('## Act three: resolution')}\n\n${tr('- The final push')}\n${tr('- The climax')}\n'
            '${tr('- The new normal')}\n';
      }),
      BuiltInTemplate('song', tr('Song sheet'), tr('Title, key and tempo, with verses and a chorus to fill in'), Icons.lyrics_outlined, (n, d) {
        n.background = PageBackground.lines;
        n.documentText = '${tr('# Song')}\n\n${tr('**Key:**')} \n${tr('**Tempo:**')} \n${tr('**Time:**')} 4/4\n\n${tr('## Verse 1')}\n\n\n${tr('## Chorus')}\n\n\n'
            '${tr('## Verse 2')}\n\n\n${tr('## Bridge')}\n\n\n${tr('## Ideas')}\n\n- \n';
      }),
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
