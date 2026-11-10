import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

import '../devicesync/sync_link.dart';
import '../l10n/text.dart';

/// Whether this platform can scan a QR code with its camera (the scanner has no macOS version: there the link is pasted).
bool get canScanQr => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Opens the camera and returns the first QR code that holds a link to add a device (null when the person goes back).
Future<SyncLink?> scanSyncLink(BuildContext context) => Navigator.of(context).push<SyncLink>(MaterialPageRoute(builder: (_) => const ScanLinkScreen()));

/// Opens the camera and returns the first QR code that is the code of a browser that wants to be connected for a while (null when the
/// person goes back).
Future<ConnectLink?> scanConnectLink(BuildContext context) =>
    Navigator.of(context).push<ConnectLink>(MaterialPageRoute(builder: (_) => const ScanLinkScreen(connect: true)));

class ScanLinkScreen extends StatefulWidget {
  /// Looks for the code of a browser ([ConnectLink]) instead of a link to add a device.
  final bool connect;

  const ScanLinkScreen({super.key, this.connect = false});

  @override
  State<ScanLinkScreen> createState() => _ScanLinkScreenState();
}

class _ScanLinkScreenState extends State<ScanLinkScreen> {
  final _viewKey = GlobalKey(debugLabel: 'scan-link-view');
  StreamSubscription<Barcode>? _scans;
  bool _done = false;

  @override
  void dispose() {
    _scans?.cancel(); // the view lets go of the controller itself
    super.dispose();
  }

  void _onCreated(QRViewController controller) {
    _scans = controller.scannedDataStream.listen(_onScan);
  }

  void _onScan(Barcode code) {
    if (_done) return;
    final link = widget.connect ? ConnectLink.parse(code.code ?? '') : SyncLink.parse(code.code ?? '');
    if (link != null) {
      _done = true;
      Navigator.of(context).pop(link);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the code')),
      body: Stack(children: [
        QRView(
          key: _viewKey,
          onQRViewCreated: _onCreated,
          formatsAllowed: const [BarcodeFormat.qrcode],
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: widget.connect
                ? const Text('Point the camera at the code that the web version shows.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 6)]))
                : const Text('Point the camera at the code that "Add a device" shows on the other device.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 6)])),
          ),
        ),
      ]),
    );
  }
}
