"""Checks that make_truth.py and score_code.py work, with made-up lines (no ink, no model): lines laid out like the sheet, readings with
mistakes put in on purpose. `python3 -P selftest.py` prints OK, or says what is wrong.
It also shows what the numbers look like before there is real handwriting."""
import json, os, random, re, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
snippets = json.load(open(os.path.join(here, 'snippets.json')))
rnd = random.Random(3)
H, K = 24.0, 1.5  # a line is 24 high, one level of indentation 1.5 line heights

lines, reading_plain, reading_noisy = [], {}, {}
top = 20.0
for n, s in enumerate(snippets):
    for k, text in enumerate(s['lines']):
        unit = 2 if s['lang'] == 'dart' else 4
        level = (len(text) - len(text.lstrip(' '))) // unit
        left = 20 + level * K * H + rnd.uniform(-3, 3)
        lid = f'page_c{n:02d}_{k:02d}'
        lines.append({'id': lid, 'chunks': [{'box': [left, top, left + 8 * len(text.strip()), top + H], 'n': 1}], 'strokes': []})
        reading_plain[lid] = text.strip()
        t = text.strip()
        # mistakes a reader makes: a word with a wrong letter, a curly quote, a bracket left out, a symbol swapped
        if 'return' in t and k % 2 == 0:
            t = t.replace('return', 'retum')
        t = t.replace('"', '”', 1) if '"' in t and n % 3 == 0 else t
        if '(' in t and ')' in t and n % 4 == 0:
            t = t[::-1].replace(')', '', 1)[::-1]
        if ';' in t and n % 5 == 0:
            t = t.replace(';', ':', 1)
        reading_noisy[lid] = t
        top += H * 1.6
    top += H  # a free line between snippets

with tempfile.TemporaryDirectory() as tmp:
    json.dump(lines, open(f'{tmp}/lines.json', 'w'))
    os.makedirs(f'{tmp}/results')
    json.dump(reading_plain, open(f'{tmp}/results/perfect.json', 'w'))
    json.dump(reading_noisy, open(f'{tmp}/results/noisy.json', 'w'))
    made = subprocess.run([sys.executable, '-P', os.path.join(here, 'make_truth.py'), tmp], capture_output=True, text=True)
    assert made.returncode == 0, made.stdout + made.stderr
    scored = subprocess.run([sys.executable, '-P', os.path.join(here, 'score_code.py'), tmp], capture_output=True, text=True)
    assert scored.returncode == 0, scored.stdout + scored.stderr
    text = scored.stdout
    print(text)
    assert '== perfect' in text and 'CER 0.0 %' in text.split('== perfect')[1].split('==')[0], 'a perfect reading must score 0'
    noisy = text.split('== noisy')[1].split('== indentation')[0]
    assert 'CER 0.0 %' not in noisy.split('\n')[1], 'the mistakes must cost something'
    assert 'typography' in noisy and 'keywords' in noisy and 'brackets' in noisy
    # the rules mend what they were made for: with all of them applied the noisy reading is better than it was
    first = noisy.split('\n')[1]
    all_line = [l for l in noisy.split('\n') if l.strip().startswith('ALL')][0]
    assert float(first.split('CER ')[1].split(' %')[0]) > float(all_line.split()[1]), 'the rules should help on mistakes they know'
    assert re.search(r'one level = 1\.\d\d line heights -> 100\.0 %', text), 'the indentation must be found from the geometry'

    # a wrong number of lines is said, not guessed
    json.dump(lines[:-3], open(f'{tmp}/lines.json', 'w'))
    os.remove(f'{tmp}/truth.json')
    short = subprocess.run([sys.executable, '-P', os.path.join(here, 'make_truth.py'), tmp], capture_output=True, text=True)
    assert short.returncode == 1 and 'lines were cut out' in short.stdout, short.stdout
print('OK')
