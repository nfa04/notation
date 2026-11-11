#!/usr/bin/env python3
"""Makes pages of hand-written-looking mixed content (text, formulas, matrices, doodles) with the right answer for every stroke, for
test/ink_layout_test.dart: which block of writing it is in, which row of that block, and whether it is text, maths or a drawing.

    python3 tool/ink_fixtures/make_mixed_pages.py HERSHEY_DIR QUICKDRAW_DIR OUT.json

HERSHEY_DIR: the .jhf files of https://github.com/kamalmostafa/hershey-fonts (hershey-fonts/). Letters are Hershey glyphs, bent and shaken per
letter so that no two are alike; script words are joined into one stroke the way joined-up writing is.
QUICKDRAW_DIR: <category>.ndjson files of the Quick, Draw! dataset (simplified), https://quickdraw.withgoogle.com/data: real doodles.
The same seed makes the same pages. See test/fixtures/ink_layout/README.md for the licences of the data.
"""
import json
import math
import os
import random
import sys

TEXT, MATHS, DRAWING = 0, 1, 2


def parse_jhf(path):
    t = open(path).read().replace('\n', '')
    glyphs, i = [], 0
    while i < len(t):
        n = int(t[i + 5:i + 8])
        body = t[i + 8:i + 8 + 2 * n]
        i += 8 + 2 * n
        left, right = ord(body[0]) - 82, ord(body[1]) - 82
        strokes, cur = [], []
        for k in range(2, len(body), 2):
            pair = body[k:k + 2]
            if pair == ' R':
                if cur:
                    strokes.append(cur)
                cur = []
            else:
                cur.append((ord(pair[0]) - 82, ord(pair[1]) - 82))
        if cur:
            strokes.append(cur)
        glyphs.append((left, right, strokes))
    return {chr(32 + k): g for k, g in enumerate(glyphs)}


class Pen:
    """Writes on one page: every stroke with its answer."""

    def __init__(self, rnd, fonts, doodles):
        self.rnd, self.fonts, self.doodles = rnd, fonts, doodles
        self.strokes = []  # (points, block, row, kind)
        self.said = {}  # (block, row): [(kind, text)], what each row says, in order
        # this writer's hand: size, slant, how much it shakes, how wide it spaces
        self.cap = rnd.uniform(20, 32)
        self.slant = rnd.uniform(-0.05, 0.3)
        self.shake = rnd.uniform(0.02, 0.07)
        self.space = rnd.uniform(0.9, 1.5)
        self.script = rnd.random() < 0.6
        self.colour = rnd.choice([0xFF000000, 0xFFD32F2F, 0xFF1565C0, 0xFF2E7D32])

    def add(self, pts, block, row, kind):
        if len(pts) >= 2:
            self.strokes.append((resample(pts, 2.5), block, row, kind))

    def glyph(self, font, ch, x, y, size, block, row, kind, join=None):
        """Writes [ch] with its baseline at y, left edge at x; returns the advance. [join] collects the strokes of a joined-up word."""
        r = self.rnd
        left, right, strokes = self.fonts[font][ch]
        s = size / 21.0 * r.uniform(0.9, 1.1)
        rot = r.uniform(-0.06, 0.06)
        dy = r.uniform(-0.06, 0.06) * size
        out = []
        for st in strokes:
            pts = []
            for gx, gy in st:
                px, py = (gx - left) * s, (gy - 9) * s  # Hershey baseline is at +9
                px, py = px * math.cos(rot) - py * math.sin(rot), px * math.sin(rot) + py * math.cos(rot)
                px -= self.slant * py
                pts.append((x + px, y + py + dy))
            out.append(wobble(r, pts, self.shake * size))
        if join is not None:
            join.extend(out)
        else:
            for pts in out:
                self.add(pts, block, row, kind)
        return (right - left) * s

    def word(self, text, x, y, block, row, kind=TEXT, size=None, font=None):
        size = size or self.cap
        font = font or ('scripts' if self.script and kind == TEXT and text.isalpha() else 'futural')
        if font == 'scripts' and len(text) > 1:
            # joined-up: the letters of the word are one stroke (dots, crossings and accents are lifted)
            parts = []
            for ch in text:
                x += self.glyph(font, ch, x, y, size, block, row, kind, join=parts)
            # each part that starts near where the word's stroke ends goes on with it; the others (the dot of an i, the bar of a t) are lifted
            main, lifted = [], []
            for part in parts:
                if not main or dist(main[-1], part[0]) < 0.6 * size:
                    main.extend(part)
                else:
                    lifted.append(part)
            self.add(main, block, row, kind)
            for part in lifted:
                self.add(part, block, row, kind)
            return x
        for ch in text:
            x += self.glyph(font, ch, x, y, size, block, row, kind)
        return x

    def say(self, block, row, kind, text):
        self.said.setdefault((block, row), []).append((kind, text))

    def line(self, words, x, y, block, row, kind=TEXT):
        self.say(block, row, kind, ' '.join(words))
        for w in words:
            x = self.word(w, x, y, block, row, kind) + self.space * 0.55 * self.cap
        return x

    def stroke(self, pts, block, row, kind):
        self.add(wobble(self.rnd, pts, self.shake * self.cap * 0.5), block, row, kind)

    def doodle(self, category, x, y, size, block=-1):
        d = self.rnd.choice(self.doodles[category])
        for xs, ys in d:
            self.add([(x + a / 255 * size, y + b / 255 * size) for a, b in zip(xs, ys)], block, -1, DRAWING)


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def wobble(r, pts, amount):
    """[pts] with a slow drift, as a hand has."""
    phase, freq = r.uniform(0, 6.3), r.uniform(0.02, 0.06)
    out = []
    for i, (x, y) in enumerate(pts):
        out.append((x + amount * math.sin(phase + freq * i * 7), y + amount * math.cos(phase * 1.3 + freq * i * 5)))
    return out


