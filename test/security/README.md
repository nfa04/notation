# Security tests

Every attack we know of, and the test that shows it does not work. They all run with the normal `flutter test` (so CI runs them on
every change); `tool/security_tests.sh` runs only these, which is quick after touching sync, sharing or note import.

**When you fix a security problem, add its test here (or list it below) first, and check that the test fails without the fix.**
**When you add a way for outside data to reach the app (a new message, file, link or address), add an attack test for it.**

| Attack | Test |
|---|---|
| Joins the room of a profile without the secret; wrong, replayed or other-room proof; flooding; huge or binary frames; room squatting and room-count exhaustion | `test/collab/signaling_test.dart`, `signaling_limits_test.dart` |
| A device that knows the secret but is not of the profile floods the others with offers, candidates or huge descriptions to use up memory | `test/security/room_member_flood_test.dart` |
| A link to a shared copy leads to this device or a private network (also through redirects), or to a file so big it fills memory | `test/security/shared_link_download_test.dart` |
| A cloud service sends the app on to another server, and the login goes along | `test/security/redirect_credentials_test.dart` |
| Reads what the signalling server relays (note ids, device ids, sizes, same message twice) | `test/devicesync/sync_room_privacy_test.dart` |
| A device that is not on the list gets notes (no link on offer; claims another device's id; other secret) | `test/devicesync/sync_session_test.dart`, `test/security/peer_data_attacks_test.dart` |
| Man in the middle of the direct connection (other certificates), also while pairing; grinding the six digits | `test/devicesync/sync_session_test.dart` |
| A removed device comes back; an old device list re-adds it | `test/devicesync/sync_session_test.dart`, `sync_keys_test.dart` |
| A locked note is sent or published | `test/security/peer_data_attacks_test.dart`, `test/nativeshare/shared_folder_sync_test.dart` |
| A shared folder's manifest overwrites a private note, deletes outside the share, changes settings, takes over a folder id; a participant file claims another's id | `test/nativeshare/shared_folder_sync_test.dart` |
| Files in the cloud folder: not sealed with the key; sealed files swapped between names by the storage provider | `test/cloudsync/folder_sync_test.dart` |
| A peer's picture, folder picture or sound names a path outside the app folder (id or extension) | `test/collab/collab_service_test.dart`, `test/hostile_input_test.dart`, `test/security/peer_data_attacks_test.dart` |
| A note file with a zip bomb, too many files, damaged parts, a made-up page count | `test/hostile_input_test.dart` |
| A note from someone else loads pictures from the web (tracks you, reaches your local network) or reads files of this device | `test/security/untrusted_note_content_test.dart` |
| The web clipper or an extension fetches a local or private address, also through a redirect or a name that resolves to one | `test/capture_private_hosts_test.dart`, `test/extensions/service_test.dart` |
| A link `notation://capture?file=` reads a file outside the cache; an extension zip writes outside its folder | `test/capture_link_test.dart`, `test/extensions/service_test.dart` |
| An imported note replaces a different local picture of the same name | `test/import_document_images_test.dart` |

Not covered by a test (known limits, see `docs/profile-sync.md`): a device that is on the list is trusted; the signalling server sees
that a device is online; a rolled-back manifest in the cloud folder is not noticed; the name lookup of the web clipper can be raced
(DNS rebinding); a member of a room can send the frame the server answers a relay request with, and so name a relay (it sees only sealed bytes; closing this needs a change of the signalling protocol).
