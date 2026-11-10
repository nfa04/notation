import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../l10n/text.dart';
import '../style/platform_dialog.dart';

/// The documentation of the extension API (docs/extensions.md, shipped with the app), to read while writing an extension.
Future<void> showExtensionDocs(BuildContext context) => showDialog<void>(
      context: context,
      builder: (context) => PlatformAlertDialog(
        title: const Text('Extension documentation'),
        content: SizedBox(
          width: 720,
          height: 520,
          child: FutureBuilder<String>(
            future: rootBundle.loadString('docs/extensions.md'),
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text('The documentation could not be loaded.');
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator.adaptive());
              return SingleChildScrollView(
                child: SelectableText(snapshot.data!, key: const ValueKey('extension-docs-text'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final text = await rootBundle.loadString('docs/extensions.md');
              await Clipboard.setData(ClipboardData(text: text));
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
