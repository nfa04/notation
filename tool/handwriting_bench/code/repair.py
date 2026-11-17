"""Rules that could make what a reader wrote for handwritten code more like code. They are only SIMULATED here, to find out which of them
earn their keep on real ink before anything goes into the app: each takes a line and its language and gives a line back.
  from repair import RULES, repair"""
import re
from rapidfuzz.distance import Levenshtein

KEYWORDS = {
    'python': 'def return if elif else for while in range import from as class self print len with open lambda not and or is None True False try except finally pass break continue yield raise global'.split(),
    'dart': 'final var const class return if else for while in await async Future void int double String bool List Map null this super new static extends implements import true false switch case break continue try catch throw required'.split(),
    'c': 'int char float double void return if else for while struct sizeof malloc free printf include define static const unsigned long short break continue switch case typedef enum NULL'.split(),
    'java': 'public private static void class return if else for while new null this import String int double boolean true false extends implements try catch throw final package System out println'.split(),
    'javascript': 'const let var function return if else for while new null this import export class async await true false typeof document map filter reduce forEach'.split(),
    'sql': 'SELECT FROM WHERE GROUP BY ORDER INSERT INTO VALUES UPDATE DELETE CREATE TABLE JOIN ON AND OR NOT NULL COUNT AS LIMIT HAVING DISTINCT'.split(),
    'shell': 'for in do done if then else fi while echo grep sort git commit push pull cd ls cat wc find sed awk'.split(),
}

# what a hand makes the same: letters and digits that look alike
_LOOK = {'0': 'o', 'O': 'o', '1': 'l', 'I': 'l', '5': 's', '8': 'b'}


def _squash(token):
    t = ''.join(_LOOK.get(c, c.lower()) for c in token)
    # (two letters a hand runs into one, and one it splits in two)
    return t.replace('rn', 'm').replace('cl', 'd').replace('vv', 'w')


def keywords(line, lang):
    """A word that is a keyword written the way a hand confuses it (`retum`, `ret0rn`, `Fut ure` is not handled) becomes the keyword."""
    words = KEYWORDS.get(lang, [])
    if not words:
        return line
    squashed = {}
    for w in words:
        squashed.setdefault(_squash(w), w)

    def fix(m):
        t = m.group(0)
        if t in words or len(t) < 4:
            return t
        s = _squash(t)
        # a word that differs from a keyword only by its capitals is the person's own (`list` is not Dart's `List`)
        if s in squashed and squashed[s].lower() != t.lower():
            return squashed[s]
        if len(t) >= 5:
            near = [w for w in words if len(w) >= 5 and abs(len(w) - len(t)) <= 1 and Levenshtein.distance(w.lower(), t.lower()) == 1]
            if len(near) == 1:
                return near[0]
        return t

    return re.sub(r'[A-Za-z0-9]+', fix, line)


def brackets(line, lang):
    """A ( or [ that was opened and not closed gets its closer at the end of the line (before `:`, `;` or a block's `{`)."""
    out = line
    for o, c in (('(', ')'), (('['), (']'))):
        extra = out.count(o) - out.count(c)
        if extra > 0:
            m = re.search(r'\s*[:;{]?\s*$', out)
            out = out[:m.start()] + c * extra + out[m.start():]
    return out


def typography(line, lang):
    """The characters a reader writes that code does not have: curly quotes, long dashes, multiplication and division signs."""
    t = line.replace('’', "'").replace('‘', "'").replace('“', '"').replace('”', '"').replace('„', '"')
    t = t.replace('–', '-').replace('—', '-').replace('×', '*').replace('÷', '/').replace('−', '-')
    t = t.replace('≤', '<=').replace('≥', '>=').replace('≠', '!=').replace('→', '->')
    return t


def spaces(line, lang):
    """No space inside a word the reader split (`pr int(`) is NOT repaired: too risky. Only runs of spaces are made one."""
    return re.sub(r' {2,}', ' ', line.strip())


RULES = {'typography': typography, 'keywords': keywords, 'brackets': brackets, 'spaces': spaces}


def repair(line, lang, rules=None):
    for name in rules or RULES:
        line = RULES[name](line, lang)
    return line
