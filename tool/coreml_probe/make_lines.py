"""Makes the test lines of the CoreML probe: sentences written in a handwriting font (Caveat, SIL Open Font License; not kept here,
pass its path), drawn like the app draws a line for GLM-OCR: 140 pixels high (10 rows of patches), black on white, padded on the right
to one of the app's widths (glmPaddedWidths in lib/ink/ink_image.dart, in columns of 28 pixels). No one's real handwriting.

  python make_lines.py FONT.ttf OUT_DIR
writes OUT_DIR/NN.png, a harder OUT_DIR/hNN.png of each, and OUT_DIR/truth.tsv (file, text).
"""
import os
import sys

import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

LINES = [
    'Meeting notes for Monday',
    'Buy milk, eggs and bread',
    'The lecture starts at 9:15 in room 204',
    'Hausaufgaben bis Freitag abgeben',
    'Die Lösung ist überraschend einfach',
    'Remember to call the dentist',
    'Chapter 3: linear algebra',
    'Prüfung am 12. Dezember',
    'This idea needs more work',
    'Zusammenfassung der Vorlesung',
    'Draft the report before lunch',
    'Wir treffen uns um halb acht',
    'Questions for the next session',
    'Ergebnis: 42 Punkte von 50',
    'Send the slides to Anna',
    'Grüße aus dem Büro',
    'The experiment failed twice',
    'Nächste Woche keine Übung',
    'Total cost was 128 francs',
    'Check the proof of lemma 2',
]
WIDTHS = [4, 6, 8, 12, 16, 24, 32, 48, 64, 96]  # (glmPaddedWidths, in columns of 28 pixels; the widest a line gets here)
HEIGHT = 140


def draw(text, font):
    left, top, right, bottom = font.getbbox(text)
    margin = 14
    width = right - left + 2 * margin
    columns = next(w for w in WIDTHS if w * 28 >= width)
    img = Image.new('RGB', (columns * 28, HEIGHT), 'white')
    d = ImageDraw.Draw(img)
    d.text((margin - left, (HEIGHT - (bottom - top)) / 2 - top), text, fill='black', font=font)
    return img


def draw_hard(text, font, seed):
    """The same sentence harder to read: smaller, every letter moved up or down a little, slanted, slightly blurred."""
    rnd = random.Random(seed)
    margin, x = 14, 14
    canvas = Image.new('L', (2800, HEIGHT), 255)
    d = ImageDraw.Draw(canvas)
    for ch in text:
        d.text((x, HEIGHT / 2 - 26 + rnd.uniform(-5, 5)), ch, fill=0, font=font)
        x += font.getlength(ch) + rnd.uniform(-1.5, 1.5)
    canvas = canvas.crop((0, 0, int(x) + margin, HEIGHT))
    canvas = canvas.transform(canvas.size, Image.AFFINE, (1, 0.18, -0.18 * HEIGHT / 2, 0, 1, 0), fillcolor=255)
    canvas = canvas.filter(ImageFilter.GaussianBlur(0.8))
    columns = next(w for w in WIDTHS if w * 28 >= canvas.size[0])
    img = Image.new('RGB', (columns * 28, HEIGHT), 'white')
    img.paste(canvas.convert('RGB'), (0, 0))
    return img


def main():
    font_path, out = sys.argv[1:3]
    os.makedirs(out, exist_ok=True)
    font = ImageFont.truetype(font_path, 64)
    small = ImageFont.truetype(font_path, 44)
    rows = []
    for i, text in enumerate(LINES):
        name = f'{i:02d}.png'
        draw(text, font).save(os.path.join(out, name), optimize=True)
        rows.append(f'{name}\t{text}')
        hard = f'h{i:02d}.png'
        draw_hard(text, small, i).save(os.path.join(out, hard), optimize=True)
        rows.append(f'{hard}\t{text}')
    with open(os.path.join(out, 'truth.tsv'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(rows) + '\n')


if __name__ == '__main__':
    main()
