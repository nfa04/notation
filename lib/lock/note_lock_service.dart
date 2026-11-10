import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../data/note_file_service.dart';
import '../data/lock_repository.dart' show LockRow;
import '../data/note_repository.dart';
import 'lock_crypto.dart';
import '../data/app_secure_storage.dart';

/// How a note is locked.
enum LockMode {
  none,

  /// A passcode to open it, and it is kept out of sight (no title shown in the lists, not searched, no preview). Its content is
  /// stored as it is, so this keeps people from looking, not from reading the database.
  passcode,

  /// Its content (and title) is encrypted under a passphrase and is not in the database until it is opened, and put away again
  /// when it is closed. Forgetting the passphrase loses the note.
  encrypted;

  static LockMode of(int i) => i >= 0 && i < values.length ? values[i] : none;
}

/// The device's own way to unlock: fingerprint, face or the screen lock. [available] says whether there is one.
abstract class DeviceAuth {
  Future<bool> available();
  Future<bool> authenticate(String reason);
}

/// [DeviceAuth] with the system dialog (fingerprint, face, device PIN) of Android, iOS, macOS and Windows.
class LocalDeviceAuth implements DeviceAuth {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    try {
      if (kIsWeb || !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows)) return false;
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason);
    } catch (_) {
      return false;
    }
  }
}

/// Where the passphrase of a note is kept when the person lets the device unlock it (the platform keystore).
abstract class PassphraseVault {
  Future<String?> read(String noteId);
  Future<void> write(String noteId, String secret);
  Future<void> delete(String noteId);
}

/// [PassphraseVault] in the secure storage of the system (Keystore, Keychain), so the device can unlock a note without asking.
class KeystoreVault implements PassphraseVault {
  final FlutterSecureStorage _storage;
  const KeystoreVault([this._storage = appSecureStorage]);

  String _key(String id) => 'note_lock_$id';

  @override
  Future<String?> read(String noteId) => _storage.read(key: _key(noteId));

  @override
  Future<void> write(String noteId, String secret) => _storage.write(key: _key(noteId), value: secret);

  @override
  Future<void> delete(String noteId) => _storage.delete(key: _key(noteId));
}

/// Locks notes, opens them and puts them away again.
///
/// A note is [locked] in one of two ways ([LockMode]). Opening one ([unlock]) makes it readable until it is put away
/// ([seal]): when the person leaves it, the app goes out of sight or closes. An encrypted note is, while it is open, in the
/// database in plain, like any note; [seal] writes it into its encrypted block again and takes it out of the database.
class NoteLockService extends ChangeNotifier {
  final NoteRepository repository;
  final NoteFileService files;
  final DeviceAuth deviceAuth;
  final PassphraseVault vault;

  /// Told when an encrypted note is put away (its earlier versions in the history are removed, for one).
  final Future<void> Function(String noteId)? onSealed;

  /// How hard a passphrase is stirred into a key (tests use less).
  final int _iterations;

  /// The key of each encrypted note that is open, kept in memory only.
  final Map<String, Uint8List> _keys = {};

  NoteLockService(this.repository, this.files, {DeviceAuth? deviceAuth, PassphraseVault? vault, this.onSealed, int iterations = lockIterations})
      : _iterations = iterations,
        deviceAuth = deviceAuth ?? LocalDeviceAuth(),
        vault = vault ?? const KeystoreVault();

  Future<LockMode> modeOf(String noteId) async => LockMode.of(await repository.locks.lockModeOf(noteId));

  /// Whether the note can be read now (it is not locked, or it is open).
  bool isOpen(String noteId) => repository.locks.unlocked.contains(noteId);

  Future<bool> deviceCanUnlock() => deviceAuth.available();

  /// Whether the device may unlock this note (the person allowed it when locking).
  Future<bool> deviceUnlockAllowed(String noteId) async => await vault.read(noteId) != null;

  // ---- locking

  /// Locks [noteId] with a passcode. With [allowDevice] the device's fingerprint or face can open it too.
  Future<void> lockWithPasscode(String noteId, String passcode, {bool allowDevice = false}) async {
    final salt = randomBytes(16);
    final verifier = await passcodeVerifier(passcode, salt, _iterations);
    await repository.locks.putLock(noteId, LockRow(mode: 1, salt: salt, iterations: _iterations, verifier: verifier));
    if (allowDevice) await vault.write(noteId, passcode);
    // the note is open now: the person has just set the lock
    repository.locks.unlocked.add(noteId);
    notifyListeners();
  }

  /// Locks [noteId] and encrypts it under [passphrase]. The note is put away at once (so it should not be open in an editor
  /// that saves it again): its content is only in the encrypted block afterwards.
  Future<void> lockEncrypted(String noteId, String passphrase, {bool allowDevice = false}) async {
    final bytes = await files.exportBytes(noteId, locked: true);
    if (bytes == null) throw StateError('There is no such note.');
    final salt = randomBytes(16);
    final key = await deriveKey(passphrase, salt, _iterations);
    final sealed = await encrypt(key, bytes);
    await repository.locks.putLock(noteId, LockRow(mode: 2, salt: salt, iterations: _iterations, nonce: sealed.nonce, data: sealed.data, open: true));
    if (allowDevice) await vault.write(noteId, passphrase);
    _keys[noteId] = key;
    repository.locks.unlocked.add(noteId);
    await seal(noteId);
  }

  // ---- opening

