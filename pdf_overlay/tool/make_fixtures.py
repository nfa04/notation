#!/usr/bin/env python3
"""Generate test fixtures for pdf_overlay.

Needs:  pip install reportlab pikepdf

Writes test/fixtures/*.pdf and test/fixtures/manifest.json.  The manifest is read
by both the Dart tests and tool/verify.py, so every fixture is described once.

Each overlay page paints, in *display* space (what the viewer shows):
  * a RED square in the top-left corner
  * a GREEN square in the bottom-right corner
  * a half-transparent YELLOW highlight around the page centre (ExtGState alpha)
  * the text "NOTE" (Helvetica, so the overlay carries a font resource)
verify.py renders the merged file and checks those pixels.
"""
import json
import os
import re

import pikepdf
from pikepdf import Array, Dictionary, Name
from reportlab.pdfgen import canvas

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "test", "fixtures"))
os.makedirs(OUT, exist_ok=True)


def path(name):
    return os.path.join(OUT, name)


# --------------------------------------------------------------------------- bases

def make_base(name, sizes, text_xy=None):
    """Plain reportlab PDF (classic xref table, PDF 1.4). One page per size.
    text_xy=(x, y) places the "PAGE n" label at a fixed point instead of near the top-left."""
    c = canvas.Canvas(path(name), pagesize=sizes[0], pageCompression=0)
    for i, (w, h) in enumerate(sizes):
        c.setPageSize((w, h))
        c.setFont("Helvetica", 18)
        x, y = text_xy if text_xy else (20, h - 70)
        c.drawString(x, y, "PAGE %d" % (i + 1))
        c.showPage()
    c.save()


def inherited(page, key):
    node = page.obj
    while node is not None:
        if key in node:
            return node[key]
        node = node.get("/Parent")
    return None


def geometry(pdf):
    """Display size (w, h) of every page, honouring inheritance, CropBox and /Rotate."""
    out = []
    for p in pdf.pages:
        media = [float(x) for x in inherited(p, "/MediaBox")]
        crop = inherited(p, "/CropBox")
        crop = [float(x) for x in crop] if crop is not None else media
        mx0, mx1 = sorted((media[0], media[2]))
        my0, my1 = sorted((media[1], media[3]))
        cx0, cx1 = sorted((crop[0], crop[2]))
        cy0, cy1 = sorted((crop[1], crop[3]))
        x0, x1, y0, y1 = max(mx0, cx0), min(mx1, cx1), max(my0, cy0), min(my1, cy1)
        if x1 <= x0 or y1 <= y0:
            x0, x1, y0, y1 = mx0, mx1, my0, my1
        rot = int(inherited(p, "/Rotate") or 0) % 360
        w, h = x1 - x0, y1 - y0
        out.append([h, w] if rot in (90, 270) else [w, h])
    return out


# ------------------------------------------------------------------------- overlays

def make_overlay(name, sizes, compress_with_pikepdf=False):
    c = canvas.Canvas(path(name), pagesize=sizes[0], pageCompression=0)
    for (w, h) in sizes:
        c.setPageSize((w, h))
        c.setFillColorRGB(1, 0, 0)
        c.rect(0, h - 40, 40, 40, fill=1, stroke=0)
        c.setFillColorRGB(0, 0.7, 0)
        c.rect(w - 40, 0, 40, 40, fill=1, stroke=0)
        c.saveState()
        c.setFillColorRGB(1, 1, 0)
        c.setFillAlpha(0.5)
        c.rect(w / 2 - 40, h / 2 - 15, 80, 30, fill=1, stroke=0)
        c.restoreState()
        c.setFillColorRGB(0, 0, 0)
        c.setFont("Helvetica", 10)
        c.drawString(w / 2 - 36, h / 2 - 4, "NOTE")
        c.showPage()
    c.save()
    if compress_with_pikepdf:
        # Overlay that is itself xref-stream + object-stream + Flate, like a modern writer would emit.
        with pikepdf.open(path(name), allow_overwriting_input=True) as pdf:
            pdf.save(path(name), object_stream_mode=pikepdf.ObjectStreamMode.generate,
                     compress_streams=True)


# ------------------------------------------------------------------------- fixtures

manifest = []


def register(name, targets=None, expect="ok", compress_overlay=False, note=""):
    with pikepdf.open(path(name + ".pdf")) as pdf:
        geo = geometry(pdf)
    if targets is None:
        targets = list(range(len(geo)))
    entry = {
        "name": name,
        "original": name + ".pdf",
        "overlay": name + ".overlay.pdf",
        "targets": targets,
        "geometry": geo,
        "expect": expect,
        "note": note,
    }
    make_overlay(entry["overlay"], [geo[t] for t in targets], compress_with_pikepdf=compress_overlay)
    manifest.append(entry)


A4 = (595.0, 842.0)
LETTER = (612.0, 792.0)

# 1. classic xref table, 3 pages, overlay on pages 0 and 2 only
make_base("classic.pdf", [A4, A4, LETTER])
register("classic", targets=[0, 2], note="classic xref table; overlay only for pages 0 and 2")

# 2. xref stream + object streams (page dicts live *inside* an object stream)
make_base("objstm.pdf", [A4, LETTER, A4])
with pikepdf.open(path("objstm.pdf"), allow_overwriting_input=True) as pdf:
    pdf.save(path("objstm.pdf"), object_stream_mode=pikepdf.ObjectStreamMode.generate,
             compress_streams=True)
register("objstm", compress_overlay=True,
         note="xref stream + compressed object streams; overlay is also xref-stream/Flate")

