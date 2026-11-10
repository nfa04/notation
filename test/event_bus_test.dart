import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes/events/event_bus.dart';

void main() {
  test('emit waits for each handler, in order, and a failing one does not stop the rest', () async {
    final bus = EventBus();
    final log = <String>[];
    bus.listen((e) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      log.add('slow ${e.type}');
    });
    bus.listen((e) => throw StateError('boom'));
    bus.listen((e) => log.add('last ${e.noteId}'));
    await bus.emit(const AppEvent('noteOpened', noteId: 'n1'));
    expect(log, ['slow noteOpened', 'last n1']);
  });

  test('a handler that fails is told in the log, with the event it failed on', () async {
    final logged = <String>[];
    final was = debugPrint;
    debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
    addTearDown(() => debugPrint = was);
    final bus = EventBus();
    bus.listen((e) => throw StateError('boom'));
    await bus.emit(const AppEvent('noteOpened'));
    expect(logged, hasLength(1));
    expect(logged.single, contains('noteOpened'));
    expect(logged.single, contains('boom'));
  });

  test('a stopped listener hears nothing more, and types can be looked up', () async {
    final bus = EventBus();
    var heard = 0;
    final stop = bus.listen((_) => heard++);
    await bus.emit(const AppEvent('a'));
    stop();
    await bus.emit(const AppEvent('a'));
    expect(heard, 1);
    bus.register(const EventType('a', 'A', hasNote: true));
    expect(bus.type('a')!.hasNote, isTrue);
    expect(bus.types, hasLength(1));
  });
}
