import 'dart:async';

/// One stream that fires once for a burst of events on any of [sources], [wait] after the last: for a screen that shows a list (notes,
/// folders, tasks) and loads it again when the library changes under it, whoever changed it (an agent over MCP, a sync, the editor's
/// autosave). Changes come in bursts (a note is made and then filled; a save follows a save), and one load is enough for them.
/// Listen once; nothing is listened to on the sources until then.
Stream<void> debouncedChanges(Iterable<Stream<Object?>?> sources, {Duration wait = const Duration(milliseconds: 400)}) {
  final list = [for (final s in sources) ?s];
  final subscriptions = <StreamSubscription<Object?>>[];
  Timer? timer;
  late final StreamController<void> controller;
  controller = StreamController<void>(
    onListen: () {
      for (final s in list) {
        subscriptions.add(s.listen((_) {
          timer?.cancel();
          timer = Timer(wait, () {
            if (!controller.isClosed) controller.add(null);
          });
        }));
      }
    },
    onCancel: () async {
      timer?.cancel();
      for (final s in subscriptions) {
        await s.cancel();
      }
      subscriptions.clear();
    },
  );
  return controller.stream;
}
