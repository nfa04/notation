import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, Colors;
import 'package:flutter/services.dart';

import 'key_combo.dart';

/// The parts of the list of shortcuts, in the order they are shown in.
enum ShortcutGroup {
  navigation('Go to'),
  note('Note'),
  edit('Edit and search'),
  tools('Drawing tools'),
  colors('Pen colors and size'),
  insert('Insert'),
  view('View and pages');

  final String label;
  const ShortcutGroup(this.label);
}

/// Something a shortcut can do: the app (or the open note) has to be told its [id] and does it.
@immutable
class ShortcutAction {
  final String id;

  /// What the list shows (in English; it goes through `tr`).
  final String label;
  final ShortcutGroup group;

  /// The combinations that do it until the person changes them (none: it has no shortcut to begin with).
  final List<KeyCombo> defaults;

  const ShortcutAction(this.id, this.label, this.group, [this.defaults = const []]);
}

/// The places of the menu on the left, by the name of their action (the index the shell goes by).
const navigationActions = <String, int>{
  'go.dashboard': 0,
  'go.folders': 1,
  'go.calendar': 2,
  'go.note': 3,
  'go.automations': 4,
  'go.graph': 8,
  'go.assistant': 9,
  'go.search': 6,
  'go.settings': 5,
};

/// Every action with its default shortcuts. Where a program would use Ctrl, a Mac uses Cmd: [mac] says which this is.
List<ShortcutAction> shortcutActions({required bool mac}) {
  KeyCombo cmd(LogicalKeyboardKey key, {bool shift = false, bool alt = false}) => KeyCombo(key, ctrl: !mac, meta: mac, shift: shift, alt: alt);
  KeyCombo plain(LogicalKeyboardKey key, {bool shift = false, bool alt = false}) => KeyCombo(key, shift: shift, alt: alt);
  const nav = ShortcutGroup.navigation, note = ShortcutGroup.note, edit = ShortcutGroup.edit, tools = ShortcutGroup.tools;
  const colors = ShortcutGroup.colors, insert = ShortcutGroup.insert, view = ShortcutGroup.view;
  return [
    ShortcutAction('go.dashboard', 'Dashboard', nav, [cmd(LogicalKeyboardKey.digit1)]),
    ShortcutAction('go.folders', 'Folders', nav, [cmd(LogicalKeyboardKey.digit2)]),
    ShortcutAction('go.calendar', 'Calendar', nav, [cmd(LogicalKeyboardKey.digit3)]),
    ShortcutAction('go.note', 'Active canvas (the open note)', nav, [cmd(LogicalKeyboardKey.digit4)]),
    ShortcutAction('go.automations', 'Automations', nav, [cmd(LogicalKeyboardKey.digit5)]),
    ShortcutAction('go.graph', 'Graph', nav, [cmd(LogicalKeyboardKey.digit6)]),
    ShortcutAction('go.assistant', 'Assistant', nav, [cmd(LogicalKeyboardKey.digit7)]),
    ShortcutAction('go.search', 'Search all notes', nav, [cmd(LogicalKeyboardKey.keyF, shift: true)]),
    ShortcutAction('go.settings', 'Settings', nav, [cmd(LogicalKeyboardKey.comma)]),
    ShortcutAction('app.sidebar', 'Show or hide the left bar', nav, [cmd(LogicalKeyboardKey.keyL, shift: true)]),

    ShortcutAction('note.save', 'Save the note now', note, [cmd(LogicalKeyboardKey.keyS)]),
    ShortcutAction('note.favorite', 'Add to or remove from favourites', note, [cmd(LogicalKeyboardKey.keyD)]),
    ShortcutAction('note.present', 'Present the note', note, [plain(LogicalKeyboardKey.f5)]),
    ShortcutAction('note.history', 'History of the note', note, [cmd(LogicalKeyboardKey.keyH)]),
    ShortcutAction('note.assistant', 'Ask about this document', note, [cmd(LogicalKeyboardKey.keyJ)]),
    ShortcutAction('note.outline', 'Bookmarks and outline', note, [cmd(LogicalKeyboardKey.keyO, shift: true)]),
    ShortcutAction('note.bookmark', 'Bookmark the page on screen', note, [cmd(LogicalKeyboardKey.keyB, shift: true)]),
    ShortcutAction('note.importPdf', 'Import a PDF', note, [cmd(LogicalKeyboardKey.keyO)]),
    ShortcutAction('note.exportPdf', 'Export the note as a PDF', note, [cmd(LogicalKeyboardKey.keyE, shift: true)]),
    ShortcutAction('note.dictate', 'Dictate: write down what is said', note, [cmd(LogicalKeyboardKey.keyM, shift: true)]),
    ShortcutAction('note.readAloud', 'Read the note aloud or stop reading', note, [cmd(LogicalKeyboardKey.keyR, shift: true)]),
    ShortcutAction('note.translate', 'Translate the note', note),
    ShortcutAction('note.remind', 'Remind me about this note', note),
    ShortcutAction('note.beside', 'Open another note beside this one', note),
    ShortcutAction('automation.trigger1', 'Run the automations of trigger 1 ("You press a trigger")', note),
    ShortcutAction('automation.trigger2', 'Run the automations of trigger 2', note),
    ShortcutAction('automation.trigger3', 'Run the automations of trigger 3', note),

    ShortcutAction('edit.undo', 'Undo', edit, [cmd(LogicalKeyboardKey.keyZ)]),
    ShortcutAction('edit.redo', 'Redo', edit, [cmd(LogicalKeyboardKey.keyY), cmd(LogicalKeyboardKey.keyZ, shift: true)]),
    ShortcutAction('edit.paste', 'Paste a picture or text onto the page', edit, [cmd(LogicalKeyboardKey.keyV)]),
    ShortcutAction('edit.delete', 'Delete the selected drawing, text box or picture', edit, [plain(LogicalKeyboardKey.delete), plain(LogicalKeyboardKey.backspace)]),
    ShortcutAction('edit.clearPage', 'Clear the drawings and highlights on the page', edit),
    ShortcutAction('find.open', 'Find in the note', edit, [cmd(LogicalKeyboardKey.keyF)]),
    ShortcutAction('find.replace', 'Find and replace in the note', edit, [cmd(LogicalKeyboardKey.keyF, alt: true)]),
    ShortcutAction('find.next', 'Next match', edit, [plain(LogicalKeyboardKey.f3), cmd(LogicalKeyboardKey.keyG)]),
    ShortcutAction('find.previous', 'Previous match', edit, [plain(LogicalKeyboardKey.f3, shift: true), cmd(LogicalKeyboardKey.keyG, shift: true)]),

    ShortcutAction('mode.select', 'Select mode', tools, [plain(LogicalKeyboardKey.digit1, alt: true)]),
    ShortcutAction('mode.draw', 'Draw mode', tools, [plain(LogicalKeyboardKey.digit2, alt: true)]),
    ShortcutAction('mode.document', 'Document mode', tools, [plain(LogicalKeyboardKey.digit3, alt: true)]),
    ShortcutAction('tool.pen', 'Pen', tools, [plain(LogicalKeyboardKey.keyP)]),
    ShortcutAction('tool.highlighter', 'Highlighter', tools, [plain(LogicalKeyboardKey.keyH)]),
    ShortcutAction('tool.eraser', 'Eraser', tools, [plain(LogicalKeyboardKey.keyE)]),
    ShortcutAction('tool.lasso', 'Lasso', tools, [plain(LogicalKeyboardKey.keyL)]),
    ShortcutAction('shape.freehand', 'Shape: freehand', tools),
    ShortcutAction('shape.line', 'Shape: line', tools),
    ShortcutAction('shape.arrow', 'Shape: arrow', tools, [plain(LogicalKeyboardKey.keyA)]),
    ShortcutAction('shape.connector', 'Shape: connector', tools),
    ShortcutAction('shape.rectangle', 'Shape: rectangle', tools, [plain(LogicalKeyboardKey.keyR)]),
    ShortcutAction('shape.ellipse', 'Shape: ellipse', tools, [plain(LogicalKeyboardKey.keyO)]),
    ShortcutAction('shape.triangle', 'Shape: triangle', tools),
    ShortcutAction('shape.diamond', 'Shape: diamond', tools),
    ShortcutAction('shape.roundedRectangle', 'Shape: rounded rectangle', tools),
    ShortcutAction('shape.rightTriangle', 'Shape: right triangle', tools),
    ShortcutAction('shape.parallelogram', 'Shape: parallelogram', tools),
    ShortcutAction('shape.pentagon', 'Shape: pentagon', tools),
    ShortcutAction('shape.hexagon', 'Shape: hexagon', tools),
    ShortcutAction('shape.star', 'Shape: star', tools),
    ShortcutAction('shape.heart', 'Shape: heart', tools),
    ShortcutAction('shape.cross', 'Shape: cross', tools),
    ShortcutAction('shape.doubleArrow', 'Shape: double arrow', tools),
    ShortcutAction('shape.speechBubble', 'Shape: speech bubble', tools),
    ShortcutAction('shape.bezier', 'Shape: pen for curves', tools, [plain(LogicalKeyboardKey.keyB)]),
    ShortcutAction('tool.straighten', 'Straighten lines and shapes on or off', tools),
    ShortcutAction('tool.plot', 'Add an empty plot', tools),

    for (var i = 0; i < drawColors.length; i++)
      ShortcutAction('color.${i + 1}', 'Pen color ${i + 1}', colors, [plain([LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6][i])]),
    ShortcutAction('color.custom', 'Add a pen color', colors),
    ShortcutAction('size.thinner', 'Thinner line', colors, [plain(LogicalKeyboardKey.comma), plain(LogicalKeyboardKey.bracketLeft)]),
    ShortcutAction('size.thicker', 'Thicker line', colors, [plain(LogicalKeyboardKey.period), plain(LogicalKeyboardKey.bracketRight)]),

    ShortcutAction('insert.textBox', 'Add a text box', insert, [cmd(LogicalKeyboardKey.keyT, shift: true)]),
    ShortcutAction('insert.table', 'Add a table', insert, [cmd(LogicalKeyboardKey.keyT, alt: true)]),
    ShortcutAction('insert.diagram', 'Make a mind map or a flowchart', insert, [cmd(LogicalKeyboardKey.keyD, alt: true)]),
    ShortcutAction('insert.image', 'Add a picture', insert, [cmd(LogicalKeyboardKey.keyI, shift: true)]),

    ShortcutAction('toolbar.nextProfile', 'Next toolbar profile', view, [cmd(LogicalKeyboardKey.keyP, alt: true)]),
    ShortcutAction('toolbar.previousProfile', 'Previous toolbar profile', view, [cmd(LogicalKeyboardKey.keyP, shift: true, alt: true)]),
    ShortcutAction('zoom.in', 'Zoom in', view, [cmd(LogicalKeyboardKey.equal), cmd(LogicalKeyboardKey.add, shift: true), cmd(LogicalKeyboardKey.numpadAdd)]),
    ShortcutAction('zoom.out', 'Zoom out', view, [cmd(LogicalKeyboardKey.minus), cmd(LogicalKeyboardKey.numpadSubtract)]),
    ShortcutAction('zoom.reset', 'Zoom back to 100%', view, [cmd(LogicalKeyboardKey.digit0)]),
    ShortcutAction('zoom.fit', 'Show everything on the canvas', view, [cmd(LogicalKeyboardKey.digit9)]),
    ShortcutAction('page.next', 'Next page', view, [cmd(LogicalKeyboardKey.pageDown)]),
    ShortcutAction('page.previous', 'Previous page', view, [cmd(LogicalKeyboardKey.pageUp)]),
    ShortcutAction('page.first', 'First page', view, [cmd(LogicalKeyboardKey.home)]),
    ShortcutAction('page.last', 'Last page', view, [cmd(LogicalKeyboardKey.end)]),
  ];
}

/// The colors of the pen in the drawing bar, in order (the keys 1 to 6 choose them).
final drawColors = <Color>[Colors.black, Colors.blueAccent, Colors.redAccent, Colors.green, Colors.purple, Colors.orange];
