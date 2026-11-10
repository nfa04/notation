import 'package:flutter/material.dart' hide Text;

import '../l10n/language.dart';
import '../l10n/text.dart';

/// Documents to start from: a name, what it is for, and its Markdown (with the parts to fill in in square brackets).
const documentTemplates = <(String, String, IconData, String)>[
  (
    'Letter',
    'A formal letter with the addresses, a date and a signature',
    Icons.mail_outline,
    '{align=right}[Your name]\n{align=right}[Your street and number]\n{align=right}[Postcode and town]\n\n'
        '[Their name]\n[Their street and number]\n[Postcode and town]\n\n'
        '{align=right}[Town], [date]\n\n'
        '**[Subject of the letter]**\n\n'
        'Dear [name],\n\n'
        '[What you want to say.]\n\n'
        'Kind regards,\n\n\n'
        '[Your name]\n',
  ),
  (
    'Essay',
    'A title, an introduction, the main part and a conclusion, the sources at the end',
    Icons.history_edu_outlined,
    '[footer]: {page}\n\n'
        '{align=center}# [Title]\n'
        '{align=center}[Your name] - [course] - [date]\n\n'
        '## Introduction\n\n[What the essay is about, and what it argues.]\n\n'
        '## [First part]\n\n[...]\n\n'
        '## [Second part]\n\n[...]\n\n'
        '## Conclusion\n\n[What follows from it.]\n\n'
        '[bibliography]\n',
  ),
  (
    'Report',
    'A title page, the contents, numbered pages and sections',
    Icons.summarize_outlined,
    '[header]: {title}\n[footer]: Page {page} of {pages}\n\n'
        '\n\n\n{align=center}# [Title of the report]\n'
        '{align=center}[Subtitle]\n\n'
        '{align=center}[Author] - [date]\n'
        '\\pagebreak\n'
        '[toc]\n'
        '\\pagebreak\n'
        '## Summary\n\n[The findings in a few sentences.]\n\n'
        '## Background\n\n[...]\n\n'
        '## Findings\n\n[...]\n\n'
        '| What | Result |\n| --- | --- |\n| [...] | [...] |\n\n'
        '## Recommendations\n\n- [...]\n- [...]\n',
  ),
  (
    'CV',
    'A curriculum vitae: contact, experience, education, skills',
    Icons.badge_outlined,
    '{align=center}# [Your name]\n'
        '{align=center}[Email] - [phone] - [town]\n\n'
        '---\n'
        '## Experience\n\n'
        '**[Job title]**, [company] - *[from] to [until]*\n- [What you did and achieved]\n\n'
        '## Education\n\n'
        '**[Degree]**, [school] - *[year]*\n\n'
        '## Skills\n\n- [...]\n\n'
        '## Languages\n\n- [...]\n',
  ),
  (
    'Meeting notes',
    'Who was there, the agenda, what was decided and what is to be done',
    Icons.groups_outlined,
    '# [Meeting] - [date]\n\n'
        '**Present:** [names]\n\n'
        '## Agenda\n\n1. [...]\n2. [...]\n\n'
        '## Notes\n\n[...]\n\n'
        '## Decisions\n\n- [...]\n\n'
        '## To do\n\n- [ ] [Who] - [what] - [by when]\n',
  ),
  (
    'Cover letter',
    'For a job application',
    Icons.work_outline,
    '{align=right}[Your name] - [email] - [phone]\n\n'
        '{align=right}[Town], [date]\n\n'
        '[Company]\n[Their address]\n\n'
        '**Application for [position]**\n\n'
        'Dear [name],\n\n'
        '[Why this position, and why you.]\n\n'
        '[What you bring: experience, skills, an example.]\n\n'
        '[Closing: that you look forward to talking with them.]\n\n'
        'Kind regards,\n\n[Your name]\n',
  ),
];

/// Asks which document to start from; its Markdown (null: none).
Future<String?> showTemplatePicker(BuildContext context) => showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Start from a template'),
        children: [
          for (final (name, about, icon, markdown) in documentTemplates)
            SimpleDialogOption(
              key: ValueKey('template-$name'),
              onPressed: () => Navigator.pop(context, markdown),
              child: ListTile(leading: Icon(icon), title: Text(name), subtitle: Text.verbatim(tr(about)), contentPadding: EdgeInsets.zero),
            ),
        ],
      ),
    );