  /// Opens [noteId] with [secret] (the passcode or the passphrase). False if it is wrong.
  Future<bool> unlock(String noteId, String secret) async {
    final lock = await repository.locks.lockRow(noteId);
    if (lock == null) return true;
    if (lock.mode == 1) {
      final check = await passcodeVerifier(secret, lock.salt, lock.iterations);
      if (lock.verifier == null || !sameBytes(check, lock.verifier!)) return false;
      await _strengthenPasscode(noteId, lock, secret);
      repository.locks.unlocked.add(noteId);
      notifyListeners();
      return true;
    }
    final key = await deriveKey(secret, lock.salt, lock.iterations);
    final clear = lock.nonce == null || lock.data == null ? null : await decrypt(key, lock.nonce!, lock.data!);
    if (clear == null) return false;
    if (!lock.open) {
      // put the note back into the database; one that was left open (the app stopped) still has its newer content there
      await files.restoreInto(noteId, clear);
      await repository.locks.putLock(noteId, lock.copyWith(open: true));
    }
    _keys[noteId] = key;
    await _strengthenEncrypted(noteId, lock, secret, clear);
    repository.locks.unlocked.add(noteId);
    notifyListeners();
    return true;
  }

  /// A lock made when passphrases were stirred fewer times is made again with [_iterations] (a new salt too), now that the secret is
  /// known. It is only a better lock: if anything goes wrong the old one is still there and still works.
  Future<void> _strengthenPasscode(String noteId, LockRow lock, String passcode) async {
    if (lock.iterations >= _iterations) return;
    try {
      final salt = randomBytes(16);
      await repository.locks.putLock(noteId, LockRow(mode: 1, salt: salt, iterations: _iterations, verifier: await passcodeVerifier(passcode, salt, _iterations)));
    } catch (_) {
      // (tried again the next time it is opened)
    }
  }

  /// Like [_strengthenPasscode]: the key is made again and the block sealed under it. [clear] is what the block holds. The note is
  /// marked open, as it is while it is in use.
  Future<void> _strengthenEncrypted(String noteId, LockRow lock, String passphrase, Uint8List clear) async {
    if (lock.iterations >= _iterations) return;
    try {
      final salt = randomBytes(16);
      final key = await deriveKey(passphrase, salt, _iterations);
      final sealed = await encrypt(key, clear);
      await repository.locks.putLock(noteId, LockRow(mode: 2, salt: salt, iterations: _iterations, nonce: sealed.nonce, data: sealed.data, open: true));
      _keys[noteId] = key;
    } catch (_) {
      // (tried again the next time it is opened)
    }
  }

  /// Opens the note with the device's fingerprint, face or screen lock, if that was allowed when it was locked.
  Future<bool> unlockWithDevice(String noteId, String reason) async {
    final secret = await vault.read(noteId);
    if (secret == null) return false;
    if (!await deviceAuth.authenticate(reason)) return false;
    return unlock(noteId, secret);
  }

  // ---- putting away

  /// Closes [noteId]: an encrypted note is written into its encrypted block (the editor must have saved it) and taken out of
  /// the database; a passcode note only has to be opened again with the passcode. Does nothing for a note that is not open.
  Future<void> seal(String noteId) async {
    if (!repository.locks.unlocked.contains(noteId)) return;
    final lock = await repository.locks.lockRow(noteId);
    if (lock != null && lock.mode == 2) {
      final key = _keys[noteId];
      if (key == null) return; // (opened before the app stopped: it is put away when it is opened with its passphrase)
      final bytes = await files.exportBytes(noteId, locked: true);
      if (bytes == null) return;
      final sealed = await encrypt(key, bytes);
      // the block is written first: only then is the plain content taken away
      await repository.locks.putLock(noteId, lock.copyWith(nonce: sealed.nonce, data: sealed.data, open: false));
      final gone = await repository.locks.purgeContent(noteId);
      for (final path in gone) {
        try {
          await File(path).delete();
        } on FileSystemException {
          // already gone
        }
      }
      await onSealed?.call(noteId);
      _keys.remove(noteId);
    }
    repository.locks.unlocked.remove(noteId);
    notifyListeners();
  }

  /// Puts away every note that is open.
  Future<void> sealAll() async {
    for (final id in List.of(repository.locks.unlocked)) {
      await seal(id);
    }
  }

  // ---- changing

  /// Takes the lock off [noteId], which must be open. Returns false if it is not.
  Future<bool> removeLock(String noteId) async {
    if (!repository.locks.unlocked.contains(noteId)) return false;
    await repository.locks.removeLock(noteId);
    await vault.delete(noteId);
    _keys.remove(noteId);
    repository.locks.unlocked.remove(noteId);
    notifyListeners();
    return true;
  }

  /// A new passcode or passphrase for an open note.
  Future<bool> changeSecret(String noteId, String newSecret, {bool allowDevice = false}) async {
    if (!repository.locks.unlocked.contains(noteId)) return false;
    final lock = await repository.locks.lockRow(noteId);
    if (lock == null) return false;
    final salt = randomBytes(16);
    if (lock.mode == 1) {
      await repository.locks.putLock(noteId, LockRow(mode: 1, salt: salt, iterations: _iterations, verifier: await passcodeVerifier(newSecret, salt, _iterations)));
    } else {
      final key = await deriveKey(newSecret, salt, _iterations);
      final bytes = await files.exportBytes(noteId, locked: true);
      if (bytes == null) return false;
      final sealed = await encrypt(key, bytes);
      await repository.locks.putLock(noteId, LockRow(mode: 2, salt: salt, iterations: _iterations, nonce: sealed.nonce, data: sealed.data, open: true));
      _keys[noteId] = key;
    }
    if (allowDevice) {
      await vault.write(noteId, newSecret);
    } else {
      await vault.delete(noteId);
    }
    notifyListeners();
    return true;
  }
}
