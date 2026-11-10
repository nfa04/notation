import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';
import '../lock/note_lock_service.dart';
import '../style/platform_dialog.dart';

/// Asks for the passcode or passphrase of a locked note and opens it. Returns whether the note is open.
Future<bool> unlockNote(BuildContext context, NoteLockService locks, String noteId) async {
  if (locks.isOpen(noteId)) return true;
  final mode = await locks.modeOf(noteId);
  if (mode == LockMode.none) return true;
  final device = await locks.deviceUnlockAllowed(noteId) && await locks.deviceCanUnlock();
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UnlockDialog(locks: locks, noteId: noteId, mode: mode, device: device),
      ) ??
      false;
}

class _UnlockDialog extends StatefulWidget {
  final NoteLockService locks;
  final String noteId;
  final LockMode mode;
  final bool device;
  const _UnlockDialog({required this.locks, required this.noteId, required this.mode, required this.device});

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final _secret = TextEditingController();
  bool _busy = false, _wrong = false, _hidden = true;

  @override
  void initState() {
    super.initState();
    if (widget.device) WidgetsBinding.instance.addPostFrameCallback((_) => _withDevice());
  }

  @override
  void dispose() {
    _secret.dispose();
    super.dispose();
  }

  Future<void> _try() async {
    if (_busy || _secret.text.isEmpty) return;
    setState(() {
      _busy = true;
      _wrong = false;
    });
    final ok = await widget.locks.unlock(widget.noteId, _secret.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _wrong = true;
      });
    }
  }

  Future<void> _withDevice() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.locks.unlockWithDevice(widget.noteId, tr('Unlock the note'));
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final encrypted = widget.mode == LockMode.encrypted;
    return PlatformAlertDialog(
      title: Row(children: [const Icon(Icons.lock_outline), const SizedBox(width: 12), Text(encrypted ? 'Encrypted note' : 'Locked note')]),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: const ValueKey('unlock-secret'),
            controller: _secret,
            autofocus: true,
            obscureText: _hidden,
            enabled: !_busy,
            onSubmitted: (_) => _try(),
            decoration: InputDecoration(
              labelText: tr(encrypted ? 'Passphrase' : 'Passcode'),
              errorText: _wrong ? tr(encrypted ? 'That is not the passphrase.' : 'That is not the passcode.') : null,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: tr(_hidden ? 'Show' : 'Hide'),
                icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _hidden = !_hidden),
              ),
            ),
          ),
          if (_busy)
            const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (widget.device && !_busy)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('unlock-device'),
                icon: const Icon(Icons.fingerprint),
                label: const Text('Use fingerprint or face'),
                onPressed: _withDevice,
              ),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('unlock-go'), onPressed: _busy ? null : _try, child: const Text('Unlock')),
      ],
    );
  }
}

/// Asks how to lock the note, with what secret, and does it. Returns the way it was locked, or null if cancelled.
/// [beforeEncrypting] is called first (the editor saves the note); [afterEncrypting] once the note is encrypted and its content
/// gone (the editor has to be left).
Future<LockMode?> lockNoteDialog(
  BuildContext context,
  NoteLockService locks,
  String noteId, {
  Future<void> Function()? beforeEncrypting,
  VoidCallback? afterEncrypting,
}) async {
  final device = await locks.deviceCanUnlock();
  if (!context.mounted) return null;
  final choice = await showDialog<({LockMode mode, String secret, bool device})>(
    context: context,
    builder: (_) => _LockSetupDialog(device: device),
  );
  if (choice == null) return null;
  if (choice.mode == LockMode.encrypted) {
    await beforeEncrypting?.call();
    await locks.lockEncrypted(noteId, choice.secret, allowDevice: choice.device);
    afterEncrypting?.call();
  } else {
    await locks.lockWithPasscode(noteId, choice.secret, allowDevice: choice.device);
  }
  return choice.mode;
}

