import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart' show rootBundle;

/// Where the bundled list of root certificates is (Mozilla's, see assets/certs/README.md).
const bundledRootsAsset = 'assets/certs/ca-bundle.pem';

Future<void>? _loading;

/// Makes the app trust Mozilla's list of root certificates as well as the ones the system hands over.
///
/// On Windows the roots come from the certificate store, and Windows fills that store lazily: a root it has not needed yet is not
/// in it, and Dart's TLS does not ask Windows to fetch it. So a machine that has never seen, say, Amazon's root fails a download
/// from Hugging Face with `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`, while the browser (which does ask)
/// works. Only Windows has this, so nothing is added elsewhere (the other systems keep deciding who is trusted).
/// Added to [context] (the default one for the whole app when none is given), once.
Future<void> trustBundledRoots({bool? onlyOnWindows, SecurityContext? context}) {
  if (kIsWeb) return Future.value();
  if ((onlyOnWindows ?? true) && !Platform.isWindows) return Future.value();
  if (context != null) return _add(context);
  return _loading ??= _add(SecurityContext.defaultContext);
}

Future<void> _add(SecurityContext context) async {
  try {
    final data = await rootBundle.load(bundledRootsAsset);
    context.setTrustedCertificatesBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  } catch (e) {
    // (a certificate the context already has is no reason to give up on the others, and no reason to stop the app)
    debugPrint('The bundled root certificates could not be added: $e');
  }
}
