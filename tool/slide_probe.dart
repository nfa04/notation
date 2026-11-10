// Logs, frame by frame, where the first page and the scroll are while the bars slide (a real window, a profile build):
//   flutter build linux --profile -t tool/slide_probe.dart
//   PROBE_DIR=$(mktemp -d) build/linux/x64/profile/bundle/notation
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/screens/fixed_page_note_editor.dart';
import 'package:notes/style/stylus_settings.dart';

Element? _find(bool Function(Element) test) {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    if (test(e)) {
      found = e;
      return;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

ScrollPosition? _scroll() {
  ScrollPosition? found;
  _find((e) {
    if (e.widget is! Scrollable) return false;
    final pos = ((e as StatefulElement).state as ScrollableState).position;
    if (pos.axis != Axis.vertical || !pos.hasContentDimensions || pos.maxScrollExtent <= 500) return false;
    found = pos;
    return true;
  });
  return found;
}

Future<void> _settle([int ms = 700]) async {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < ms) {
    await Future<void>.delayed(const Duration(milliseconds: 8));
    SchedulerBinding.instance.scheduleFrame();
  }
}

Future<bool> _tapText(String label) async {
  final e = _find((e) => e.widget is RichText && (e.widget as RichText).text.toPlainText() == label);
  final box = e?.renderObject as RenderBox?;
  if (box == null) return false;
  final at = box.localToGlobal(box.size.center(Offset.zero));
  GestureBinding.instance
    ..handlePointerEvent(PointerDownEvent(pointer: 900, position: at, buttons: kPrimaryButton))
    ..handlePointerEvent(PointerUpEvent(pointer: 900, position: at));
  return true;
}

final _clock = Stopwatch();
final _log = StringBuffer();
var _recording = false;

void _onFrame(Duration _) {
  if (!_recording) return;
  final page = _find((e) => e.widget.key == const ValueKey('page-0'))?.renderObject as RenderBox?;
  final pos = _scroll();
  final r = page == null || !page.attached ? null : page.localToGlobal(Offset.zero) & page.size;
  final shown = page == null || !page.attached ? null : MatrixUtils.transformRect(page.getTransformTo(null), Offset.zero & page.size);
  _log.writeln('${_clock.elapsedMilliseconds.toString().padLeft(5)} ms  page left ${shown?.left.toStringAsFixed(1)} top ${shown?.top.toStringAsFixed(1)} '
      'width ${shown?.width.toStringAsFixed(1)} (laid out ${r?.width.toStringAsFixed(1)})  scroll ${pos?.pixels.toStringAsFixed(1)} of ${pos?.maxScrollExtent.toStringAsFixed(0)}');
  SchedulerBinding.instance.scheduleFrame();
}

Future<void> _step(String what, String tap) async {
  _log.writeln('--- $what');
  _clock
    ..reset()
    ..start();
  _recording = true;
  await _tapText(tap);
  await _settle(450);
  _recording = false;
  await _settle(300);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = Platform.environment['PROBE_DIR'] ?? Directory.systemTemp.createTempSync('probe').path;
  AppDatabase.initFfi();
  final repo = NoteRepository(await AppDatabase.open(path: '$dir/notes.db'));
  final id = await repo.createNote(title: 'Probe');
  final r = Random(1);
  String sentence() => List.generate(8 + r.nextInt(10), (_) => ['lorem', 'ipsum', 'dolor', 'sit', 'amet', 'note', 'page', 'bar'][r.nextInt(8)]).join(' ');
  final text = [for (var i = 0; i < 120; i++) '${i % 9 == 0 ? '## ' : ''}${sentence()}. ${sentence()}. ${sentence()}.\n'].join('\n');
  await repo.saveNote((await repo.loadNote(id))!..documentText = text);
  runApp(MaterialApp(home: FixedPageNoteEditor(key: ValueKey(id), noteId: id, repository: repo, stylus: StylusSettings.inMemory())));
  SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  await _settle(1500);
  final size = WidgetsBinding.instance.platformDispatcher.views.first.physicalSize / WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  _log.writeln('window $size');
  await _step('Select -> Document (top)', 'Document');
  await _step('Document -> Draw (top)', 'Draw');
  await _step('Draw -> Document (top)', 'Document');
  _scroll()?.jumpTo(1500);
  await _settle(500);
  await _step('Document -> Draw (scrolled)', 'Draw');
  await _step('Draw -> Document', 'Document');
  await _step('Document -> Select', 'Select');
  await _step('Select -> Draw', 'Draw');
  await _step('Draw -> Select', 'Select');
  File('$dir/slide_probe.txt').writeAsStringSync(_log.toString());
  stdout.write(_log);
  exit(0);
}
