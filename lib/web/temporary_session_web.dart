import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Everything of a temporary session is kept in the browser like the data of any other (the database and the files in IndexedDB, the
/// profile's secret in localStorage), and a page cannot run code reliably while its tab is closed. So the session is marked twice:
///
///  * in localStorage (lasts): "this browser holds a temporary session";
///  * in sessionStorage (lasts as long as the tab, and through a reload): "and its tab is still open".
///
/// When the app starts and finds the first without the second, its tab was closed: [wipeEndedTemporarySession] throws away
/// everything the browser keeps for the page before anything of it is opened. That is the guarantee. It happens the next time the
/// page is opened, not at the moment the tab closes: a browser on a shared computer keeps the data until then.
const _kMarked = 'notation_temporary_session';
const _kAlive = 'notation_temporary_alive';

String? _local(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

bool get temporaryMarked => _local(_kMarked) == '1';

/// A flag in localStorage that only says "a profile is set up in this browser" (no secret in it). The server that hosts the page
/// cannot see the browser's storage, but a landing page on the same address can: see docs/web_landing_redirect.md.
void setSignedInFlag(bool signedIn) {
  try {
    if (signedIn) {
      web.window.localStorage.setItem('notation_signed_in', '1');
    } else {
      web.window.localStorage.removeItem('notation_signed_in');
    }
  } catch (_) {}
}

/// This browser holds a temporary session, and this tab is its tab.
void markTemporary() {
  try {
    web.window.localStorage.setItem(_kMarked, '1');
    web.window.sessionStorage.setItem(_kAlive, '1');
  } catch (_) {
    // storage blocked: the session cannot be told from a normal one, and nothing is kept either
  }
}

/// The session is over (signed out): the tab is no longer its tab, so the next start throws the data away. (The caller reloads.)
void endTemporary() {
  try {
    web.window.sessionStorage.removeItem(_kAlive);
  } catch (_) {}
}

Future<void> wipeEndedTemporarySession() async {
  try {
    if (_local(_kMarked) != '1') return;
    if (web.window.sessionStorage.getItem(_kAlive) == '1') return; // (a reload of the same tab)
  } catch (_) {
    return;
  }
  try {
    final databases = await web.window.indexedDB.databases().toDart;
    for (final d in databases.toDart) {
      final name = d.name;
      final done = Completer<void>();
      final request = web.window.indexedDB.deleteDatabase(name);
      request.onsuccess = ((web.Event _) => done.complete()).toJS;
      request.onerror = ((web.Event _) => done.complete()).toJS;
      request.onblocked = ((web.Event _) => done.complete()).toJS;
      await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }
  } catch (_) {
    // a browser without the list of databases: the data of the site stays, and so does the mark, so the next start tries again
    return;
  }
  try {
    web.window.localStorage.clear();
    web.window.sessionStorage.clear();
  } catch (_) {}
}

JSFunction? _guard;

/// While [on], the browser asks before the tab is closed or left.
void warnBeforeLeaving(bool on) {
  if (on == (_guard != null)) return;
  if (on) {
    _guard = ((web.Event e) {
      e.preventDefault();
      // (older browsers want this too; the text is not shown by any of them)
      (e as web.BeforeUnloadEvent).returnValue = '';
    }).toJS;
    web.window.addEventListener('beforeunload', _guard);
  } else {
    web.window.removeEventListener('beforeunload', _guard);
    _guard = null;
  }
}

/// Opens the page again (after signing out).
void reloadPage() => web.window.location.reload();