class _LockSetupDialog extends StatefulWidget {
  final bool device;

  /// Set when the way of locking stays and only the secret is changed.
  final LockMode? only;
  const _LockSetupDialog({required this.device, this.only});

  @override
  State<_LockSetupDialog> createState() => _LockSetupDialogState();
}

class _LockSetupDialogState extends State<_LockSetupDialog> {
  late LockMode _mode = widget.only ?? LockMode.passcode;
  final _secret = TextEditingController(), _again = TextEditingController();
  bool _device = false, _hidden = true;
  String? _problem;

  @override
  void dispose() {
    _secret.dispose();
    _again.dispose();
    super.dispose();
  }

  void _go() {
    final encrypted = _mode == LockMode.encrypted;
    if (_secret.text.length < (encrypted ? 6 : 4)) {
      setState(() => _problem = tr(encrypted ? 'Use at least 6 characters.' : 'Use at least 4 characters.'));
      return;
    }
    if (_secret.text != _again.text) {
      setState(() => _problem = tr('The two entries are not the same.'));
      return;
    }
    Navigator.pop(context, (mode: _mode, secret: _secret.text, device: _device && widget.device));
  }

  Widget _option(LockMode mode, IconData icon, String title, String about) => RadioListTile<LockMode>.adaptive(
        key: ValueKey('lock-mode-${mode.name}'),
        contentPadding: EdgeInsets.zero,
        value: mode,
        secondary: Icon(icon),
        title: Text(title),
        subtitle: Text(about),
      );

  @override
  Widget build(BuildContext context) {
    final encrypted = _mode == LockMode.encrypted;
    return PlatformAlertDialog(
      title: Text(widget.only == null ? 'Lock this note' : (encrypted ? 'New passphrase' : 'New passcode')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.only == null)
              RadioGroup<LockMode>(
                groupValue: _mode,
                onChanged: (v) => setState(() {
                  _mode = v!;
                  _problem = null;
                }),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  _option(LockMode.passcode, Icons.visibility_off_outlined, 'Passcode', 'Keeps the note out of sight: its title is hidden and it asks for the passcode to open. The content is stored as usual, so this does not protect against someone who reads the files of the app.'),
                  _option(LockMode.encrypted, Icons.lock_outline, 'Encrypted', 'Encrypts the whole note, its title too, with a passphrase. Nothing of it is stored in plain, except while it is open. If you forget the passphrase, the note is lost for good.'),
                ]),
              ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('lock-secret'),
              controller: _secret,
              obscureText: _hidden,
              decoration: InputDecoration(
                labelText: tr(encrypted ? 'Passphrase' : 'Passcode'),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: tr(_hidden ? 'Show' : 'Hide'),
                  icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _hidden = !_hidden),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('lock-again'),
              controller: _again,
              obscureText: _hidden,
              onSubmitted: (_) => _go(),
              decoration: InputDecoration(labelText: tr('Once more'), border: const OutlineInputBorder(), errorText: _problem),
            ),
            if (widget.device)
              SwitchListTile.adaptive(
                key: const ValueKey('lock-device'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Open with fingerprint or face'),
                subtitle: const Text('Keeps the secret in this device\'s keystore, to be given by the device.'),
                value: _device,
                onChanged: (v) => setState(() => _device = v),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('lock-go'), onPressed: _go, child: const Text('Lock')),
      ],
    );
  }
}

/// Asks for a new passcode or passphrase for an open locked note.
Future<bool> changeSecretDialog(BuildContext context, NoteLockService locks, String noteId) async {
  final mode = await locks.modeOf(noteId);
  final device = await locks.deviceCanUnlock();
  if (!context.mounted) return false;
  final choice = await showDialog<({LockMode mode, String secret, bool device})>(
    context: context,
    builder: (_) => _LockSetupDialog(device: device, only: mode),
  );
  if (choice == null) return false;
  return locks.changeSecret(noteId, choice.secret, allowDevice: choice.device);
}
