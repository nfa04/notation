import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/settings_repository.dart';
import '../l10n/language.dart';
import '../util/public_host.dart';
import '../util/user_agent.dart';

/// An inbox: a place where anyone who has the link can leave files for the owner, but not read or change anything.
class InboxInfo {
  /// What goes into the link: where guests leave files.
  final Uri dropUrl;

  /// What the owner needs to read the inbox (a path).
  final String ref;

  const InboxInfo(this.dropUrl, this.ref);
}

/// A file in an inbox.
class InboxFile {
  final String name;

  const InboxFile(this.name);
}

/// A file that was put on a service: the address to download it from, and [ref], which is whatever that service
/// needs to replace it later (a path, a key). It is only meaningful to the service that gave it.
class StoredFile {
  final Uri url;
  final String ref;

  const StoredFile(this.url, this.ref);
}

/// A place a sealed copy of a note can be put so that anyone with the link can fetch it, whether or not the
/// person who shared it is online. What is stored is already sealed with a key that never leaves the link, so
/// a service needs no trust: it only has to keep a file and hand out an address for it.
///
/// To offer another service (Dropbox, Google Drive, a WebDAV folder, ...) implement this and add it to the
/// list given to `CloudShare`. Nothing else knows which services exist.
abstract class ShareStorage extends ChangeNotifier {
  /// What the person calls it: "Nextcloud".
  String get label;

  /// Whether it can be used now (an account is connected).
  bool get available;

  /// Why it cannot be used, for the person; null when it can.
  String? get unavailableReason => available ? null : tr('Connect {service} first.', {'service': label});

  /// How long a shared copy stays, for the person to read.
  Duration get keeps;

  /// Stores [sealed] and returns where it is and how to find it again.
  Future<StoredFile> store(Uint8List sealed);

  /// Stores [sealed] and returns an address anyone can download it from without an account.
  Future<Uri> upload(Uint8List sealed) async => (await store(sealed)).url;

  /// Whether a stored file can be replaced by [replace] (its address stays the same).
  bool get canReplace => true;

  /// Puts [sealed] in place of the file that [ref] (from [StoredFile.ref]) names. The address of the file does
  /// not change.
  Future<void> replace(String ref, Uint8List sealed) => throw UnsupportedError('replace');

  /// Whether this service can make an inbox, a place where people with the link leave sealed changes to the note.
  bool get hasInbox => false;

  /// Makes an inbox for the owner to read, and the address guests leave files at.
  Future<InboxInfo> createInbox() => throw UnsupportedError('inbox');

  /// Whether [dropUrl] is the inbox address of this kind of service (it works without an account).
  bool handlesDrop(Uri dropUrl) => false;

  /// Leaves [sealed] in the inbox at [dropUrl] under [name]; needs no account.
  Future<void> drop(Uri dropUrl, String name, Uint8List sealed) => throw UnsupportedError('drop');

  /// The files in the inbox [ref], for the owner.
  Future<List<InboxFile>> readInbox(String ref) async => const [];

  Future<Uint8List> readInboxFile(String ref, String name) => throw UnsupportedError('inbox');

  Future<void> removeInboxFile(String ref, String name) async {}

  /// Handles a link that opens the app on the way back from the service's sign-in page (`notation://oauth/...`).
  /// True if it was for this service.
  Future<bool> handleRedirect(Uri uri) async => false;

  /// Whether this service has to be asked in its own way for the file at [url] (most links are plain downloads).
  bool handles(Uri url) => false;

  /// The file at [url], for the addresses it [handles].
  Future<Uint8List> fetch(Uri url) => downloadShared(url);
}

/// Downloads the file a shared link points at. Only `https` is accepted (`http` when [allowInsecure], for tests). A link comes from
/// someone else, so every address it leads to (it may send on up to 5 times) must be a public one - not this device, not a private
/// network - and the file is cut off as soon as it is bigger than [maxBytes], not after it is all here.
Future<Uint8List> downloadShared(Uri url, {Dio? dio, bool allowInsecure = false, int maxBytes = 300 << 20}) async {
  final client = dio ??
      Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 2),
        headers: {...userAgentHeader},
      ));
  var at = url;
  for (var hop = 0;; hop++) {
    if (!(at.scheme == 'https' || (allowInsecure && at.scheme == 'http'))) {
      throw StateError(tr('This link does not use a secure address.'));
    }
    if (!allowInsecure) await checkPublicHost(at);
    final r = await client.getUri<ResponseBody>(
      at,
      options: Options(responseType: ResponseType.stream, followRedirects: false, validateStatus: (s) => s != null && s < 500),
    );
    final status = r.statusCode ?? 0;
    final next = r.headers.value('location');
    if (status >= 300 && status < 400 && next != null) {
      await r.data?.stream.drain<void>();
      if (hop >= 5) throw StateError(tr('The page sends on too many times.'));
      at = at.resolve(next);
      continue;
    }
    if (status == 404 || status == 410) throw StateError(tr('This shared copy is gone: it expired or was taken down.'));
    if (status != 200 || r.data == null) throw StateError(tr('The shared copy could not be downloaded ({code}).', {'code': r.statusCode}));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in r.data!.stream) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) throw StateError(tr('This shared copy is too big.'));
    }
    return bytes.takeBytes();
  }
}


/// The copies put on a service with the time, kept in the settings, so that the ones past their time can be
/// taken off again (a service that keeps files forever would otherwise fill up with them).
class UploadLedger {
  final SettingsRepository? _settings;
  final String _key;
  final DateTime Function() _now;

  UploadLedger(this._settings, this._key, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  Future<List<Map<String, Object?>>> _read() async {
    final text = await _settings?.get(_key);
    if (text == null) return [];
    try {
      return [for (final e in jsonDecode(text) as List) (e as Map).cast<String, Object?>()];
    } catch (_) {
      return [];
    }
  }

  /// Notes that [id] (whatever the service needs to delete it again) was put there now.
  Future<void> add(String id) async {
    final list = await _read()..add({'id': id, 'at': _now().millisecondsSinceEpoch});
    await _settings?.set(_key, jsonEncode(list));
  }

  /// Deletes the ones older than [after] with [delete] (true: gone, or already gone). Those it fails on are tried again later.
  Future<void> sweep(Duration after, Future<bool> Function(String id) delete) async {
    final list = await _read();
    final keep = <Map<String, Object?>>[];
    for (final e in list) {
      if (_now().millisecondsSinceEpoch - (e['at'] as int) < after.inMilliseconds) {
        keep.add(e);
        continue;
      }
      try {
        if (!await delete(e['id'] as String)) keep.add(e);
      } catch (_) {
        keep.add(e);
      }
    }
    if (keep.length != list.length) await _settings?.set(_key, jsonEncode(keep));
  }

  Future<void> clear() async => _settings?.remove(_key);
}