def resample(pts, step):
    out = [pts[0]]
    for a, b in zip(pts, pts[1:]):
        d = dist(a, b)
        n = max(1, int(d / step))
        for k in range(1, n + 1):
            out.append((a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n))
    return out


def arc_bracket(x, top, bottom, opens, bulge):
    """A round bracket from top to bottom whose middle is [bulge] to the left (opening) or right."""
    pts = []
    for k in range(21):
        t = k / 20
        dx = bulge * math.sin(math.pi * t)
        pts.append((x - dx if opens else x + dx, top + (bottom - top) * t))
    return pts


def square_bracket(x, top, bottom, opens, w):
    e = x + w if opens else x - w
    return [(e, top), (x, top), (x, bottom), (e, bottom)]


# ---------------------------------------------------------------------------------------------------------------------------------------------
# The things written: each takes the pen, where to start (x, baseline y), the block and row; returns the x where it ends.

def latex(items):
    """The LaTeX of a formula of [write_expr], as a reader would write it."""
    out = []
    for it in items:
        if isinstance(it, str):
            out.append({'->': r'\rightarrow'}.get(it, it))
        elif it[0] == 'sub':
            out.append(f'{it[1]}_{{{it[2]}}}')
        elif it[0] == 'sup':
            out.append(f'{it[1]}^{{{it[2]}}}')
        elif it[0] == 'frac':
            out.append(f'\\frac{{{it[1]}}}{{{it[2]}}}')
        elif it[0] == 'sum':
            out.append(f'\\sum_{{{it[1]}}}^{{{it[2]}}}')
        elif it[0] == 'sqrt':
            out.append(f'\\sqrt{{{it[1]}}}')
        elif it[0] == 'matrix':
            body = r' \\ '.join(' & '.join(r) for r in it[1])
            out.append(f'\\begin{{pmatrix}}{body}\\end{{pmatrix}}')
    return ' '.join(out)


