"""Draws the lines of lines.json from their strokes with PIL, for the readers that are not given the app's own pictures.
  python3 -P render.py OUT_DIR NAME HEIGHT PEN MARGIN   ->  OUT_DIR/NAME/<line>.png
HEIGHT = pixels of the ink's height (the tallest the line is), PEN = pen width as a part of HEIGHT, MARGIN = white around, as a part of HEIGHT.
Drawn 4x too big and shrunk, so the edges are smooth."""
import json, os, sys
from PIL import Image, ImageDraw

def render(strokes, height, pen, margin, ss=4):
    xs = [x for s in strokes for x in s[0::2]]; ys = [y for s in strokes for y in s[1::2]]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    sc = height / max(y1 - y0, 1.0)
    m = margin * height
    w = int((x1 - x0) * sc + 2 * m); h = int(height + 2 * m)
    im = Image.new('L', (w * ss, h * ss), 255); d = ImageDraw.Draw(im)
    pw = max(1, round(pen * height * ss))
    for s in strokes:
        q = [((x - x0) * sc + m) * ss for x in s[0::2]], [((y - y0) * sc + m) * ss for y in s[1::2]]
        pts = list(zip(*q))
        if len(pts) > 1:
            d.line(pts, fill=0, width=pw, joint='curve')
            for p in (pts[0], pts[-1]): d.ellipse((p[0] - pw / 2, p[1] - pw / 2, p[0] + pw / 2, p[1] + pw / 2), fill=0)
    return im.resize((w, h), Image.LANCZOS)

if __name__ == '__main__':
    out, name, height, pen, margin = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
    only = set(json.load(open(f'{out}/truth.json')))
    os.makedirs(f'{out}/{name}', exist_ok=True)
    for l in json.load(open(f'{out}/lines.json')):
        if l['id'] in only: render(l['strokes'], height, pen, margin).save(f"{out}/{name}/{l['id']}.png")
