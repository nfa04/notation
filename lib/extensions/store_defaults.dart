/// Where the extension store is (github.com/nfa04/notation-extension-store, a small PHP server: see its README to deploy one) and who
/// signs its catalogue.
///
/// The store the app uses unless the person picked another one (Settings, Extensions, Advanced).
const String builtInExtensionStore = 'https://store.notation.noelaeby.me';

/// The public keys (base64 of the 32 bytes of an Ed25519 key, `store.pub` of the store repository) that may sign the catalogue. More
/// than one so that a key can be replaced: ship the app that knows both, then sign with the new one.
const List<String> extensionStorePublicKeys = ['yO5XN/3ZZE0Zxe3pk21xhnJXKY4v8hdwmGVpdYKmpVA='];

/// The address in use: `--dart-define=NOTATION_STORE_URL=https://localhost:8443` points a test build at a local store (the store repository's
/// `deploy/dev.sh`), otherwise [builtInExtensionStore].
const String extensionStoreAddress = String.fromEnvironment('NOTATION_STORE_URL', defaultValue: builtInExtensionStore);

/// For a test build only: a PEM file whose certificate the store client trusts as well (`--dart-define=NOTATION_STORE_CERT=/path/cert.pem`), so
/// that a local store with a self-signed certificate can be reached. Empty in every normal build.
const String extensionStoreCertFile = String.fromEnvironment('NOTATION_STORE_CERT');
