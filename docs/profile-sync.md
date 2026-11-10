# Profile sync: one person, several devices

What a person sees: *Settings → Sync profile* (and the first screen of the app). A second device is added with a link; from then on the devices share the id and name, the notes and folders, and the settings that are about the person rather than the device. Code: `lib/devicesync/`, UI in `lib/screens/sync_settings.dart`.

## What is shared

| Shared | Not shared |
|---|---|
| id and name of the profile | servers, accounts, calendars (CalDAV/phone/ICS), passwords, API keys |
| notes (every kind, as note files) with folder, star and trash state | locked notes |
| folders (name, colour, order, nesting, banner picture up to 8 MB; a note's own picture travels in its file) | the choice of AI model, downloaded models |
| the graphs that were made and kept (the tabs of the Graph screen: name, kind, folder, picture; the newer of two copies wins, see [graph-architecture.md](graph-architecture.md)) | the facts the AI wrote of each note (they are made again from the notes when needed) |
| settings about looks and behaviour (`syncedSetting` in `sync_library.dart`), and the list of notes and folders shared with other people (`native_shares`, see [native-sharing.md](native-sharing.md)) | tasks (they have their own sync with CalDAV), templates |

## Secrets and who can do what

* **Profile secret** (32 random bytes): made on the first device that offers a link, carried in the link after the `#`, kept in the system's secure storage. Everything shared is derived from it by HKDF: the *room* on the signalling server, the key that seals messages, and the key of the pairing code. Knowing the secret is **not enough** to be part of the profile.
* **Device secret** (an Ed25519 private key, made on each device and never sent anywhere, kept in the secure storage). Its public key is on the *list of devices* that every device of the profile holds. Whoever is not on the list cannot sync, even with the profile secret.
* **Adding a device** needs a person: the new device comes with the link, both devices show the same six digits (made from the secret, both public keys and a random number from each side, so a device in the middle shows different digits to each side), and the person on the device that made the link says yes. The new device's key is then put on the list, which the other devices learn at their next sync.
* **Every meeting** of two devices starts with a mutual proof: each signs the room, both ids and both fresh random numbers (and its own id, so a signature cannot be reflected) with its device secret; the other checks it against the key on its list. A device that was removed from the list (or whose id is used with another key) is refused.
* **Removing a device** puts a removal on the list; it spreads to the others. *Leaving the profile* forgets the secret and the list on that device only.

A device that signed in through a cloud folder (see below) was never linked, so it has no signalling server of its own: the sign-in file carries the one the profile's first device uses (inside the sealed part), and a device without one falls back to the server in its live collaboration settings. If the two devices use different servers they never meet in a room, and a live session on a note cannot start; set the same one on both.

## On the signalling server

The server keeps the room `/sync/<room>` where `<room>` is the hash of a public key made from the profile secret. A device has to answer a fresh challenge with a signature of the matching private key before it is let in (and before it can hear or be heard), so nobody without the secret can squat the room, flood it or even see who is in it. The server learns only that *a device that has the secret* is connected, and when. That is why the automatic sync is **opt-in** ("Keep my devices in sync automatically"): while it is on, the device stays in its room; while it is off, the device only connects while a link is on offer, while one is being used, or for two minutes after pressing "Sync now". Protocol and limits: `tool/signaling/README.md`. All three servers (Cloudflare Worker, Node, Dart) implement it and pass the same conformance tests (`test/collab/signaling_test.dart`). An idle room costs nothing on Cloudflare (hibernating object; the keep-alive `ping` is answered by the runtime).

Devices in a room say `here` every 45 s (and when they arrive), with whether they sync their notes now (a device that is only there for a note it works on live, with the automatic sync off, does not, and is not synced with: it turns such a meeting away); the one with the **lower id** opens a WebRTC connection to the other (`peer_linker.dart`, offer/answer/ICE as sealed messages in the room); a device with the higher id that has something new sends a `poke` so that the other connects. Each connection has an id of its own, so two devices can have several at once (a sync while a note is worked on live) and making one never closes another. The data then goes directly between the devices (or through a TURN server if one is configured, which only sees sealed bytes), and the server is not used for it.

## What happens in a meeting (`sync_session.dart`)

1. Hello, proof (above), and pairing if the other device is new.
2. The lists of devices are merged.
3. Each side sends a *manifest* (a line per folder, note, graph, synced setting and deletion; no content) and works out what it wants from the other (`SyncLibrary.plan`): newer replaces older; a note whose place changed (folder, star, trash) is compared on its own so that moving a note does not look like editing it; when both sides changed the same thing the device with the lower id wins on both sides.
4. Each side asks for what it wants and is sent it (notes as `.uninote` files, which carry everything in a note, including what the AI made of it). A note that was **edited on both devices** since they last agreed (`sync_marks`) is replaced by the newer one and the older is kept as "Title (from before the sync)", so nothing is lost. A note that is **open in an editor** is skipped until the next sync.
5. Deletions travel as tombstones (`sync_tombstones`, written when a note or folder is deleted for good); a note edited after the deletion on another device is kept and comes back.

Syncs are run: when a device appears in the room, when something was saved (after 20 s), every five minutes, and on "Sync now".

## What the signalling server (and Cloudflare in front of it) can see

| Visible | Why it has to be | What was done to say as little as possible |
|---|---|---|
| That a connection to `/sync/<room>` exists, when it opens and closes, how many are in the room | It relays between them | The room is named after a key that **changes every day** (made from the secret and the date, UTC), so it cannot tell that the same profile came back tomorrow or learn its usual hours from the name; the devices move to the next day's room at midnight |
| The IP address of each device | Any server sees it | Not avoidable without a VPN or a server of your own (`Settings → Live collaboration → My own server`) |
| The public key of the room and a signature | To check that the device knows the secret | Both are one-way: the key says nothing of the secret, and the signature is made for one challenge only |
| The size and timing of the frames | It relays them | Every message is **padded to a multiple of 4096 bytes** before it is sealed, so a greeting, an offer and a connection candidate look alike; keep-alives are a bare `ping` |
| Nothing else: device ids, names, notes, settings, even the kind of message | - | Everything is sealed with XChaCha20-Poly1305 under a key made from the profile secret, which the server never gets. The notes do not pass the server at all (they go over the direct connection, which is encrypted again by WebRTC) |

Also seen by others: the STUN servers used to find a way through a router (`defaultIceServers`) learn the public address of a device when it sets up a direct connection; they see nothing else. A TURN server, if one is added, relays bytes that are sealed twice.

## Someone who tries to get their own device in: what was checked

Assume the attacker may have the link (the profile secret leaked), may sit on the path to the signalling server, or may run the server.

| Attack | What stops it |
|---|---|
| Connects to the room without the secret | The server asks for a signature that only the secret can make; the room is named after the matching public key. Nothing is relayed to or from a device that has not proven it. |
| Has the secret, connects as a new device | Not on the list of devices: refused, unless a link is on offer; then the person on the device that made the link must say yes after comparing six digits. The link works for ten minutes, for one device (it stops being offered after a device joined), and at most three requests wait for an answer at once. |
| Has the secret, uses the id of a device on the list | Its key is not the one on the list: refused. With the right key it would still have to sign a challenge it cannot know. |
| Replays what it recorded | Each meeting signs fresh random numbers of *both* sides, the room, and who signs, so nothing can be replayed or reflected. |
| Has the secret and **sits in the middle of the connection** (the signalling carries the WebRTC offer and answer, so it could put in certificates of its own and relay everything) | The proofs and the six digits include the certificate fingerprints of both ends as each end sees them (`PeerChannel.binding`). With a device in the middle the two ends see different ones, so the proofs fail and the digits differ. |
| Same, while a new device is paired, choosing its random number and key to make the six digits come out the same on both screens | Each side first sends only a hash of its number and key, and reveals them after it has the other's hash: nothing can be chosen after seeing the other side's. Guessing is left: one in a million. |
| A device that answers the link and is not the person's (the new device joins the wrong one) | The new device shows the digits and asks "is it the same?"; until the person says yes nothing is taken over, no note imported and no profile adopted. |
| Pretends to be many devices, or keeps connecting | Attempts per device are spaced out after failures (5 s doubling to 5 min); at most 64 devices are remembered per room. |
| Has been removed | Taken off the list and refused by every device; it still knows the secret and can sit in the room (the server cannot tell), but nobody talks to it. Rotating the secret is not offered yet. |
| Adds itself back by sending an old device list | A removal later than the addition wins in the merge, and a known id never takes another key. |
| Reads the secrets off this device | The profile secret and the device secret are in the system's secure storage (Keystore / Keychain / libsecret), not in the database. |

What is **not** protected: a device that is on the list is trusted (it may change or delete any note, and add other devices); if the person says yes to the wrong device after not comparing the digits, it is in; and the signalling server (or Cloudflare) sees that a device with the secret is online when it is.

## Looking for the other devices

Three levels, the person's choice: *nothing* (only "Sync now"), *from time to time* (the device joins the room for a minute when the app starts, comes to the front, and every ten minutes, and syncs if another device is there; the server learns only of these visits), and *always connected* ("Keep my devices in sync automatically"). Two devices that only look from time to time meet when their visits overlap; one that stays connected is always found. While the sync settings are open the status is asked again every 30 seconds. The sync through a cloud folder runs beside this, for devices that are not online at the same time; it does not take the device out of the room. What needs the signalling server: joining the profile, handing over an account, the automatic sync, and working on one note on two devices at the same time (see "Live sessions between the devices"). The folder sync itself never uses it. The settings say so next to each switch. Switching the folder off, renaming it or changing the service takes effect at once: the run that tells the other devices in the old place goes on in the background, after the run under way.

## Limits of this version

* Syncs whole notes: a note edited on two devices at the same time ends up as two notes, not merged text.
* A removed device that still has the profile secret can sit in the room (the server cannot tell), but no device talks to it. Rotating the secret is not offered yet.
* Folder banner pictures, tasks, templates and styles are not synced.
* Where direct connections are blocked, a TURN server is needed (as for live sessions).

## Working on one note live on two devices

With "Keep my devices in sync automatically" on, each device tells the others (in the sealed room messages, `here`) which notes are
open on its screen. When a note is open on two devices of the profile, the one with the lower id hosts a live session on it
(`CollabService.startOwnHosting`) and the other joins (`joinOwn`) - the same live sessions as for sharing with others, so
cursors, the page markers and merging work as they do there. What is different is how the devices find each other and who is let in:

* The line is the direct connection between the two devices. `SyncSession` runs its usual first steps on it (each device proves
  its device key over the connection's fingerprints), and only a device that is on the list of the profile is served. The host then
  sends the secret of its session over that proven line, and the line is handed to the live session (`LiveLink`), which seals its
  traffic with that secret on top. Nothing about the session goes through the signalling server, and nobody has to say yes.
* The guest's note and the host's note are merged as for a copy that is opened again after a break: what was drawn or typed on
  either since they last synced stays.
* Closing the note on a device ends its part; if the line is lost the guest connects again (a proven line each time).
* The server learns nothing more than before: which notes are open is only said inside the sealed room messages.

## When the connection drops

A sync over a direct connection can be cut at any point. What keeps it consistent:

* Nothing is half-taken: a note is taken in as a whole, and each note counts as agreed with the other device **as soon as it is taken**
  (not only at the end), so the next meeting does not mistake it for a change made here and does not keep a "from before the sync" copy.
  At the end, only the notes that are the same on both count as agreed: one that was not exchanged (it was open in an editor) does not,
  so that a change made on top of it later is still told from a change made on the other device.
* Taking in a note is one at a time for each note: a sync through the folder and a direct one that bring the same note at once each see
  what the other left.
* Both sides work from the lists (manifests) again at the next meeting, so what was missed is asked for again and nothing is taken twice.
* A device that is silent for 90 seconds in the middle of an exchange is given up on; a failed sync is tried again by itself after a
  growing pause (5, 10, 20, 40 s ..., four times), and when the connection to the signalling server comes back the devices look for each
  other again.
* A live session over a lost connection is joined again by the guest, with a proven line each time.

(`test/devicesync/sync_session_test.dart` cuts the line after every third message and checks that the next meeting finishes the job.)

## Cloud accounts

The cloud accounts of the app (Nextcloud, S3, Dropbox, OneDrive) are handed from one device to the other at the end of a direct sync
(`SyncedAccounts`, `AppAccounts`): the newer change of each account wins, and removing an account removes it on the other devices. They
travel only over the proven, sealed line between two devices of the profile - never through the signalling server and never into a cloud
folder. For Dropbox and OneDrive the refresh token goes (and the app registration if you entered your own); each device asks for its own
short-lived token. Microsoft may replace a refresh token each time it is used; if two devices fall out of step, sign in again on one.
Dropbox now also asks for the permission to read files and list the folder: sign in again once after the update.

## Sync through a cloud folder

For devices that are never online together. *Settings → Sync profile → Sync through a cloud folder* (the choices - on, service, folder
name, encrypted or not - are settings of the profile and reach the other devices like the rest). Code: `lib/cloudsync/`.

* **One writer per file.** Each device writes only its own directory in the folder and reads those of the others, so two devices never
  write the same file. A directory holds the **manifest** (the same lines as for a direct sync), the note files (`n/<id>.<version>`;
  named by version, so a manifest always points to complete files) and the folder pictures.
* **A run** takes in what the others published (the same plan as for a direct sync: newer replaces older, changes on both sides keep
  both, deletions travel, open notes are left alone), then publishes: new files first, the manifest last, old files after that. A run
  that is cut leaves the old manifest and the files it points to in place; the next run finishes. A single note that will not upload (or
  will not be taken in) is reported and left out of the manifest for that run; it does not hold the others back. Runs happen when the app
  starts or comes to the front, every three minutes, half a minute after a change (and again soon after a run during which something
  changed), and on "Sync through the folder now".
* **Encrypted** (default): every file is sealed with a key from the secret of the profile (XChaCha20-Poly1305) and the names are
  keyed hashes, so the cloud holds files nobody can read and learns only how many and how large. **Not encrypted**: the manifest is
  JSON and the notes are `.uninote` files, readable by anyone who can see the folder (but also openable by you). A run reads either kind;
  switching rewrites the files and removes the old kind. In the directory of a device that seals, a file that does not open with the key
  of the profile is refused: whoever can write to the folder cannot put notes (or devices) there. Each sealed file is also tied to the place it is stored at, so the storage provider cannot put one file under another's name (files from before this open without the tie and are tied when they are next written). Not covered: it can still give back an older complete state of the folder.
* **Tries again.** A service that answers "slow down" (429, 503...) or a connection that drops for a moment does not end a run: each request
  is tried again after 1, 4 and 10 seconds (`RetryingFolder`); a "no" (login, storage full) is not.
* **Moving the sync.** The service and the folder name are settings of the profile, so the other devices learn of a change from the
  folder they are using. Before the change takes effect, one more run is made in the old place (with the new choice written), and the
  other devices follow when they read it. What was published somewhere else does not count as published in the new place: it all goes up
  again. Switching the sync off is announced the same way. A device that gets the sync switched on (or moved) by another device makes a
  run soon after, and so does the app after it starts.
* **Services**: Nextcloud (WebDAV), S3-compatible storage, Dropbox, OneDrive (`CloudFolder`; each is an implementation in its
  storage's file). The Dropbox and OneDrive ones are tested against stand-ins of their APIs, not the real services. Dropbox's headers carry
  the path as ASCII escapes, so a folder called "Notizen für Uni" works.

## Signing in with the cloud folder (opt-in)

For a new device, or a browser, where nobody can scan a code or press "yes" on another device: *Settings → Sync profile → Sync through a
cloud folder → Let me sign in with this folder*. Off by default; the link pairing above stays as it was and stays the careful way. Code:
`lib/cloudsync/cloud_sign_in.dart`, UI in `lib/screens/cloud_sign_in_ui.dart`.

**What the person does.** On a device that is in: switch it on (it explains the trade-off first), and keep the **recovery key** that is
shown once (25 characters, `ABCDE-FGHJK-MNPQR-STUVW-XY234`; the app does not keep it). On the new device (first screen, or the sync
settings): *Sign in with your cloud folder* - choose the service, connect the account if it is not connected, check the folder name, type
the key. The notes come over the usual folder sync; the profile id and name are taken over.

**What is in the folder** (a directory `_profile` next to the directories of the devices):

| File | Holds | Who can read it |
|---|---|---|
| `b` (bootstrap) | the secret of the profile, with the id and name of the profile, sealed (XChaCha20-Poly1305) with a key HKDF'd from the recovery key; next to it, in the clear, the *verifier* (a public Ed25519 key made from the recovery key), which is also what the sealed part is tied to | only someone with the recovery key can open the secret |
| `j-<hash>` (one per device) | an **endorsement**: "this id, this public key, this name, added at this time", signed with the private key the recovery key makes; sealed with the key of the profile | devices of the profile; the service sees a name that says nothing |

There is no slow key stretching: the key has about 123 random bits, so there is nothing to guess offline. A wrong or mistyped key does not open the
file (the person is told so, and nothing on the device changes).

**How a device gets in.**

1. The new device opens `b` with the key and takes over the secret, the profile id and name. It starts a list of devices with itself on it, writes its own
   endorsement and reads the others' (a device accepts an endorsement only if the signature checks against the verifier from `b`).
2. It learns who else is in, and who was taken out, from the lists the endorsed devices published in their manifests; a device that another one lists as removed is not asked
   about who else is in. Only then the first run of the folder sync reads the other devices.
3. The devices that were in already look for new endorsements at the start of every run of the folder sync (one listing; files already looked at are skipped by name). The verifier is a
   setting of the profile (`sync_signin_verifier`), so it reaches them sealed through the usual sync and not from the folder: whoever runs the folder cannot swap it. An endorsement that checks
   adds the device to the list, and the devices list it as *signed in with the recovery key*. Removing it works as for any device.
4. Turning it off writes an empty verifier (it reaches the other devices like any setting) and takes `b` and the endorsements out of the folder. A new key (*Make a new recovery key*) rewrites `b`
   and the endorsements and changes the verifier: the old key stops opening `b` and stops being able to endorse a device.

**What was checked** (`test/cloudsync/cloud_sign_in_test.dart`, `cloud_sign_in_ui_test.dart`):

| Attack | What stops it |
|---|---|
| Reads the folder (the service, or anyone with its files) | `b` is sealed with a key from the recovery key; the endorsements are sealed with the key of the profile. It sees that a Notation sign-in exists and how many devices there are |
| Swaps the verifier in `b` for its own | The sealed part is tied to the verifier (authenticated data): it no longer opens |
| Has the profile secret (a device that was removed) and wants back in | It cannot make an endorsement that checks: that needs the private key of the recovery key. A removal stays: the endorsement it made earlier is not newer than the removal |
| Has the recovery key, but not the folder | Nothing to open |
| Has the recovery key **and** the cloud account | Gets in. That is the trade: this replaces the person's yes on another device. The devices show it and it can be removed |
| A device signs in again after it was taken out | Its new endorsement is later than the removal: it is let back in. (It has the key; the person who removed it knows it is there again from the list.) |

**What it does not do (yet).**

* **No rotation of the profile's secret.** Removing a device, or making a new recovery key, does not change the secret: a device that already had it keeps being able to read the files in the folder. Changing the
  secret would have to reach every remaining device sealed for each of them (the device keys sign only), which is not built. The same gap exists for link pairing.
* A new key reaches a device that had not yet looked at an endorsement made with the old key only through the list of another device that had; otherwise that device signs in again.
* The folder is found by name: the new device uses the name the person types (default `Notation Sync`).
* The Nextcloud account is connected with *Log in with the browser* (Nextcloud's Login Flow v2: the app gets an app password of its own, `lib/sync/nextcloud_login_flow.dart`); entering an app password by hand still works.
* On the web, the service must allow cross-origin requests: Dropbox and OneDrive do; a Nextcloud needs the headers in [nextcloud-on-the-web.md](nextcloud-on-the-web.md); S3 needs a CORS rule on the bucket.

## Live sessions between the devices

The meeting room on the signalling server is the one place where the devices of a profile learn which of them are online and which notes
they have open; the cloud folder only carries the library.

* **Who is in the room.** A device is in the room while the automatic sync is on, and also while a note is open and "Work on a note on two
  devices at the same time" (`sync_live`, on by default) is on. With the automatic sync off, a device that is there only for an open note
  does not sync the library; closing the last note takes it out of the room.
* **What it says.** Every 45 seconds, and at once when the open notes change, a device says it is there and which notes it has open (at
  most 12). With `sync_live` off it does not say which notes are open.
* **What the server learns.** Every message in the room is sealed with a key from the secret of the profile (XChaCha20-Poly1305) with a
  random nonce of its own, and padded to 4096 bytes. The server sees neither the ids of the notes nor of the devices, cannot tell that the
  same note is opened again (the same message never looks the same twice), nor how many notes are open. The name of the room changes every
  day. What it does see: that devices of one profile are connected, from which addresses, and when they send something (a note opened or
  closed makes a message at once).
* **Who hosts.** A note that is open on two devices that are online is worked on live: the device with the lower id hosts, the other
  connects to it directly (WebRTC, set up through the sealed room), proves who it is as in a sync, and is handed the key of the session over
  that line. The session never shows up at the server as a room of its own.
* **The host changes.** The host is always the device with the lowest id among those that have the note open, as the room sees them.
  When that changes - the host closed the note or went away (its session ends on the guests, quietly), or a device with a lower id
  opened it - every device works it out again: the new host starts a session, and a device that hosts or follows another one leaves
  that session and joins the new host. So there is one session per note, also after leaving and opening the note again. The same is
  worked out again when a session ends, when a device that went without a word is taken for gone, and when the connection to the server
  is back.
* **A device that goes without a word** (its app was killed, its network vanished) is noticed within seconds, not after it misses its
  signs of life (about two minutes): the server tells the room that *a* connection closed - not whose - and closes one that was silent
  for 70 seconds the same way. Every device then asks who is still here, and one that does not answer within five seconds is taken for
  gone. A guest that cannot reach its host asks the same.
* **When nobody else is left.** The host saves the note and, with the cloud folder on, runs a sync through it. Every device counts the note
  as agreed with the devices that were in the session when it ended (`SyncLibrary.markNoteAgreed`), so that the copies that follow are
  not taken for a change made on both sides. A device that was not in it, or left before the end, may have changed the note meanwhile:
  it does not count as agreed with it.