def write_expr(p, items, x, y, block, row):
    """A formula: items are strings (written as signs), ('frac', top, bottom), ('sub', base, s), ('sup', base, s), ('sum', lo, hi),
    ('matrix', rows), ('sqrt', inner)."""
    p.say(block, row, MATHS, latex(items))
    c = p.cap
    gap = 0.35 * c
    for it in items:
        if isinstance(it, str):
            if it == '=':
                w = 0.6 * c
                p.stroke([(x, y - 0.42 * c), (x + w, y - 0.42 * c)], block, row, MATHS)
                p.stroke([(x, y - 0.22 * c), (x + w, y - 0.22 * c)], block, row, MATHS)
                x += w + gap
            elif it == '->':
                w = 1.6 * c
                p.stroke([(x, y - 0.35 * c), (x + w, y - 0.35 * c)], block, row, MATHS)
                p.stroke([(x + w - 0.3 * c, y - 0.55 * c), (x + w, y - 0.35 * c), (x + w - 0.3 * c, y - 0.15 * c)], block, row, MATHS)
                x += w + gap
            else:
                x = p.word(it, x, y, block, row, MATHS) + gap
        elif it[0] == 'sub' or it[0] == 'sup':
            x = p.word(it[1], x, y, block, row, MATHS)
            off = 0.3 * c if it[0] == 'sub' else -0.65 * c
            x = p.word(it[2], x + 0.05 * c, y + off, block, row, MATHS, size=0.6 * c) + gap
        elif it[0] == 'frac':
            top_w = len(it[1]) * 0.75 * c
            bot_w = len(it[2]) * 0.75 * c
            w = max(top_w, bot_w) + 0.3 * c
            bar = y - 0.35 * c
            p.word(it[1], x + (w - top_w) / 2, bar - 0.3 * c, block, row, MATHS)
            p.stroke([(x, bar), (x + w, bar)], block, row, MATHS)
            p.word(it[2], x + (w - bot_w) / 2, bar + 1.25 * c, block, row, MATHS)
            x += w + gap
        elif it[0] == 'sum':
            h = 1.3 * c
            top, bottom = y - 1.05 * c, y + 0.25 * c
            w = 0.9 * c
            p.stroke([(x + w, top), (x, top), (x + 0.5 * w, (top + bottom) / 2), (x, bottom), (x + w, bottom)], block, row, MATHS)
            p.word(it[2], x + 0.1 * w, top - 0.2 * c, block, row, MATHS, size=0.55 * c)
            p.word(it[1], x, bottom + 0.75 * c, block, row, MATHS, size=0.55 * c)
            x += w + gap
        elif it[0] == 'sqrt':
            inner_w = len(it[1]) * 0.75 * c
            top = y - 1.25 * c
            p.stroke([(x, y - 0.4 * c), (x + 0.2 * c, y - 0.5 * c), (x + 0.4 * c, y + 0.15 * c), (x + 0.7 * c, top), (x + 1.0 * c + inner_w, top)], block, row, MATHS)
            x = p.word(it[1], x + 0.85 * c, y, block, row, MATHS) + gap
        elif it[0] == 'matrix':
            cells = it[1]
            n = len(cells)
            col_w = 1.6 * c * p.rnd.uniform(1.0, 1.8)
            row_h = 1.5 * c * p.rnd.uniform(0.9, 1.3)
            height = n * row_h
            top = y - 0.5 * c - height / 2 - 0.2 * c
            bottom = top + height + 0.3 * c
            square = p.rnd.random() < 0.3
            br = square_bracket(x + 0.3 * c, top, bottom, True, 0.35 * c) if square else arc_bracket(x + 0.45 * c, top, bottom, True, p.rnd.uniform(0.12, 0.3) * height)
            p.stroke(br, block, row, MATHS)
            cx = x + 0.8 * c
            for i, cells_row in enumerate(cells):
                by = top + (i + 0.5) * row_h + 0.55 * c
                for j, cell in enumerate(cells_row):
                    p.word(cell, cx + j * col_w, by, block, row, MATHS)
            right = cx + len(cells[0]) * col_w - 0.2 * c
            br = square_bracket(right + 0.3 * c, top, bottom, False, 0.35 * c) if square else arc_bracket(right, top, bottom, False, p.rnd.uniform(0.12, 0.3) * height)
            p.stroke(br, block, row, MATHS)
            x = right + 0.6 * c + gap
    return x


WORDS = ('the of and for with this that from into each when then there where which while about after before under over between through '
         'solve energy pressure velocity flow constant volume equation value matrix vector eigen decomposition sample mean variance '
         'given shows follows therefore because using example step result simple linear system point field force mass time rate '
         'die der und mit fuer eine nach ist nicht auch werden durch Formel Beispiel Loesung Gleichung').split()


def text_words(r, n):
    return [r.choice(WORDS) for _ in range(n)]


def num(r):
    return str(r.randint(0, 30))


def letter(r):
    return r.choice('abcdxyzmnpqrstuvw')


def random_formula(r):
    kind = r.choice(['frac', 'sub', 'sum', 'sqrt', 'plain', 'sup'])
    a, b = letter(r), letter(r)
    if kind == 'frac':
        return [a, '=', ('frac', f'{b}+{num(r)}', num(r)), '+', letter(r)]
    if kind == 'sub':
        return [('sub', a, '1'), '=', ('sub', b, '2'), '+', num(r)]
    if kind == 'sum':
        return [a, '=', ('sum', 'k=1', 'n'), ('sub', b, 'k')]
    if kind == 'sqrt':
        return [a, '=', ('sqrt', f'{b}+{num(r)}')]
    if kind == 'sup':
        return [('sup', a, '2'), '+', ('sup', b, '2'), '=', ('sup', letter(r), '2')]
    return [a, '+', num(r), '=', b]


