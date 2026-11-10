import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';

/// What happens when the window of the app is closed: the window goes first, the last work is done after it.
///
/// The note on screen is saved first (a moment, and local). Then, if there are shared copies whose markers have to say "not
/// here" and the window can be hidden (Linux), the window is hidden and the answer is "do not exit yet": the copies are put up
/// in the background and the process is ended when that is done (or after [background] seconds). Where the window cannot be hidden
/// the app waits for the copies, but only [foreground] seconds. Each part has its limit (no network, a slow disk), so that closing
/// never hangs; and if the process is still there [lastResort] after the app said it may go, it is ended.
class WindowCloser {
  /// Saves the note on screen.
  final Future<void> Function() saveNote;

  /// Whether there is anything to put up (shared copies with markers).
  final bool Function() hasCopies;

  /// Puts the shared copies up (their markers say "not here").
  final Future<void> Function() putUpCopies;

  /// Hides the window; false where that cannot be done.
  final Future<bool> Function() hideWindow;

  /// Ends the process.
  final void Function(int code) endProcess;

  /// Whether the process may be ended from here as a last resort (a desktop).
  final bool desktop;

  final Duration saveLimit, foreground, background, lastResort;

  WindowCloser({
    required this.saveNote,
    required this.hasCopies,
    required this.putUpCopies,
    required this.hideWindow,
    required this.endProcess,
    this.desktop = true,
    this.saveLimit = const Duration(seconds: 3),
    this.foreground = const Duration(seconds: 3),
    this.background = const Duration(seconds: 10),
    this.lastResort = const Duration(seconds: 3),
  });

  Future<AppExitResponse>? _closing;

  /// The answer to the request to close: the same one for a second click on the button.
  Future<AppExitResponse> closeDown() => _closing ??= _run();

  Future<void> _part(String what, Future<void> Function() job, Duration limit) async {
    try {
      await job().timeout(limit);
    } catch (e) {
      debugPrint('[exit] $what did not finish in time: $e');
    }
  }

  Future<AppExitResponse> _run() async {
    final watch = Stopwatch()..start();
    await _part('saving the note', saveNote, saveLimit);

    if (hasCopies() && await hideWindow()) {
      debugPrint('[exit] window closed after ${watch.elapsedMilliseconds} ms; the shared copies go up now');
      // the process is kept until that is done (the engine would end it with the answer "exit")
      final backstop = Timer(background + lastResort, () => endProcess(0));
      unawaited(() async {
        await _part('putting up the shared copies', putUpCopies, background);
        debugPrint('[exit] done after ${watch.elapsedMilliseconds} ms');
        backstop.cancel();
        endProcess(0);
      }());
      return AppExitResponse.cancel;
    }

    if (hasCopies()) await _part('putting up the shared copies', putUpCopies, foreground);
    debugPrint('[exit] closing after ${watch.elapsedMilliseconds} ms');
    if (desktop) {
      Timer(lastResort, () {
        debugPrint('[exit] the process is still there: ending it');
        endProcess(0);
      });
    }
    return AppExitResponse.exit;
  }
}
