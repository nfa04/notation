import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../shortcuts/key_combo.dart';
import '../shortcuts/shortcut_action.dart';
import '../shortcuts/shortcut_service.dart';
import '../style/platform_dialog.dart';

/// The keyboard shortcuts: every action with the keys that do it, and a way to change, add and take away keys.
class ShortcutSettings extends StatefulWidget {
  final ShortcutService service;

  const ShortcutSettings({super.key, required this.service});

  @override
  State<ShortcutSettings> createState() => _ShortcutSettingsState();
}

class _ShortcutSettingsState extends State<ShortcutSettings> {
  final _search = TextEditingController();

  ShortcutService get _service => widget.service;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Asks for a key combination for [action] and gives it: [replacing] is the one that is changed, if any.
  Future<void> _record(ShortcutAction action, {KeyCombo? replacing}) async {
    final combo = await showDialog<KeyCombo>(
      context: context,
      builder: (context) => _KeyRecorder(service: _service, action: action),
    );
    if (combo == null) return;
    if (replacing != null) await _service.removeBinding(action.id, replacing);
    await _service.addBinding(action.id, combo);
  }

  bool _shown(ShortcutAction a, String query) {
    if (query.isEmpty) return true;
    if (tr(a.label).toLowerCase().contains(query) || a.label.toLowerCase().contains(query)) return true;
    return _service.bindingsOf(a.id).any((c) => c.label().toLowerCase().contains(query));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([_service, _search]),
      builder: (context, _) {
        final query = _search.text.trim().toLowerCase();
        final groups = [
          for (final g in ShortcutGroup.values)
            (group: g, actions: [for (final a in _service.actions) if (a.group == g && _shown(a, query)) a]),
        ].where((g) => g.actions.isNotEmpty).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Keyboard shortcuts', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Press a key combination to run an action: tools, inserting things, going to another part of the app. '
            'Choose a shortcut to change it, or add more than one. Keys without Ctrl, Alt or Cmd only work while no text is being typed.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('shortcut-search'),
                controller: _search,
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Find an action or a key'), isDense: true, border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              key: const ValueKey('shortcuts-reset-all'),
              onPressed: _service.anyChanged ? _service.resetAll : null,
              child: Text('Reset all'),
            ),
          ]),
          if (groups.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Text('No action matches.', style: TextStyle(color: scheme.onSurfaceVariant))),
          for (final g in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 20, bottom: 4),
              child: Text(g.group.label, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary)),
            ),
            for (final a in g.actions) _row(a, scheme),
          ],
        ]);
      },
    );
  }

  Widget _row(ShortcutAction a, ColorScheme scheme) {
    final combos = _service.bindingsOf(a.id);
    return Padding(
      key: ValueKey('shortcut-row-${a.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(flex: 4, child: Text(a.label)),
        Expanded(
          flex: 5,
          child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (combos.isEmpty) Text('Not set', style: TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic, fontSize: 13)),
            for (final c in combos)
              InputChip(
                key: ValueKey('shortcut-${a.id}-${c.encode()}'),
                label: Text.verbatim(c.label(), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                visualDensity: VisualDensity.compact,
                tooltip: tr('Change this shortcut'),
                deleteButtonTooltipMessage: tr('Remove this shortcut'),
                onPressed: () => _record(a, replacing: c),
                onDeleted: () => _service.removeBinding(a.id, c),
              ),
            IconButton(
              key: ValueKey('shortcut-add-${a.id}'),
              tooltip: tr('Add a shortcut'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              onPressed: () => _record(a),
            ),
            if (_service.changed(a.id))
              IconButton(
                key: ValueKey('shortcut-reset-${a.id}'),
                tooltip: tr('Back to the usual shortcut'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.restart_alt, size: 18),
                onPressed: () => _service.reset(a.id),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Waits for the keys to be pressed that are to be the shortcut, and shows what else they do now.
class _KeyRecorder extends StatefulWidget {
  final ShortcutService service;
  final ShortcutAction action;

  const _KeyRecorder({required this.service, required this.action});

  @override
  State<_KeyRecorder> createState() => _KeyRecorderState();
}

class _KeyRecorderState extends State<_KeyRecorder> {
  KeyCombo? _combo;

  /// The modifiers that are held before the key is pressed.
  String _held = '';

  @override
  void initState() {
    super.initState();
    widget.service.pause(); // the keys pressed here are not shortcuts, they are the one that is being set
  }

  @override
  void dispose() {
    widget.service.resume();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (_combo == null) setState(() => _held = _modifiersHeld());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _modifiersHeld().isEmpty) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    final combo = KeyCombo.fromEvent(event);
    setState(() {
      if (combo == null) {
        _held = _modifiersHeld();
      } else {
        _combo = combo;
      }
    });
    return KeyEventResult.handled;
  }

  String _modifiersHeld() {
    final k = HardwareKeyboard.instance;
    return [
      if (k.isControlPressed) 'Ctrl',
      if (k.isAltPressed) 'Alt',
      if (k.isShiftPressed) 'Shift',
      if (k.isMetaPressed) 'Cmd',
    ].join('+');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final combo = _combo;
    final others = combo == null ? const <ShortcutAction>[] : widget.service.usedBy(combo, except: widget.action.id);
    return PlatformAlertDialog(
      title: Text.verbatim(tr(widget.action.label)),
      content: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Press the keys that should do this. Esc cancels.'),
            const SizedBox(height: 16),
            Container(
              key: const ValueKey('key-recorder'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.primary, width: 2),
                color: scheme.surfaceContainerHighest,
              ),
              child: Center(
                child: combo != null
                    ? Text.verbatim(combo.label(), style: Theme.of(context).textTheme.headlineSmall)
                    : Text.verbatim(_held.isEmpty ? tr('Waiting for keys...') : '$_held+...', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 18)),
              ),
            ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text.verbatim(
                tr('Already used for: {actions}. Using it here takes it away from there.', {'actions': others.map((a) => tr(a.label)).join(', ')}),
                style: TextStyle(color: scheme.error, fontSize: 13),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
        FilledButton(key: const ValueKey('key-recorder-assign'), onPressed: combo == null ? null : () => Navigator.pop(context, combo), child: Text('Use this shortcut')),
      ],
    );
  }
}