def random_matrix(r):
    n = r.choice([2, 2, 3])
    m = r.choice([n, n, 1])
    pick = lambda: r.choice([num(r), letter(r), '0', '1'])
    return ('matrix', [[pick() for _ in range(m)] for _ in range(n)])


# ---------------------------------------------------------------------------------------------------------------------------------------------
# Pages: each is a few blocks of one kind of mixed content, laid out down the page.

def block_paragraph(p, x, y, block):
    r = p.rnd
    rows = r.randint(2, 4)
    lead = r.uniform(1.7, 2.3) * p.cap
    for i in range(rows):
        p.line(text_words(r, r.randint(3, 6)), x, y + i * lead, block, i)
    return y + rows * lead


def block_text_with_formula(p, x, y, block):
    r = p.rnd
    end = p.line(text_words(r, r.randint(2, 4)), x, y, block, 0)
    write_expr(p, random_formula(r), end, y, block, 0)
    return y + 2.4 * p.cap


def block_worked(p, x, y, block):
    """A worked solution: rows of formulas under each other, some with fractions."""
    r = p.rnd
    rows = r.randint(2, 4)
    yy = y
    for i in range(rows):
        f = random_formula(r)
        tall = any(isinstance(t, tuple) and t[0] in ('frac', 'sum') for t in f)
        if tall:
            yy += 0.6 * p.cap
        write_expr(p, f, x + r.uniform(0, 1) * p.cap, yy, block, i)
        yy += (3.0 if tall else 2.0) * p.cap * r.uniform(0.95, 1.15)
    return yy


def block_matrix(p, x, y, block):
    r = p.rnd
    items = [letter(r).upper(), '=', random_matrix(r)]
    if r.random() < 0.6:
        items += ['=', random_matrix(r)]
    if r.random() < 0.4:
        items += ['->', ('sub', letter(r), '11'), '=', num(r)]
    y += 1.6 * p.cap
    write_expr(p, items, x, y, block, 0)
    return y + 3.2 * p.cap


def block_label_formula(p, x, y, block):
    r = p.rnd
    label = r.choice(['Translation', 'Rotation', 'Beispiel', 'Example', 'Given'])
    p.say(block, 0, TEXT, label + ':')
    end = p.word(label, x, y, block, 0)
    # the colon
    c = p.cap
    p.stroke([(end + 0.15 * c, y - 0.55 * c), (end + 0.17 * c, y - 0.5 * c)], block, 0, TEXT)
    p.stroke([(end + 0.15 * c, y - 0.1 * c), (end + 0.17 * c, y - 0.05 * c)], block, 0, TEXT)
    write_expr(p, random_formula(r), end + 1.2 * c, y, block, 0)
    return y + 2.6 * c


def block_heading(p, x, y, block):
    r = p.rnd
    end = p.line(text_words(r, r.randint(1, 3)), x, y, block, 0)
    if r.random() < 0.5:
        # an underline is a long stroke: not handwriting, and not a row of its own
        p.add([(x - 5, y + 0.45 * p.cap), (end, y + 0.5 * p.cap)], block, -1, DRAWING)
    return y + 2.2 * p.cap


def doodle_beside(p, x, y, block, right_edge):
    r = p.rnd
    size = r.uniform(2.5, 6) * p.cap
    p.doodle(r.choice(list(p.doodles)), right_edge + r.uniform(1, 3) * p.cap, y - size * 0.6, size)


def doodle_between(p, x, y):
    r = p.rnd
    size = r.uniform(3, 7) * p.cap
    p.doodle(r.choice(list(p.doodles)), x + r.uniform(0, 8) * p.cap, y, size)
    return y + size + 1.5 * p.cap


def doodle_small_inline(p, x, y, block):
    """A small doodle (a star, a sun) at the end of a line of text: small strokes, as small as letters."""
    r = p.rnd
    end = p.line(text_words(r, r.randint(2, 4)), x, y, block, 0)
    size = r.uniform(1.2, 2.0) * p.cap
    p.doodle(r.choice([c for c in p.doodles if c in ('star', 'sun', 'flower', 'eye', 'cloud')] or list(p.doodles)), end + 0.8 * p.cap, y - size * 0.8, size)
    return y + 2.4 * p.cap


def tilt(p, since, x, y, angle):
    """Turns the strokes written since [since] by [angle] about (x, y): a line that runs uphill or down."""
    c, s = math.cos(angle), math.sin(angle)
    for i in range(since, len(p.strokes)):
        pts, b, row, k = p.strokes[i]
        p.strokes[i] = ([(x + (px - x) * c - (py - y) * s, y + (px - x) * s + (py - y) * c) for px, py in pts], b, row, k)


