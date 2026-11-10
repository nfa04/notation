import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../block_editor/block_editor.dart';
import '../data/settings_repository.dart';
import 'key_combo.dart';
import 'shortcut_action.dart';

/// Does the action [id] if it can; false when it is not for this handler (or cannot be done now), so that the next one is asked.
typedef ShortcutHandler = bool Function(String id);

/// Whether a text is being typed into: plain keys then belong to the text.
bool shortcutTextFocused() {
  final focused = FocusManager.instance.primaryFocus?.context;
  return focused?.findAncestorWidgetOfExactType<EditableText>() != null || focused?.findAncestorWidgetOfExactType<BlockEditor>() != null;
}

/// The keyboard shortcuts: which key combinations do which action (what the person set, or the defaults), and the one place that
/// watches the keyboard and hands a pressed combination to whoever can do its action (the open note, then the frame of the app).
class ShortcutService extends ChangeNotifier {
  static const _key = 'keyboard_shortcuts';

  /// The service of screens that were not given one (tests and previews): the defaults, remembering nothing.
  static final ShortcutService fallback = ShortcutService.inMemory();

  final SettingsRepository? _settings;
  final List<ShortcutAction> actions;
  late final Map<String, ShortcutAction> _byId = {for (final a in actions) a.id: a};

  ShortcutService(SettingsRepository this._settings, {bool? mac}) : actions = shortcutActions(mac: mac ?? defaultTargetPlatform == TargetPlatform.macOS) {
    _reindex();
  }

  /// Remembers nothing: for tests and previews.
  ShortcutService.inMemory({bool? mac}) : _settings = null, actions = shortcutActions(mac: mac ?? defaultTargetPlatform == TargetPlatform.macOS) {
    _reindex();
  }

  /// What differs from the defaults: the combinations of the actions that were changed (none at all: the action was unbound).
  final Map<String, List<KeyCombo>> _custom = {};
  Map<KeyCombo, List<String>> _index = {};

  ShortcutAction? action(String id) => _byId[id];

  /// The combinations that do [id] now.
  List<KeyCombo> bindingsOf(String id) => _custom[id] ?? _byId[id]?.defaults ?? const [];

  /// Whether the shortcuts of [id] differ from how they came.
  bool changed(String id) => _custom.containsKey(id);

  bool get anyChanged => _custom.isNotEmpty;

  /// The actions that [combo] already does (other than [except]).
  List<ShortcutAction> usedBy(KeyCombo combo, {String? except}) => [
        for (final id in _index[combo] ?? const <String>[])
          if (id != except) _byId[id]!,
      ];

  Future<void> load() async {
    final saved = await _settings?.get(_key);
    _custom.clear();
    if (saved != null) {
      try {
        for (final e in (jsonDecode(saved) as Map<String, dynamic>).entries) {
          if (!_byId.containsKey(e.key)) continue; // (an action of another version)
          final combos = [for (final c in (e.value as List)) ?KeyCombo.decode(c as String)];
          if (!listEquals(combos, _byId[e.key]!.defaults)) _custom[e.key] = combos;
        }
      } catch (_) {
        _custom.clear(); // unreadable: the defaults
      }
    }
    _reindex();
    notifyListeners();
  }

  /// Makes [combos] the shortcuts of [id] (an empty list: none).
  Future<void> setBindings(String id, List<KeyCombo> combos) {
    final action = _byId[id];
    if (action == null) return Future.value();
    final unique = combos.toSet().toList(); // (in the order given)
    if (listEquals(unique, action.defaults)) {
      _custom.remove(id);
    } else {
      _custom[id] = unique;
    }
    return _changed();
  }

  /// Gives [combo] to [id] as well as what it has; an action that already does [combo] loses it.
  Future<void> addBinding(String id, KeyCombo combo) {
    for (final other in usedBy(combo, except: id)) {
      _custom[other.id] = [for (final c in bindingsOf(other.id)) if (c != combo) c];
      if (listEquals(_custom[other.id], other.defaults)) _custom.remove(other.id);
    }
    return setBindings(id, [...bindingsOf(id), combo]);
  }

  /// Takes [combo] away from [id].
  Future<void> removeBinding(String id, KeyCombo combo) => setBindings(id, [for (final c in bindingsOf(id)) if (c != combo) c]);

  Future<void> reset(String id) {
    _custom.remove(id);
    return _changed();
  }

  Future<void> resetAll() {
    _custom.clear();
    return _changed();
  }

  Future<void> _changed() async {
    _reindex();
    notifyListeners();
    final s = _settings;
    if (s == null) return;
    if (_custom.isEmpty) {
      await s.remove(_key);
    } else {
      await s.set(_key, jsonEncode({for (final e in _custom.entries) e.key: [for (final c in e.value) c.encode()]}));
    }
  }

  void _reindex() {
    final index = <KeyCombo, List<String>>{};
    for (final a in actions) {
      for (final c in bindingsOf(a.id)) {
        index.putIfAbsent(c, () => []).add(a.id);
      }
    }
    _index = index;
  }

  // ---- doing what a key press asks for

  final List<ShortcutHandler> _handlers = [];
  int _paused = 0;

  /// Watches the keyboard while at least one handler is added. The one added last is asked first (the open note before the frame around it).
  void addHandler(ShortcutHandler handler) {
    // (taken off first so that it is never in twice, and is in again if the keyboard was reset behind our back)
    HardwareKeyboard.instance.removeHandler(_onKey);
    HardwareKeyboard.instance.addHandler(_onKey);
    _handlers.add(handler);
  }

  void removeHandler(ShortcutHandler handler) {
    _handlers.remove(handler);
    if (_handlers.isEmpty) HardwareKeyboard.instance.removeHandler(_onKey);
  }

  /// Nothing is done for key presses until [resume]: a shortcut is being typed in to be set.
  void pause() => _paused++;

  void resume() => _paused = _paused > 0 ? _paused - 1 : 0;

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || _paused > 0) return false;
    final combo = KeyCombo.fromEvent(event);
    final ids = combo == null ? null : _index[combo];
    if (ids == null || !combo!.worksInText && shortcutTextFocused()) return false;
    return dispatch(ids);
  }

  /// Asks the handlers, newest first, to do each of [ids] until one does.
  @visibleForTesting
  bool dispatch(List<String> ids) {
    for (final id in ids) {
      for (final handler in _handlers.reversed.toList()) {
        if (handler(id)) return true;
      }
    }
    return false;
  }
}
