/// The signalling server that live sessions use unless the person chooses their own
/// (Settings → Live collaboration). Put the address of your deployed server here, with `wss://`:
/// for the Cloudflare Worker (github.com/nfa04/note-signaling-cf-worker) that is
/// `wss://uninotes-signaling.<account>.workers.dev` (or your own domain on it).
///
/// Empty means there is no built-in server, and each person has to enter one.
const String builtInSignalingServer = 'wss://uninotes-signaling.noel-aeby.workers.dev';

/// The app registration at Dropbox (https://www.dropbox.com/developers/apps): "Scoped access", with the permissions files.content.write,
/// files.content.read, files.metadata.read, sharing.write and sharing.read, and `notation://oauth/dropbox` as the redirect URI. Empty
/// means Dropbox is not offered.
///
/// The access type is "App folder" (the app sees only its own folder; enough for link copies and the sync) or "Full Dropbox". Sharing a
/// folder with other people needs **Full Dropbox**: an app folder app can neither share its folder nor reach what is shared with the
/// person, and the access type of an app cannot be changed afterwards, so it is a registration of its own. Set [dropboxFullAccess] when the
/// key above is such a one.
const String dropboxAppKey = '';

/// Whether [dropboxAppKey] is an app with the access type "Full Dropbox" (see above): then sharing with people is on from the start.
const bool dropboxFullAccess = false;

/// The app registration at Microsoft (Azure portal, App registrations): "Personal Microsoft accounts" (or any), a
/// "Mobile and desktop" redirect URI `notation://oauth/onedrive`, and the delegated permissions Files.ReadWrite.AppFolder
/// and offline_access. Empty means OneDrive is not offered.
const String oneDriveClientId = '';
