import 'model_pins_data.dart';

/// Models that other people publish on Hugging Face are fetched from the commit that was looked at, not from `main`, and each file has
/// to hash to what that commit holds (`model_pins_data.dart`, made from the Hugging Face API). A repository that is changed or taken
/// over later cannot hand the app a different model: the download of such a file fails. A model that is wanted from a newer commit is a
/// new row in the table (`tool/pin_models.py` makes it).
const _prefix = 'https://huggingface.co/';

/// Where to fetch [url] from and what it has to hash to; [url] itself and null for an address that is not a file of a repository on
/// Hugging Face's `main` (the ones that are ours pin their files in their own service). Throws [StateError] for a file of a repository
/// in the table that the table does not know: it is never fetched unchecked.
({String url, String? sha256}) pinnedDownload(String url) {
  if (!url.startsWith(_prefix)) return (url: url, sha256: null);
  final rest = url.substring(_prefix.length);
  final at = rest.indexOf('/resolve/main/');
  if (at < 0) return (url: url, sha256: null);
  final repo = rest.substring(0, at), path = rest.substring(at + '/resolve/main/'.length);
  final pin = pinnedRepositories[repo];
  if (pin == null) return (url: url, sha256: null);
  final sha = pin.files[path];
  if (sha == null) throw StateError('$path of $repo is not one of the pinned files.');
  return (url: '$_prefix$repo/resolve/${pin.revision}/$path', sha256: sha);
}
