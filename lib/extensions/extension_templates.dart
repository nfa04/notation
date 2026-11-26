import 'package:material_symbols_icons/symbols.dart';

import '../templates/templates.dart';
import 'extension_service.dart';

/// The templates extensions bring (`templates` in their manifests, a Markdown file each), as templates of the app: they appear in the
/// list of templates and make a note whose written document is the text. `{date}` in the text is today (as `2026-12-24`), `{title}`
/// the title of the template.
List<BuiltInTemplate> extensionTemplates(ExtensionService service) => [
      for (final t in service.templates)
        BuiltInTemplate(
          'ext:${t.extension.id}/${t.template.id}',
          t.template.title,
          t.extension.manifest.name,
          Symbols.extension,
          (note, today) {
            final day = '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
            note.documentText = t.text.replaceAll('{date}', day).replaceAll('{title}', t.template.title);
          },
        ),
    ];