# 3. nested page tree, /Rotate + /MediaBox inherited from an intermediate /Pages node, CropBox on a leaf
make_base("inherit.pdf", [A4, A4, LETTER, A4])
with pikepdf.open(path("inherit.pdf"), allow_overwriting_input=True) as pdf:
    root_pages = pdf.Root.Pages
    p = list(pdf.pages)
    for leaf in p:                       # strip direct attributes so inheritance is needed
        for k in ("/MediaBox", "/Rotate", "/CropBox"):
            if k in leaf.obj:
                del leaf.obj[k]
    mid = pdf.make_indirect(Dictionary(
        Type=Name.Pages, Parent=root_pages, Count=2,
        Kids=Array([p[0].obj, p[1].obj]),
        MediaBox=Array([0, 0, 595, 842]), Rotate=90))
    p[0].obj.Parent = mid
    p[1].obj.Parent = mid
    p[1].obj.CropBox = Array([40, 60, 500, 700])      # CropBox on a leaf, Rotate inherited
    p[2].obj.MediaBox = Array([0, 0, 612, 792])       # leaf directly under root
    p[3].obj.MediaBox = Array([10, 20, 605, 862])     # non-zero origin
    p[3].obj.Rotate = 270
    root_pages.Kids = Array([mid, p[2].obj, p[3].obj])
    pdf.save(path("inherit.pdf"))
register("inherit", note="nested tree, inherited MediaBox/Rotate, leaf CropBox, offset MediaBox, Rotate 270")

# 4. /Annots as indirect array (page 0) and as direct array (page 1) with pre-existing link annots
make_base("annots.pdf", [A4, A4])
with pikepdf.open(path("annots.pdf"), allow_overwriting_input=True) as pdf:
    def link():
        return pdf.make_indirect(Dictionary(
            Type=Name.Annot, Subtype=Name.Link, Rect=Array([50, 50, 150, 80]),
            Border=Array([0, 0, 0]), A=Dictionary(S=Name.URI, URI=pikepdf.String("https://example.com"))))
    pdf.pages[0].obj.Annots = pdf.make_indirect(Array([link()]))
    pdf.pages[1].obj.Annots = Array([link()])
    pdf.save(path("annots.pdf"))
register("annots", note="existing /Annots: indirect array on page 0, direct array on page 1")

# 5. /Prev chain: classic file + hand-written incremental update (changes /Info)
make_base("prev.pdf", [A4, A4])
raw = open(path("prev.pdf"), "rb").read()
startxref = int(re.findall(rb"startxref\s+(\d+)", raw)[-1])
size = int(re.findall(rb"/Size (\d+)", raw)[-1])
root = re.findall(rb"/Root (\d+) 0 R", raw)[-1].decode()
ident = re.findall(rb"/ID\s*\[(.*?)\]", raw, re.S)[-1]
if not raw.endswith(b"\n"):
    raw += b"\n"
off = len(raw)
raw += b"%d 0 obj\n<< /Title (Incremental) >>\nendobj\n" % size
xref_off = len(raw)
raw += b"xref\n%d 1\n%010d 00000 n \n" % (size, off)
raw += (b"trailer\n<< /Size %d /Root %s 0 R /Info %d 0 R /Prev %d /ID [%s] >>\nstartxref\n%d\n%%%%EOF\n"
        % (size + 1, root.encode(), size, startxref, ident, xref_off))
open(path("prev.pdf"), "wb").write(raw)
register("prev", note="two xref sections linked with /Prev")

# 6. rotated + cropped + offset: every rotation on one file (direct attributes)
# label at (150, 300): inside the CropBox below, so pdftotext (which honours CropBox) still sees it
make_base("rotations.pdf", [A4, A4, A4, A4], text_xy=(150, 300))
with pikepdf.open(path("rotations.pdf"), allow_overwriting_input=True) as pdf:
    for i, pg in enumerate(pdf.pages):
        pg.obj.Rotate = 90 * i
        pg.obj.MediaBox = Array([50, 30, 50 + 595, 30 + 842])
        pg.obj.CropBox = Array([80, 60, 80 + 400, 60 + 600])
    pdf.save(path("rotations.pdf"))
register("rotations", note="Rotate 0/90/180/270, offset MediaBox, CropBox inside it")

# 6b. linearized ("fast web view"): the last startxref points at the first-page xref near the top
make_base("linearized.pdf", [A4, LETTER])
with pikepdf.open(path("linearized.pdf"), allow_overwriting_input=True) as pdf:
    pdf.save(path("linearized.pdf"), linearize=True)
register("linearized", note="linearized file; update is appended after it")

# 6c. damaged: startxref points into the middle of nowhere -> must be refused, not repaired
make_base("damaged.pdf", [A4])
raw = open(path("damaged.pdf"), "rb").read()
raw = re.sub(rb"startxref\s+\d+", b"startxref\n7", raw)
open(path("damaged.pdf"), "wb").write(raw)
register("damaged", expect="unsupported", note="corrupt startxref offset")

# 7. encrypted -> must be refused (UnsupportedPdfException), never produce a corrupt file
make_base("encrypted.pdf", [A4])
with pikepdf.open(path("encrypted.pdf"), allow_overwriting_input=True) as pdf:
    pdf.save(path("encrypted.pdf"), encryption=pikepdf.Encryption(owner="owner", user="", R=4))
with pikepdf.open(path("encrypted.pdf")) as pdf:
    geo = geometry(pdf)
make_overlay("encrypted.overlay.pdf", [geo[0]])
manifest.append({"name": "encrypted", "original": "encrypted.pdf", "overlay": "encrypted.overlay.pdf",
                 "targets": [0], "geometry": geo, "expect": "unsupported", "note": "RC4/AES encrypted"})

with open(path("manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
print("wrote %d fixtures to %s" % (len(manifest), OUT))
