import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// A kind of event that something in the app can announce and a rule can react to.
class EventType {
  /// `noteOpened`; an extension's would be `ext:<extension id>/<name>`.
  final String id;
  final String label;

  /// There is a note to act on.
  final bool hasNote;

  /// That note is open in the editor while the handlers run.
  final bool hasEditor;

  /// Plumbing between parts of the app, not something a rule can be made for.
  final bool internal;

  const EventType(this.id, this.label, {this.hasNote = false, this.hasEditor = false, this.internal = false});
}

/// Something that happened.
class AppEvent {
  /// The [EventType.id].
  final String type;
  final String? noteId;
  final String? folderId;
  final String title;

  /// What else there is to say about it (a found date, an extension's payload).
  final Map<String, Object?> data;

  /// The editor of [noteId], valid only until [EventBus.emit] completes. Typed loosely so that the
  /// bus does not depend on the editor; the handler that knows the type casts it.
  final Object? editor;

  const AppEvent(this.type, {this.noteId, this.folderId, this.title = '', this.data = const {}, this.editor});
}

/// Announces events to whoever listens. [emit] waits for the handlers one after the other, so a
/// handler can rely on the editor staying open until it is done (a plain stream would not wait).
class EventBus {
  final _types = <String, EventType>{};
  final _handlers = <FutureOr<void> Function(AppEvent)>[];

  void register(EventType type) => _types[type.id] = type;

  void unregister(String id) => _types.remove(id);

  EventType? type(String id) => _types[id];

  Iterable<EventType> get types => _types.values;

  /// Calls [handler] for every event from now on. Returns a function that stops it.
  void Function() listen(FutureOr<void> Function(AppEvent) handler) {
    _handlers.add(handler);
    return () => _handlers.remove(handler);
  }

  /// Completes when every handler has finished. A handler that throws does not keep the others
  /// from running.
  Future<void> emit(AppEvent event) async {
    for (final h in List.of(_handlers)) {
      try {
        await h(event);
      } catch (e, stack) {
        // (the others still run; but a rule or extension that fails leaves its trace in the log)
        debugPrint('a handler of ${event.type} failed: $e\n$stack');
      }
    }
  }
}
