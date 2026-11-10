import 'dart:async';

/// The web has no isolates: [f] runs where it is called, after the screen has had a turn.
Future<T> runApart<T>(FutureOr<T> Function() f) => Future<T>.delayed(Duration.zero, f);
