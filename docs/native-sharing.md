# Sharing with people through the cloud service (native sharing)

*Status: built for Nextcloud (tested against a real Nextcloud 34), OneDrive and Dropbox (tested against fakes of their APIs only). "What is built" and "What is left" at the end say what that means.*

Share a **note** or a whole **folder** with another person who uses the **same cloud service** (Nextcloud, OneDrive, Dropbox), as the
service itself understands sharing: the person is invited by name or e-mail, sees the share in their own cloud account, can be given
**read-only** or **edit** rights, and can be removed again. Both sides then keep their copies in step, the same way
[the sync through a cloud folder](profile-sync.md) keeps one person's devices in step.

It is an extension of the cloud sync, not a second sync: the same engine (`FolderSync`), the same `CloudFolder` access to the service,
the same accounts. What differs is who is in the sync (several people, not one person's devices) and which part of the library
travels (one note or one folder, not everything).

## How it differs from "share a link"

| | Link copy (`collab/cloud_share.dart`) | Sharing with a person (`nativeshare/`) |
|---|---|---|
| Who can open it | anyone with the link | only the people invited, signed in at the service |
| Protection | the file is sealed, the key is in the link | the service's own access control; the files are **plain** |
| After sharing | a one-time copy; changes go back through an inbox | both sides keep syncing; edits travel both ways |
| Stop sharing | the copy expires (7 to 30 days) | remove the person at the service; the share ends at once |
| Needs | any storage account, even only the sender's | the same service on both sides |

**The files are not sealed.** The service can read what is shared, as it can read anything else in a shared folder. That is the price
of letting the service do the access control, and it is the default on purpose. Locked notes cannot be shared (take the lock off
first). Anything that should stay unreadable to the service is better sent as a link copy, which is sealed.

## What the person sees

* **Share a note or folder:** from the live button of the note (*Share this note with a person*) or the menu of a folder (*Share with people...*). Choose the service, search for the person (Nextcloud completes
  names; for OneDrive and Dropbox it is their e-mail address), choose *Can view* or *Can edit*, share. The people it is shared with are
  listed there and can be changed or removed.
* **Receiving:** the person gets the invitation from the service itself. In the app, *Settings → Sharing and files → Shared with people* lists
  the shares waiting on their account (the app looks every few minutes, and on request); they choose where in their library it goes and accept. A shared note appears as a note, a shared folder as a folder
  (with everything below it), marked as shared.
* **Working on it:** with *Can edit*, changes are published and taken in like the sync of one's own devices, every few minutes, after
  a change, and on request. When two people changed the same note in between, the newer one wins and the older is kept next to it as a
  copy ("from before the sync"), so nothing is lost. With *Can view*, the person's own edits stay on their device and are replaced by
  the owner's next version (the replaced version is kept as a copy too).
* **Stopping:** the owner removes a person (they stop receiving; what they already have stays with them) or stops the share (everyone
  stops, the shared place is removed from the owner's cloud). A person who received a share can leave it; their notes stay, unshared.

## How it works

### Where the files go

For every share the owner has a folder in their own cloud space, `Notation Shares/<name> (<short id>)`, and shares *that folder* with the
people at the service. Everyone who takes part writes only in a directory of their own inside it and reads those of the others (the
rule that makes `FolderSync` safe without any locking), so two people never write the same file and the service needs no
compare-and-swap:

```
Notation Shares/Physics (3fa9c1)/        <- the folder shared at the service
  p/<participant id>                       who takes part (a name for the others to see)
  d-<participant id>/manifest.json         what this participant has: notes, folders, deletions, and when each changed
  d-<participant id>/n/<note id>.<version>.uninote    the notes, one file per note and version
  d-<participant id>/f/...                 pictures of folders
```

A participant is a *device* (a person with two devices is two participants), named by the device id of the sync profile. A *view-only*
participant never writes, so there is no directory of theirs (the service would refuse the write anyway).

### How little a run asks (the quick run)

A run used to read the participants' files and every participant's manifest each time, for every share, whatever had changed: on a
Nextcloud, in a browser, that is two requests (the request and its CORS preflight) for each file, every few minutes. Now:

* `CloudFolder.stamps(dir)` asks the service, in one `PROPFIND Depth:1`, for a token of the folder and of each thing directly in it (a
  Nextcloud's ETag, which for a directory follows everything below it). Other services answer null and are run in full, as before.
* A **quick run** (the timer, the app coming back, a change, a note being opened) keeps what the last run that went well saw
  (`share_<id>_seen`): the stamp of the folder if this device wrote nothing, the stamp of the participants' directory and who was in it,
  and the stamp of each participant's directory. If the folder has the same stamp and nothing changed here, **the run is that one
  request**. If it does not, the participants come from the last look when their directory did not change, and only the manifests of the
  participants whose directory did change are read (so a participant who stopped using the app costs nothing).
* It is a full look again every 10 minutes (`maxAge`), after any run that had a problem or left a file for later, and for the press of
  *Sync now* (`syncNow()` without `quick`). That is the safety net if a service's stamps do not follow what is below a directory.
* A device says that it takes part (`p/<device>`) only when its file is not there or its words changed, not on every run.
* A change here runs only the shares it concerns (the note is in the share, was in it, or has just been put in a shared folder), 30
  seconds after the person stops editing; a note in no share runs nothing. The shares given to the person are looked for every 5 minutes
  at most by quick runs. Opening a note looks in its share once per 20 seconds at most, and costs one request when nothing changed.
* The console says what a quick run did: `[share] <name>: nothing new up there ...` or `... N of M participants unchanged ...`.

### What travels: the scope

The sync engine works on "the library". For a share it works on a **scoped** view of the library (`ScopedSyncLibrary`): only the
shared note, or the shared folder and everything below it. Which notes and folders belong to a share is kept in `native_share_items`
and refreshed from the library each run (a note put into the folder by anyone joins; a note moved out leaves, which does not delete it
for the others). Settings never travel in a share.

What a participant publishes is taken in only for things that belong to the share, so someone who can write in the shared folder cannot
reach anything else in the library:

* A note or folder in a manifest that already exists on this device **and is not part of the share** is ignored (a planted id cannot
  overwrite another note).
* A deletion is taken only for things that are part of the share.
* The root of a shared folder is placed where the person chose when accepting; the owner's own place for it means nothing here. A shared
  note is placed there too, and its place is not changed by later versions.
* Note files go through the normal import (size limits, no code is run from a note file).
* Who wrote what is shown from what the service says about the share owner, never from names inside the files.

An *editor* is trusted as much as the service lets them be: they can write in every participant's directory of the shared folder, so a
malicious editor can damage the share (not anything outside it). Give edit rights to people you trust.

### The service side (`NativeShareProvider`)

One interface per service: search people, share a folder with a person and a role, list and change who has it, stop sharing, list
the shares waiting on my account, accept one, and the `CloudFolder` of a shared place (my own folder, or the place a share I received
appears at). Reading and writing the files is the existing `CloudFolder` of that service (retries included), so a provider only adds the
sharing calls.

| Service | Sharing calls | Notes |
|---|---|---|
| **Nextcloud** (also ownCloud) | OCS Share API: `shareType` 0 (user), `permissions` bitmask (read 1, update 2, create 4, delete 8); the *sharees* search for completion; `shared_with_me` for the shares received, `shares/pending` for those that wait to be accepted | Works with the account already connected for the calendar. Tested against a real Nextcloud 34. |
| **OneDrive** (personal and work or school) | Microsoft Graph `driveItem: invite` (roles `read`, `write`; the recipient by e-mail); the share is found from a **link** | Works for personal accounts too; needs a wider permission, which is a choice in the settings (below). |
| **Dropbox** | `sharing/share_folder`, `add_folder_member` (`viewer`, `editor`), `list_mountable_folders` and `mount_folder` for receiving | Needs the **full Dropbox** access type (below). |
| **S3** | none | S3 has no users to share with; use link copies. |

**OneDrive.** (Microsoft Learn, *driveItem: invite*, *createLink*, *sharedWithMe*.)

* `invite` works for personal Microsoft accounts with the delegated permission `Files.ReadWrite`, **but not on the root of the drive**.
  The shared folder is a sub folder (`Notation Shares/...`), which is how it is laid out anyway. For personal accounts the
  recipient is identified by e-mail and has to sign in with that account.
* The app signs in today with `Files.ReadWrite.AppFolder`, which cannot read what other people shared. Reading and writing a shared
  folder needs `Files.ReadWrite.All`. This is a **change of the app registration and a new consent** for everyone who uses OneDrive.
  The existing sync folder keeps working with the wider permission.
* The list *sharedWithMe* is **deprecated and stops returning data in November 2026**. So the shares received are found from a **link**,
  and the app does not rely on listing. The invitation carries one: after `invite`, the app has the id of the share (`shareId`) and makes
  `notation://share?p=onedrive&s=<id>` (or, if the answer has no id, the address of the folder). The sender copies it from the share panel
  (the link button beside the person) and sends it; the person opens it (the app takes `notation://share` links) or pastes it under
  *Settings → Sharing and files → Shared with people*. The plain link in Microsoft's invitation e-mail works too. The app resolves it with the `shares`
  API (`Prefer: redeemSharingLink`, which is what lets the person reach the folder by its address afterwards) and lists the links that opened
  something; a link that opens nothing any more means the share was withdrawn.
* The permission is **a choice**: *Settings → Sharing copies → OneDrive → Also allow sharing with people*. It switches the sign-in from
  `Files.ReadWrite.AppFolder` to `Files.ReadWrite.All` and signs out, so the next sign-in asks for the wider permission. Until then (or when the
  person gave less) OneDrive is listed with the reason and cannot be used for sharing; link copies are unaffected.
* If a particular account cannot share by invitation (an admin disabled it, a type of account that Microsoft restricts), the provider
  says so (`unsupportedReason`) and OneDrive is **disabled for sharing with people** for that account, with the reason shown in the
  share panel and the settings. It is not hidden: link copies still work.

**Dropbox.** (Dropbox developer forum, secondary sources: confirm against the current Dropbox documentation when registering.)

* An app registered with the **App folder** access type cannot share its folder or reach a folder shared with the user, and the access
  type of an existing app cannot be changed. Native sharing therefore needs a **new app registration with "Full Dropbox"** access
  (scopes `files.content.read`, `files.content.write`, `files.metadata.read`, `sharing.read`, `sharing.write`), and its key in
  `collab/defaults.dart` with `dropboxFullAccess = true`. A person who enters their own app key turns on *Also allow sharing with people*
  themselves (it asks for `sharing.read` too, which an app that was not registered for it would refuse at the sign-in).
* Dropbox lists what is shared with a person (`list_mountable_folders`), so no link is needed: a share waits in the settings, and accepting it
  mounts the folder in their Dropbox. The person typed in is an e-mail address; people without a Dropbox get Dropbox's own invitation.
* People connect again with the new registration. Files the old registration put in `Apps/Notation/...` stay there. A full-access app
  has no "app folder" to put its sync folder in, so its folders move to a folder of its own in the Dropbox (say `/Notation`), and the first
  run on each device writes the library there again. (To be decided when it is built.)

### What a real Nextcloud taught

The provider was first written from the documentation and a fake; a real Nextcloud 34 (run in a container) showed three differences, now handled and covered by tests (`test/nativeshare/real_nextcloud_test.dart`, run with `UNINOTES_NC_URL=...`, skipped otherwise):

* Sharing a folder with someone it is shared with already is not an error: the server answers with the existing share, **unchanged**. So the role is set afterwards when it differs.
* Shares that wait to be accepted are not in `shared_with_me`. They are listed apart (`shares/pending`), and without the rights they will have; the rights show once accepted. (Whether a person has to accept is their own setting, `files_sharing default_accept`.)
* Creating shares is rate limited (20 in 10 minutes for a person): the answer 429 is shown as "try again in a few minutes".

Not tried: ownCloud, Nextcloud versions before 25, and Nextcloud servers where link or user sharing is switched off by the administrator (the server's own message is shown).

### What stays the same

Profile sync, the folder sync and link copies are untouched. A shared folder is *also* part of the owner's own library, so it is also in
the owner's normal cloud sync (sealed or plain as they chose there). The share is a second, scoped sync of part of the same library.

## Working on a note live with the people it is shared with

A note of a share that is open on two people's devices at the same time is worked on **live**, like a note that is open on two of one person's
own devices (see [profile-sync.md](profile-sync.md)): each sees what the other draws and writes, and the notes come together. It uses the same
parts - a room on the signalling server (the one set under *Live collaboration*), direct connections between the devices, and the same
session - with the people of the share in place of the devices of the profile (`nativeshare/share_live.dart`):

* **The room.** Every share has a secret for working live. It is in `share.json` in the shared folder (so everybody it is shared with has it
  after they take the share in) and names the room; a device is in the room only while a note of the share is open on it. The devices tell each
  other (sealed with the secret) which notes of the share they have open; of those with the same note open, the one with the lowest id hosts the
  session and the others join it.
* **Who may take part.** Not everybody who can find the room: a device proves who it is with its key, and the key has to be one that was
  written, by its owner, into the shared folder (`p/<device>`, with the device's public key). Only people who may **write** in the share have a
  file there, so a person who may only view - who can read the secret too - is turned away by the proof, as a device that is not paired is. (A
  person who may only view gets what the others write at the next sync, as before.)
* **It is not secret from the service.** The secret is in a file of the share, which the service can read like the notes; it could in principle
  listen in on a live session, as it can read the files. This is the same trade as the unsealed files, for the same reason.
* **When it ends.** As with one person's devices: when the host is left alone the note is saved and the share is synced (so those who were not in
  it get it), and the note then counts as agreed with the people who were in it, so the copies that follow - each saved at its own moment - are
  not taken for a change made on both sides (no "from before the sync" copy).
* **One kind of session at a time.** A note that already has a live session of another kind on this device (with the person's own devices, or
  with a link copy) is left to that one: it is not offered in the room of the share until that ends. A person who is in both circles on one
  note is in one session at a time.
* A share made before this existed gets its secret the next time it runs: the owner makes it, the others read it from the folder.

"Sync now" in the top bar also runs the shares; coming back to the front, or a change of network, brings the rooms and the shares up to date as
for the cloud sync; and opening a note looks for a newer copy of it in its share.

## Limits (by design, for now)

* The same service on both sides; Nextcloud users on different servers need the service's federation, which this does not try to set up.
* The list of shares is part of the profile sync (`native_shares`, last change wins per share, an ended share is ended on every device):
  a second device of the same person knows the shares and takes part in them with its own directory in the shared folder. It needs the
  cloud account (handed over between the devices as for the cloud sync) and the notes (which the profile sync brings).
* Live co-editing needs the signalling server like the one between a person's own devices, and works between people who may write; the
  viewers are brought up to date by the sync (see above). The sessions of [link copies](../README.md) are separate.
* Notes that are locked are never shared. A note that becomes locked in a shared folder stays where it was published.
* Deleting a note in a shared folder deletes it for everyone who takes part, like deleting it on one's own other device.

## The code

| File | |
|---|---|
| `nativeshare/native_share_provider.dart` | the interface to a service, people, roles, the errors |
| `nativeshare/nextcloud_shares.dart` | the Nextcloud provider |
| `nativeshare/share_model.dart` | a share, its people, its state; storing them |
| `nativeshare/native_share_service.dart` | sharing, receiving, stopping, and the runs (like `CloudSyncService`) |
| `nativeshare/shared_folder_sync.dart` | one run of one share: the participants, then `FolderSync` on the scoped library; the quick run |
| `nativeshare/scoped_library.dart`, `share_scope.dart` | the library as the share sees it, and which notes and folders belong to the share |
| `screens/share_people.dart` | *Share with a person* (note, folder) and *Shared with people* (settings) |
| `devicesync/sync_library.dart` | `SyncLibrary.sharing`: a library that shares the other's books of what is being written |
| `cloudsync/folder_sync.dart` | the sync of a folder (used by both) |

## What is built

* **The sync of a share** (`SharedFolderSync`, `ScopedSyncLibrary`, `ShareScope`): the folder sync (`FolderSync`) takes an explicit list of
  participants, a prefix for the settings it keeps, plain files only, and a switch for not publishing. A share runs it on the scoped view
  of the library. Tested with two people against a fake service: both ways, view-only, folders and sub folders, moved out and deleted,
  the end of a share, and a participant publishing what it should not (an id that is here already, a note outside the folder, a deletion of
  something else, settings, a participant file in another device's name). Several of these were checked by breaking the guard and watching
  the test fail.
* **The shares themselves** (`NativeShareService`, `share_model.dart`, tables `native_shares` and `native_share_items`, schema 32): give a
  note or folder to a person with a role, add and remove people, change roles, stop; find what was given to the person (or add it from a
  link), accept it into a folder of their choice, leave; the runs (every few minutes, after a change, on request, and when a note of a
  share is opened) and what is shown of how they went. A share whose note or folder id is one the person has already is refused (it would
  publish their own note) - unless they left that very share before, from the same person: then they return to it with what they have.
* **The same on every device of a person:** the list of shares travels with the profile sync (see Limits).
* **Live editing and the rest of what the cloud sync does:** a note of a share that is open on two people's devices is worked on live (above);
  opening a note looks for a newer copy in its share; "Sync now", coming back to the front and a change of network include the shares; the
  dashboard reloads when a share run ends. Tested with real live sessions over a fake signalling server (`test/nativeshare/share_live_test.dart`),
  including that a viewer is turned away and that no conflict copy is left after a session.
* **In the app:** *Share this note with a person* in the live panel of a note, *Share with people...* in the menu of a folder, *Shared with
  people* in Settings → Sharing and files (shares waiting, accept into a folder, add a link, how each share is going, stop or leave), the
  group symbol on shared notes and folders, and the automation event `shareReceived`. A service that has an account but cannot share with
  people says why instead of being left out. German texts.
* **Nextcloud**, **OneDrive**, **Dropbox** providers (`NextcloudShares`, `OneDriveShares`, `DropboxShares`). Nextcloud was also run
  against a real Nextcloud 34 (see above); OneDrive and Dropbox against fakes of their APIs written from Microsoft's and Dropbox's
  documentation (`test/nativeshare/fake_graph.dart`, `fake_dropbox.dart`).

## What is left

* **Check OneDrive and Dropbox against the real services.** Nothing here has touched a real OneDrive or Dropbox: it needs a Microsoft app
  registration with `Files.ReadWrite.All` and a Dropbox app registered with "Full Dropbox", each with two accounts. The things most likely
  to differ: whether `invite` on a folder of the app's folder answers with `shareId` (the address of the folder is the fallback, which
  relies on the shares API accepting it), whether `/shares/<id>/permission` tells the rights of an invited person (when it does not, the
  person is taken as a viewer and cannot publish), and how long Dropbox takes to show a new member.
* **ownCloud and older Nextcloud versions** are untried.
* **Unsealed by design.** An option to also seal a share with a key sent in the invitation (so that the service could not read it) is not
  built.
