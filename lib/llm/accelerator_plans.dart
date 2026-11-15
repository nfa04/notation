import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb, visibleForTesting;

/// Which input sizes of a model the accelerator has a plan for on disk. MIGraphX names its plan files by a hash of the input shapes, so
/// they cannot be told apart by looking at them: the app keeps its own list, in a file among the plans (the folder the plugin gives
/// MIGraphX), so that deleting the plans deletes the list too. A model is known by its file's name, length and time (a new download is a
/// new model, whose plans are made again).
class AcceleratorPlans {
  /// The folder of the plans (as the plugin works it out on Linux), or null where there is none. Tests set [folderForTests].
  static Directory? get folder {
    if (folderForTests != null) return folderForTests;
    if (kIsWeb || !Platform.isLinux) return null;
    final xdg = Platform.environment['XDG_CACHE_HOME'], home = Platform.environment['HOME'];
    final base = xdg != null && xdg.isNotEmpty ? xdg : (home == null ? null : '$home/.cache');
    return base == null ? null : Directory('$base/flutter_onnxruntime/migraphx');
  }

  @visibleForTesting
  static Directory? folderForTests;

  static Future<void> _turn = Future.value();

  static File? get _file {
    final f = folder;
    return f == null ? null : File('${f.path}/notation-plans.json');
  }

  static Future<String?> _modelOf(String modelPath) async {
    final f = File(modelPath);
    if (!await f.exists()) return null;
    final stat = await f.stat();
    return '${f.uri.pathSegments.last}:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
  }

  static Future<Map<String, dynamic>> _all() async {
    final file = _file;
    if (file == null || !await file.exists()) return {};
    try {
      return (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      return {}; // (a broken list is started again: the sizes are found again as they are planned)
    }
  }

  /// The sizes of the model at [modelPath] whose plan is on disk, as far as the app knows.
  static Future<Set<String>> sizes(String modelPath) async {
    final model = await _modelOf(modelPath);
    if (model == null) return {};
    return {...((await _all())[model] as List? ?? const []).cast<String>()};
  }

  /// Notes that the plan of [size] is on disk.
  static Future<void> add(String modelPath, String size) {
    final done = _turn.then((_) async {
      final file = _file, model = await _modelOf(modelPath);
      if (file == null || model == null) return;
      try {
        final all = await _all();
        // (lists of models that are no longer there, e.g. an older download of the same file, are dropped)
        final name = model.substring(0, model.indexOf(':') + 1);
        all.removeWhere((k, _) => k.startsWith(name) && k != model);
        final list = {...(all[model] as List? ?? const []).cast<String>(), size}.toList()..sort();
        if (list.length == (all[model] as List?)?.length) return;
        all[model] = list;
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(all));
      } catch (e) {
        debugPrint('onnx: could not note the plan of size "$size" ($e)');
      }
    });
    _turn = done;
    return done;
  }
}
