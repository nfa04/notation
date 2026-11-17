"""How well handwritten CODE was read, and what simple rules would add. Needs OUT_DIR/truth.json, truth_meta.json (make_truth.py) and
results/*.json (line id -> text, from run_hf.py / run_glm_onnx.py).
  python3 -P score_code.py OUT_DIR [-v]

Per reader:
  CER             edit distance / length of the truth, whitespace inside a line counted as one space
  CER no spaces   the same with every space left out (what the reading is worth when spacing is mended by the language)
  lines right     lines that are exactly right (after the spacing above)
  symbols right   share of the characters that are neither letters nor digits ({}[]()<>;:=!_*/\\|&%#$@^~"'.,+-) that came out right
  by language     CER for each language of the sheet
  mix-ups         the pairs (truth -> read) that happen most
  rules           what each rule of repair.py does to CER if it is applied to the reading, how many lines it helped and harmed
And once, for the geometry (not the reader): how well the indentation can be told from where the lines start."""
import glob, json, os, re, statistics, sys
from collections import Counter, defaultdict
from rapidfuzz.distance import Levenshtein

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from repair import RULES, repair

out = sys.argv[1]
verbose = '-v' in sys.argv
truth = json.load(open(f'{out}/truth.json'))
meta = json.load(open(f'{out}/truth_meta.json'))


def spaced(t):
    return re.sub(r'\s+', ' ', t).strip()


def bare(t):
    return re.sub(r'\s+', '', t)


SYMBOL = re.compile(r'[^A-Za-z0-9\s]')


def cer(pairs, f=spaced):
    e = n = 0
    for g, p in pairs:
        g, p = f(g), f(p)
        e += Levenshtein.distance(g, p)
        n += len(g)
    return e / n if n else 0.0


def report(name, res):
    ids = [i for i in truth if i in res]
    if not ids:
        return
    pairs = [(truth[i], res[i]) for i in ids]
    right = sum(spaced(g) == spaced(p) for g, p in pairs)
    sym_total = sym_ok = 0
    mix = Counter()
    for g, p in pairs:
        g, p = spaced(g), spaced(p)
        kept = [False] * len(g)
        for tag, a0, a1, b0, b1 in Levenshtein.opcodes(g, p):
            if tag == 'equal':
                for k in range(a0, a1):
                    kept[k] = True
            elif tag == 'replace' and a1 - a0 == b1 - b0:
                for k in range(a1 - a0):
                    mix[(g[a0 + k], p[b0 + k])] += 1
            elif tag == 'delete':
                for k in range(a0, a1):
                    mix[(g[k], '∅')] += 1
        for k, c in enumerate(g):
            if SYMBOL.match(c):
                sym_total += 1
                sym_ok += kept[k]
    print(f'\n== {name}: {len(ids)} lines')
    print(f'  CER {cer(pairs) * 100:.1f} %   CER no spaces {cer(pairs, bare) * 100:.1f} %   lines right {right}/{len(ids)}   symbols right {100 * sym_ok / max(1, sym_total):.1f} % of {sym_total}')
    langs = defaultdict(list)
    for i in ids:
        langs[meta[i]['lang']].append((truth[i], res[i]))
    print('  by language: ' + '   '.join(f'{l} {cer(p) * 100:.0f} %' for l, p in sorted(langs.items(), key=lambda kv: cer(kv[1]))))
    print('  mix-ups: ' + '   '.join(f'{a}→{b} ×{n}' for (a, b), n in mix.most_common(12)))
    base = cer(pairs)
    print('  rules (CER change, lines helped / harmed):')
    for rule in list(RULES) + ['ALL']:
        fixed = [(i, repair(res[i], meta[i]['lang'], None if rule == 'ALL' else [rule])) for i in ids]
        helped = harmed = 0
        for i, f in fixed:
            before, after = Levenshtein.distance(spaced(truth[i]), spaced(res[i])), Levenshtein.distance(spaced(truth[i]), spaced(f))
            helped += after < before
            harmed += after > before
        now = cer([(truth[i], f) for i, f in fixed])
        print(f'    {rule:11} {now * 100:5.1f} %  ({(now - base) * 100:+.1f})   helped {helped}   harmed {harmed}')
    if verbose:
        for i in ids:
            if spaced(truth[i]) != spaced(res[i]):
                print(f'    {i}\n      truth: {truth[i]}\n      read : {res[i]}')


def indentation():
    """Levels from where a line starts, against the block's own left edge: the best size of one level, as a multiple of the line height."""
    blocks = defaultdict(list)
    for i, m in meta.items():
        blocks[m['block']].append(i)
    heights = [m['height'] for m in meta.values()]
    if len(blocks) == 0 or not heights:
        return
    h = statistics.median(heights)
    best = None
    table = []
    for k4 in range(2, 25):
        k = k4 / 4
        ok = 0
        for ids in blocks.values():
            base = min(meta[i]['left'] for i in ids)
            for i in ids:
                ok += round((meta[i]['left'] - base) / (k * h)) == meta[i]['indent']
        acc = ok / len(meta)
        table.append((k, acc))
        if best is None or acc > best[1]:
            best = (k, acc)
    levels = Counter(m['indent'] for m in meta.values())
    flat = levels[0] / len(meta)
    print(f'\n== indentation from where the lines start ({len(meta)} lines, median height {h:.0f}; {flat * 100:.0f} % are at level 0, which "never indent" gets right)')
    print(f'  best: one level = {best[0]:.2f} line heights -> {best[1] * 100:.1f} % of the lines right')
    near = [f'{k:.2f}:{a * 100:.0f}%' for k, a in table if abs(k - best[0]) <= 0.5]
    print('  around it: ' + '  '.join(near))


files = sorted(glob.glob(f'{out}/results/*.json'))
if not files:
    print('no results/*.json in', out)
for f in files:
    report(os.path.basename(f)[:-5], json.load(open(f)))
indentation()
