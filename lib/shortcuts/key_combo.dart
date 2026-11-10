import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A key with the modifiers that are held with it: what a keyboard shortcut is pressed as.
@immutable
class KeyCombo {
  /// The [LogicalKeyboardKey.keyId] of the key (letters always as the lower case one).
  final int keyId;
  final bool ctrl, alt, shift, meta;

  const KeyCombo._(this.keyId, this.ctrl, this.alt, this.shift, this.meta);

  KeyCombo(LogicalKeyboardKey key, {bool ctrl = false, bool alt = false, bool shift = false, bool meta = false}) : this._(_normalize(key.keyId), ctrl, alt, shift, meta);

  /// The combination that [event] is, with the modifiers held now; null when it is a modifier on its own.
  static KeyCombo? fromEvent(KeyEvent event) {
    if (isModifierKey(event.logicalKey)) return null;
    final keyboard = HardwareKeyboard.instance;
    return KeyCombo(event.logicalKey, ctrl: keyboard.isControlPressed, alt: keyboard.isAltPressed, shift: keyboard.isShiftPressed, meta: keyboard.isMetaPressed);
  }

  /// "ctrl+shift+97": the modifiers that are held, then the id of the key. [decode] reads it back.
  String encode() => [if (ctrl) 'ctrl', if (alt) 'alt', if (shift) 'shift', if (meta) 'meta', '$keyId'].join('+');

  static KeyCombo? decode(String text) {
    final parts = text.split('+');
    final id = int.tryParse(parts.last);
    if (id == null) return null;
    final mods = parts.sublist(0, parts.length - 1);
    if (mods.any((m) => !const {'ctrl', 'alt', 'shift', 'meta'}.contains(m))) return null;
    final key = KeyCombo._(_normalize(id), mods.contains('ctrl'), mods.contains('alt'), mods.contains('shift'), mods.contains('meta'));
    return isModifierKey(LogicalKeyboardKey(key.keyId)) ? null : key;
  }

  LogicalKeyboardKey get key => LogicalKeyboardKey(keyId);

  /// Whether the keys held now are exactly this combination.
  bool matches(KeyEvent event) => this == fromEvent(event);

  /// Held together with Ctrl, Alt or Cmd: such a combination is not typing.
  bool get hasCommand => ctrl || alt || meta;

  /// Whether the key can be pressed while a text is being typed without writing anything (the function keys, or any key with a command modifier).
  bool get worksInText => hasCommand || _functionKeys.contains(keyId);

  /// How it reads, e.g. "Ctrl+Shift+Z" (Cmd and Option on a Mac).
  String label([TargetPlatform? platform]) {
    final mac = (platform ?? defaultTargetPlatform) == TargetPlatform.macOS;
    final name = _keyName(key);
    return [
      if (ctrl) 'Ctrl',
      if (alt) mac ? 'Option' : 'Alt',
      if (shift) 'Shift',
      if (meta) mac ? 'Cmd' : (platform ?? defaultTargetPlatform) == TargetPlatform.windows ? 'Win' : 'Super',
      name,
    ].join('+');
  }

  @override
  bool operator ==(Object other) => other is KeyCombo && other.keyId == keyId && other.ctrl == ctrl && other.alt == alt && other.shift == shift && other.meta == meta;

  @override
  int get hashCode => Object.hash(keyId, ctrl, alt, shift, meta);

  @override
  String toString() => 'KeyCombo(${label()})';

  static int _normalize(int id) => id >= 0x41 && id <= 0x5a ? id + 0x20 : id;

  static String _keyName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Space';
    final label = key.keyLabel;
    if (label.isEmpty) return key.debugName ?? 'Key ${key.keyId.toRadixString(16)}';
    return label.length == 1 ? label.toUpperCase() : label;
  }

  static final _functionKeys = {
    LogicalKeyboardKey.f1.keyId, LogicalKeyboardKey.f2.keyId, LogicalKeyboardKey.f3.keyId, LogicalKeyboardKey.f4.keyId,
    LogicalKeyboardKey.f5.keyId, LogicalKeyboardKey.f6.keyId, LogicalKeyboardKey.f7.keyId, LogicalKeyboardKey.f8.keyId,
    LogicalKeyboardKey.f9.keyId, LogicalKeyboardKey.f10.keyId, LogicalKeyboardKey.f11.keyId, LogicalKeyboardKey.f12.keyId,
  };

  static final _modifiers = {
    LogicalKeyboardKey.control, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shift, LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt, LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.altGraph, LogicalKeyboardKey.capsLock, LogicalKeyboardKey.numLock, LogicalKeyboardKey.scrollLock,
    LogicalKeyboardKey.fn, LogicalKeyboardKey.fnLock, LogicalKeyboardKey.hyper, LogicalKeyboardKey.superKey,
    LogicalKeyboardKey.symbol, LogicalKeyboardKey.symbolLock,
  };

  /// A key that changes what other keys mean and does nothing on its own.
  static bool isModifierKey(LogicalKeyboardKey key) => _modifiers.contains(key);
}
