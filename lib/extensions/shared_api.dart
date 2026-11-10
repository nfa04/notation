import 'package:flutter/services.dart';

import 'extension_host.dart';
import 'extension_service.dart';

/// What every place gives an extension alike: tasks (through the service) and the clipboard. A place adds what is its own (the
/// note, the selection).
abstract class SharedExtensionApi extends ExtensionApi {
  final ExtensionService service;

  SharedExtensionApi(this.service);

  @override
  Future<void> addTask(String title, {String? due}) async {
    final add = service.addTask;
    if (add == null) throw ExtensionError('Tasks cannot be added here.');
    await add(title, due == null ? null : DateTime.parse(due));
  }

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));
}
