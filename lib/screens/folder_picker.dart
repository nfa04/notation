import 'package:flutter/material.dart' hide Text;

import '../data/note_data.dart';
import '../l10n/language.dart';
import '../l10n/text.dart';

/// Lets the person pick a folder (or "no folder"). The result is wrapped, so that "no folder" (null inside) can be told apart from
/// cancelling (null outside). [exclude] are folders that cannot be chosen (and what is below them); [current] is marked.
Future<(String?,)?> pickFolder(
  BuildContext context, {
  required List<FolderEntry> folders,
  required String title,
  Set<String> exclude = const {},
  String? current,
}) {
  Widget tile(String? id, String name, int depth) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: 16.0 + depth * 20, right: 16),
        leading: Icon(id == null ? Icons.home_outlined : Icons.folder_outlined, size: 20),
        title: Text.verbatim(id == null ? tr(name) : name),
        selected: id == current,
        onTap: () => Navigator.pop(context, (id,)),
      );

  List<Widget> branch(String? parent, int depth) => [
        for (final f in folders.where((f) => f.parentId == parent))
          if (!exclude.contains(f.id)) ...[tile(f.id, f.name, depth), ...branch(f.id, depth + 1)],
      ];

  return showDialog<(String?,)>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text.verbatim(title),
      children: [
        SizedBox(
          width: 360,
          height: 360,
          child: ListView(children: [tile(null, 'No folder (top level)', 0), ...branch(null, 1)]),
        ),
      ],
    ),
  );
}
