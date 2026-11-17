"""Lines the app cut out of the handwritten sheet (OUT/lines.json, see ../README.md) -> OUT/truth.json and OUT/truth_meta.json.
  python3 -P make_truth.py OUT_DIR

The lines are matched to the lines of snippets.json by ORDER: page by page as they are in lines.json, top to bottom within a page. If the
numbers differ (the app joined two written lines, or cut one in two) it says so and stops: write them again further apart, or fix
OUT/map.json by hand (`{"line id": [snippet number, line number]}`, both counted from 0) and run it again.
truth.json: line id -> the line without its indentation. truth_meta.json: line id -> language, indentation (levels, as the sheet has
them), where the line starts (`left`), how tall it is (`height`), the block of writing it is in (`block`)."""
import json, os, re, sys

out = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
snippets = json.load(open(os.path.join(here, 'snippets.json')))
flat = [(n, k, s['lang'], line) for n, s in enumerate(snippets) for k, line in enumerate(s['lines'])]
lines = json.load(open(f'{out}/lines.json'))


def box(line):
    boxes = [c['box'] for c in line['chunks']]
    return min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)


page_order = []
for l in lines:
    page = l['id'].split('_c')[0]
    if page not in page_order:
        page_order.append(page)
ordered = sorted(lines, key=lambda l: (page_order.index(l['id'].split('_c')[0]), box(l)[1]))

mapping = {}
if os.path.exists(f'{out}/map.json'):
    mapping = {k: tuple(v) for k, v in json.load(open(f'{out}/map.json')).items()}
    pairs = [(l, flat[next(i for i, f in enumerate(flat) if (f[0], f[1]) == mapping[l['id']])]) for l in ordered if l['id'] in mapping]
elif len(ordered) == len(flat):
    pairs = list(zip(ordered, flat))
else:
    print(f'{len(ordered)} lines were cut out, the sheet has {len(flat)}. Top to bottom, the lines found start at:')
    for i, l in enumerate(ordered):
        b = box(l)
        print(f"  {i:3} {l['id']}  left {b[0]:6.0f}  top {b[1]:6.0f}  height {b[3] - b[1]:4.0f}")
    print('Fix the writing, or give OUT/map.json for the lines that are right.')
    sys.exit(1)

truth, meta = {}, {}
for l, (n, k, lang, text) in pairs:
    b = box(l)
    indent = len(text) - len(text.lstrip(' '))
    unit = 2 if lang == 'dart' else 4
    truth[l['id']] = text.strip()
    meta[l['id']] = {'lang': lang, 'indent': indent // unit, 'left': b[0], 'height': b[3] - b[1], 'block': re.sub(r'_\d+$', '', l['id']), 'snippet': n}
json.dump(truth, open(f'{out}/truth.json', 'w'), indent=1, ensure_ascii=False)
json.dump(meta, open(f'{out}/truth_meta.json', 'w'), indent=1)
print(f'{len(truth)} lines of {len(flat)} matched; truth.json and truth_meta.json written')
