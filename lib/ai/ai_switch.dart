import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';

/// The kill switch for everything that runs a model: the AI assistant, summaries
/// and questions, smart titles, reading handwriting and formulas. Off, none of
/// it is offered or run, and nothing is sent to an AI service. On by default.
class AiSwitch extends ChangeNotifier {
  static const _key = 'ai_enabled';

  final SettingsRepository? _settings;

  AiSwitch([this._settings]);

  bool _enabled = true;
  bool get enabled => _enabled;

  Future<void> load() async {
    _enabled = await _settings?.get(_key) != '0';
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    notifyListeners();
    await _settings?.set(_key, value ? '1' : '0');
  }
}
