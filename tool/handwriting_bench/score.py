"""Scores every OUT_DIR/results/*.json (line id -> text) against OUT_DIR/truth.json.
  python3 -P score.py OUT_DIR [-v] [-l]   (-l: turn LaTeX into plain text before comparing)
CER = edit distance / length of the truth, over all lines together (lower is better). `CER (any case)` ignores capitals, so
the gap to CER is what wrong capitals cost. `lines right` = exact after the normalising below. `all caps` = outputs of 4+ letters
that are all capitals where the truth is not."""
import glob, json, os, re, sys, unicodedata
from rapidfuzz.distance import Levenshtein

out = sys.argv[1]; verbose = '-v' in sys.argv; LATEX_OK = '-l' in sys.argv
truth = json.load(open(f'{out}/truth.json'))

def norm(t):
    t = unicodedata.normalize('NFC', t)
    if LATEX_OK:   # (with -l: the VLMs' LaTeX (`$ \\rightarrow $`) is turned into plain text first; by default it counts as the errors it are, the app has no such step)
        t = re.sub(r'\\(?:right|long)?rightarrow|\\to\b', '->', t)
        t = re.sub(r'\\[()]|\$', '', t)
        t = re.sub(r'[_^]\{([^{}]*)\}', r'\1', t)
        t = re.sub(r'\\(?:cdot|times)', '.', t)
    t = t.replace('₁', '1').replace('₂', '2').replace('∈', 'ε')
    t = re.sub(r'[→⟶➔➜⇒]|-{1,2}>|–>|—>', '->', t)
    t = t.replace('·', '.').replace('⋅', '.').replace('•', '.').replace('’', "'").replace('–', '-').replace('—', '-')
    t = re.sub(r'\s+', ' ', t).strip()
    t = re.sub(r'\s*([:;,.!?)])', r'\1', t)   # spaces before punctuation do not count
    t = re.sub(r'\(\s+', '(', t)
    return t

rows = []
for f in sorted(glob.glob(f'{out}/results/*.json')):
    name = os.path.basename(f)[:-5]
    res = json.load(open(f))
    ids = [i for i in truth if i in res]
    if not ids: continue
    e = e2 = n = ok = caps = empty = 0
    for i in ids:
        g, p = norm(truth[i]), norm(res[i])
        e += Levenshtein.distance(g, p); e2 += Levenshtein.distance(g.casefold(), p.casefold()); n += len(g)
        ok += g == p
        empty += p == ''
        letters = re.sub(r'[^A-Za-zÄÖÜäöüß]', '', p)
        if len(letters) >= 4 and letters.isupper() and not re.sub(r'[^A-Za-zÄÖÜäöüß]', '', g).isupper(): caps += 1
        if verbose: print(f'{name:10} {i}\n   truth: {g}\n   read : {p}')
    rows.append((name, len(ids), e / n, e2 / n, ok, caps, empty))
print(f"{'reader':14}{'lines':>6}{'CER':>8}{'CER (any case)':>16}{'lines right':>13}{'all caps':>10}{'empty':>7}")
for r in sorted(rows, key=lambda r: r[2]):
    print(f'{r[0]:14}{r[1]:>6}{r[2]*100:>7.1f}%{r[3]*100:>15.1f}%{r[4]:>13}{r[5]:>10}{r[6]:>7}')
