import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The licences of what is in the app but not in a package of pub (those, and Flutter itself, are collected by Flutter):
/// the fonts of the assets and the native libraries the plugins download when the app is built. The texts are the ones
/// that came with them (assets/licenses/, assets/fonts/). When a plugin brings another library, add its text here.
const bundledLicenses = <({String package, String asset})>[
  (package: 'DejaVu fonts', asset: 'assets/fonts/DejaVu-LICENSE.txt'),
  (package: 'Liberation fonts', asset: 'assets/fonts/Liberation-LICENSE.txt'),
  (package: 'PDFium (and the libraries in it)', asset: 'assets/licenses/pdfium.txt'),
  (package: 'ONNX Runtime', asset: 'assets/licenses/onnxruntime.txt'),
  (package: 'ONNX Runtime', asset: 'assets/licenses/onnxruntime-third-party.txt'),
  (package: 'WebRTC', asset: 'assets/licenses/webrtc.txt'),
  (package: 'flutter_webrtc', asset: 'assets/licenses/flutter_webrtc-NOTICE.txt'), // (its NOTICE file: Flutter only collects LICENSE files)
  (package: 'QuickJS', asset: 'assets/licenses/quickjs.txt'),
  (package: 'GLM-OCR (its vocabulary, and the model the app downloads)', asset: 'assets/licenses/glm-ocr.txt'),
  (package: 'TexTeller (its vocabulary, and the model the app downloads)', asset: 'assets/licenses/texteller.txt'),
  (package: 'Pix2Text-MFR (its vocabulary, and the model the app downloads)', asset: 'assets/licenses/pix2text-mfr.txt'),
  (package: 'Mozilla CA certificate list', asset: 'assets/licenses/mozilla-ca-bundle.txt'),
];

/// Adds [bundledLicenses] to the licence page of Flutter (the texts are read when the page is opened).
void registerBundledLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final l in bundledLicenses) {
      yield LicenseEntryWithLineBreaks([l.package], await rootBundle.loadString(l.asset));
    }
  });
}
