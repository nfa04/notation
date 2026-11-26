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
  final List<ShortcutAction> _builtIn;
  List<ShortcutAction> _extra = const [];

  /// Every action: the app's own, then the commands extensions bring (see [setExtraActions]).
  List<ShortcutAction> get actions => [..._builtIn, ..._extra];
  late Map<String, ShortcutAction> _byId = {for (final a in _builtIn) a.id: a};

  ShortcutService(SettingsRepository this._settings, {bool? mac}) : _builtIn = shortcutActions(mac: mac ?? defaultTargetPlatform == TargetPlatform.macOS) {
    _reindex();
  }

  /// Remembers nothing: for tests and previews.
  ShortcutService.inMemory({bool? mac}) : _settings = null, _builtIn = shortcutActions(mac: mac ?? defaultTargetPlatform == TargetPlatform.macOS) {
    _reindex();
  }

  /// What was saved, as it was read (also the keys of actions that are not here now: an extension that is off keeps its keys).
  Map<String, dynamic> _saved = {};

  /// Makes [extra] (the commands of the extensions that are on) known as actions, so they can be given keys; the keys saved for
  /// them before are given back.
  void setExtraActions(List<ShortcutAction> extra) {
    final same = extra.length == _extra.length && [for (var i = 0; i < extra.length; i++) extra[i].id == _extra[i].id && extra[i].label == _extra[i].label].every((x) => x);
    if (same) return;
    _extra = extra;
    _byId = {for (final a in actions) a.id: a};
    _applySaved();
    _reindex();
    notifyListeners();
  }

  void _applySaved() {
    _custom.removeWhere((id, _) => !_byId.containsKey(id));
    for (final e in _saved.entries) {
      final action = _byId[e.key];
      if (action == null) continue;
      try {
        final combos = [for (final c in (e.value as List)) ?KeyCombo.decode(c as String)];
        if (!listEquals(combos, action.defaults)) {
          _custom[e.key] = combos;
        } else {
          _custom.remove(e.key);
        }
      } catch (_) {}
    }
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
    _saved = {};
    if (saved != null) {
      try {
        _saved = (jsonDecode(saved) as Map<String, dynamic>);
        _applySaved();
      } catch (_) {
        _custom.clear(); // unreadable: the defaults
        _saved = {};
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
    // (what was saved for an action that is not here now stays, as long as nothing of it was changed)
    final mine = {for (final e in _custom.entries) e.key: [for (final c in e.value) c.encode()]};
    _saved = {for (final e in _saved.entries) if (!_byId.containsKey(e.key)) e.key: e.value, ...mine};
    if (s == null) return;
    if (_saved.isEmpty) {
      await s.remove(_key);
    } else {
      await s.set(_key, jsonEncode(_saved));
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
