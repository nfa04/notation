"""The sheet to copy by hand: every snippet of snippets.json, numbered, with its language.
  python3 -P make_sheet.py            prints it
  python3 -P make_sheet.py --md FILE  writes it as Markdown (to open in the app or on another screen)
Write each LINE on a line of its own, top to bottom on ONE page, in the order of the sheet, the way you would write code in a note:
indent with the pen where the sheet indents (4 spaces = one level; 2 for Dart), leave a free line between snippets. Do not write the
numbers or the language."""
import json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
snippets = json.load(open(os.path.join(here, 'snippets.json')))
out = []
for n, s in enumerate(snippets, 1):
    out.append(f"{n:2}. [{s['lang']}]")
    for line in s['lines']:
        out.append('    | ' + line)
text = '\n'.join(out)
if '--md' in sys.argv:
    path = sys.argv[sys.argv.index('--md') + 1]
    open(path, 'w').write('# Handwritten code sheet\n\n```\n' + text + '\n```\n')
    print('written', path)
else:
    print(text)
print(f"\n{len(snippets)} snippets, {sum(len(s['lines']) for s in snippets)} lines", file=sys.stderr)
