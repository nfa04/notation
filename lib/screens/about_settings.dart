import 'package:flutter/material.dart' hide Text;

import '../l10n/text.dart';
import '../widgets/notation_logo.dart';
import 'lookup_panel.dart' show openInBrowser;

/// Where the privacy policy is read (docs/privacy.md). Once the website serves it, point this at that page and use the same address
/// in the store listings.
final privacyPolicyUrl = Uri.parse('https://github.com/nfa04/notation/blob/main/docs/privacy.md');

/// Settings: what the app is built from, with the page of the licences of all of it.
class AboutSettings extends StatelessWidget {
  const AboutSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('About', style: Theme.of(context,).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      Text(
        'Notation is built with open-source software and fonts; their licences are listed on the page below. '
        'The models and dictionaries that are downloaded on request name their licence where you turn them on.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        key: const ValueKey('about-licences'),
        icon: const Icon(Icons.description_outlined),
        label: Text('Open-source licences'),
        onPressed: () => showLicensePage(context: context, applicationName: 'Notation',
            applicationIcon: const Padding(
              padding: EdgeInsets.all(8),
              child: NotationLogo(size: 56),
            ), applicationLegalese: '© 2026 Noel Aeby'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const ValueKey('about-privacy'),
        icon: const Icon(Icons.privacy_tip_outlined),
        label: Text('Privacy policy'),
        onPressed: () => openInBrowser(privacyPolicyUrl),
      ),
    ]);
  }
}
