import 'dart:async';

import 'package:jsf/jsf.dart';

/// What the extensions run their scripts in: an engine for JavaScript with no access to anything but what is registered
/// in it. A new one is made for each run, and lets go of everything when it is disposed.
abstract class ScriptEngine {
  /// Makes [fn] callable from the script by [name]; what it returns (or the future it returns) is what the script gets.
  void register(String name, FutureOr<Object?> Function(List<Object?> args) fn);

  /// Runs [code]. Throws if it fails or runs over its time.
  void eval(String code, {String filename = 'script'});

  /// Runs [code] and, if it gives a promise, waits for it for up to [timeout].
  Future<Object?> evalAsync(String code, {String filename = 'script', Duration? timeout});

  void dispose();
}

typedef EngineFactory = ScriptEngine Function({void Function(String line)? onConsole});

/// QuickJS (through `jsf`): ECMAScript and nothing else. There is no network, no file, no `require`, no timers beyond what
/// the engine has inside itself; the memory, the stack, the time a piece of the script may run, the timers and the calls
/// into the app are limited. What the script can do outside is only what the app registers (see `ExtensionRuntime`).
class QuickJsEngine implements ScriptEngine {
  final JsRuntime _js;

  QuickJsEngine({
    int memoryBytes = 32 * 1024 * 1024,
    Duration timeout = const Duration(milliseconds: 1500),
    void Function(String line)? onConsole,
  }) : _js = JsRuntime(
          options: JsRuntimeOptions(
            memoryLimitBytes: memoryBytes,
            maxStackSizeBytes: 512 * 1024,
            timeout: timeout,
            maxTimers: 32,
            maxCallbacks: 64,
            maxPendingFutures: 64,
            maxModuleSourceBytes: 512 * 1024,
            onConsole: onConsole == null ? null : (e) => onConsole('${e.level}: ${e.arguments.join(' ')}'),
          ),
        );

  static QuickJsEngine make({void Function(String line)? onConsole}) => QuickJsEngine(onConsole: onConsole);

  /// Whether the engine can be used here (its native library is there).
  static bool get available {
    try {
      JsRuntime().dispose();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void register(String name, FutureOr<Object?> Function(List<Object?> args) fn) => _js.registerFunction(name, (args) => fn(args));

  @override
  void eval(String code, {String filename = 'script'}) => _js.eval(code, filename: filename);

  @override
  Future<Object?> evalAsync(String code, {String filename = 'script', Duration? timeout}) => _js.evalAsync(code, filename: filename, timeout: timeout);

  @override
  void dispose() => _js.dispose();
}