def block_dense(p, x, y, block):
    """Lines written close together, the block a little uphill or downhill, words of different sizes: notes taken in a hurry."""
    r = p.rnd
    rows = r.randint(3, 5)
    lead = r.uniform(1.4, 1.8) * p.cap
    # (a block runs uphill or downhill as a whole: the hand drifts the same way line after line)
    slope = r.uniform(-0.04, 0.04)
    for i in range(rows):
        since = len(p.strokes)
        words = text_words(r, r.randint(3, 6))
        p.say(block, i, TEXT, ' '.join(words))
        xx = x + r.uniform(0, 0.8) * p.cap
        for w in words:
            xx = p.word(w, xx, y + i * lead, block, i, size=p.cap * r.uniform(0.85, 1.15)) + p.space * 0.55 * p.cap
        tilt(p, since, x, y + i * lead, slope + r.uniform(-0.008, 0.008))
    return y + rows * lead


def block_text_formula_inside(p, x, y, block):
    """A sentence with a formula in the middle of it, and a second line under it."""
    r = p.rnd
    lead = r.uniform(1.9, 2.4) * p.cap
    end = p.line(text_words(r, r.randint(1, 3)), x, y, block, 0)
    end = write_expr(p, random_formula(r), end + 0.3 * p.cap, y, block, 0)
    p.line(text_words(r, r.randint(1, 3)), end + 0.3 * p.cap, y, block, 0)
    p.line(text_words(r, r.randint(3, 5)), x, y + lead + 0.5 * p.cap, block, 1)
    return y + 2 * lead


KINDS = {
    'paragraph': [block_heading, block_paragraph],
    'inline_formula': [block_text_with_formula, block_paragraph],
    'worked': [block_heading, block_worked],
    'matrix': [block_heading, block_matrix, block_worked],
    'label': [block_label_formula, block_worked],
    'doodle_beside': [block_paragraph, 'beside'],
    'doodle_between': [block_paragraph, 'between', block_paragraph],
    'doodle_inline': [doodle_small_inline, block_paragraph],
    'physics': [block_heading, block_text_with_formula, block_worked, block_matrix],
    # (added later: kinds go on the end, so that the pages before them stay as they were)
    'dense': [block_dense, block_dense],
    'formula_inside': [block_text_formula_inside, block_text_formula_inside],
    'dense_doodle': [block_dense, 'beside', block_text_formula_inside],
}


def make_page(name, kind, seed, fonts, doodles):
    r = random.Random(seed)
    p = Pen(r, fonts, doodles)
    x, y, block = 40.0, 60.0, 0
    for step in KINDS[kind]:
        if step == 'beside':
            doodle_beside(p, x, y - 2 * p.cap, block - 1, max(pt[0] for s in p.strokes for pt in s[0]))
            continue
        if step == 'between':
            y = doodle_between(p, x, y)
            continue
        y = step(p, x, y, block) + r.uniform(2.5, 4) * p.cap
        block += 1
    def spoken(parts):
        return ' '.join(t if k == TEXT else f'${t}$' for k, t in parts)

    return {
        'id': name,
        'kind': kind,
        # what each row says, as the reader should write it: text as it is, maths as LaTeX between dollar signs
        'says': {f'{b}/{r}': spoken(parts) for (b, r), parts in sorted(p.said.items())},
        'strokes': [
            {'c': p.colour, 'w': 3, 'pts': [round(v, 1) for pt in pts for v in pt], 't': [b, row, k]}
            for pts, b, row, k in p.strokes
        ],
    }


def load_doodles(folder, per=40):
    out = {}
    for f in sorted(os.listdir(folder)):
        if not f.endswith('.ndjson'):
            continue
        items = []
        for line in open(os.path.join(folder, f)):
            try:
                d = json.loads(line)
            except ValueError:
                break  # a cut-off last line
            if d.get('recognized'):
                items.append(d['drawing'])
            if len(items) >= per:
                break
        out[f[:-7]] = items
    return out


def main():
    hershey, quickdraw, out = sys.argv[1:4]
    fonts = {n: parse_jhf(os.path.join(hershey, n + '.jhf')) for n in ('scripts', 'futural')}
    doodles = load_doodles(quickdraw)
    pages = []
    for kind in KINDS:
        for i in range(6):
            pages.append(make_page(f'{kind}_{i}', kind, len(pages) * 7919 + 13, fonts, doodles))
    json.dump(pages, open(out, 'w'), separators=(',', ':'))
    print(len(pages), 'pages', sum(len(p['strokes']) for p in pages), 'strokes')


if __name__ == '__main__':
    main()
