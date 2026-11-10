import 'dart:async';
import 'dart:isolate';

import 'script_engine.dart';

/// Runs a script in an engine of its own on another isolate, so that what it computes never holds up the screen. The script's
/// calls into the app ([host]) travel back to this isolate, where they are checked and done; only text goes either way.
///
/// Gives what [call] evaluates to (text), or throws what went wrong. [overall] is the longest the whole run may take; if the
/// worker does not answer in time the isolate is ended.
Future<String> runInIsolate({
  required String prelude,
  required String script,
  required String scriptName,
  required String call,
  required Future<String> Function(String name, String? payload) host,
  required void Function(String line) onConsole,
  required Duration overall,
}) async {
  final inbox = ReceivePort();
  final result = Completer<String>();
  SendPort? worker;
  final isolate = await Isolate.spawn<_Job>(
    _work,
    _Job(inbox.sendPort, prelude, script, scriptName, call, overall),
    errorsAreFatal: true,
    onError: inbox.sendPort,
    onExit: inbox.sendPort,
  );
  final sub = inbox.listen((message) {
    if (message is SendPort) {
      worker = message;
    } else if (message is List) {
      switch (message[0]) {
        case 'log':
          onConsole(message[1] as String);
        case 'host':
          final id = message[1] as int;
          host(message[2] as String, message[3] as String?).then(
            (reply) => worker?.send(<Object?>[id, reply]),
            onError: (Object e) => worker?.send(<Object?>[id, '{"error":"Something went wrong: $e"}']),
          );
        case 'done':
          if (!result.isCompleted) result.complete(message[1] as String);
        case 'fail':
          if (!result.isCompleted) result.completeError(Exception(message[1] as String));
        default:
          // an error report from the isolate: [message, stack]
          if (!result.isCompleted) result.completeError(Exception('${message[0]}'));
      }
    } else if (message == null && !result.isCompleted) {
      result.completeError(Exception('The script stopped.'));
    }
  });
  try {
    return await result.future.timeout(overall + const Duration(seconds: 2), onTimeout: () => throw Exception('The script ran for too long.'));
  } finally {
    await sub.cancel();
    inbox.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

class _Job {
  final SendPort out;
  final String prelude, script, scriptName, call;
  final Duration overall;
  const _Job(this.out, this.prelude, this.script, this.scriptName, this.call, this.overall);
}

Future<void> _work(_Job job) async {
  final replies = ReceivePort();
  final waiting = <int, Completer<String>>{};
  var next = 0;
  replies.listen((m) {
    final list = m as List;
    waiting.remove(list[0] as int)?.complete(list[1] as String);
  });
  job.out.send(replies.sendPort);
  ScriptEngine? engine;
  try {
    engine = QuickJsEngine.make(onConsole: (line) => job.out.send(<Object?>['log', line]));
    engine.register('__host', (args) {
      final id = next++;
      final c = Completer<String>();
      waiting[id] = c;
      job.out.send(<Object?>['host', id, args[0] as String, args[1] as String?]);
      return c.future;
    });
    engine.eval(job.prelude, filename: 'notation');
    engine.eval(job.script, filename: job.scriptName);
    final raw = await engine.evalAsync(job.call, filename: 'run', timeout: job.overall);
    job.out.send(<Object?>['done', '$raw']);
  } catch (e) {
    job.out.send(<Object?>['fail', '$e']);
  } finally {
    engine?.dispose();
    replies.close();
  }
}
