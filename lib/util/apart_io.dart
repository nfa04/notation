import 'dart:async';
import 'dart:isolate';

/// Runs [f] on another isolate: work that takes long enough to be felt (decoding a photograph, hashing a big file, zipping a note).
Future<T> runApart<T>(FutureOr<T> Function() f) => Isolate.run(f);
