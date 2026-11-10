#!/usr/bin/env python3
"""Independently verify merged PDFs (does not use any pdf_overlay code).

    python3 tool/verify.py [outdir]        # default: build/test_out

`dart test` writes <outdir>/<name>.pdf for every fixture in test/fixtures/manifest.json.
Checks, per fixture:
  * the original file is an exact byte-prefix of the output (pure incremental update)
  * `qpdf --check` is clean (exit code 0, i.e. no errors *and* no warnings)
  * same page count; every target page gained exactly one Stamp annotation with an
    appearance stream; untouched pages keep their annotations
  * page text is still extractable (pdftotext) -> content was not rasterised
  * poppler render: RED top-left, GREEN bottom-right, translucent YELLOW centre on
    target pages, and no red on non-target pages; render size matches the page's
    display size (CropBox + /Rotate aware)
Encrypted fixtures must be *refused*: no output file may exist.

Needs: pikepdf, Pillow, and the qpdf + poppler-utils (pdftoppm, pdftotext) binaries.
"""
import json
import os
import subprocess
import sys
import tempfile

import pikepdf
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.normpath(os.path.join(HERE, "..", "test", "fixtures"))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(os.path.join(HERE, "..", "build", "test_out"))

failures = []


def fail(name, msg):
    failures.append("%s: %s" % (name, msg))
    print("   FAIL  " + msg)


def render(pdf, page_no, tmp):
    prefix = os.path.join(tmp, "p")
    subprocess.run(["pdftoppm", "-cropbox", "-r", "72", "-f", str(page_no), "-l", str(page_no),
                    "-png", "-singlefile", pdf, prefix], check=True, capture_output=True)
    return Image.open(prefix + ".png").convert("RGB")


def is_red(px):
    return px[0] > 200 and px[1] < 60 and px[2] < 60


def is_green(px):
    return px[1] > 120 and px[0] < 60 and px[2] < 60


def is_yellowish(px):
    return px[0] > 230 and px[1] > 230 and 90 < px[2] < 180


def annot_count(pdf, i):
    a = pdf.pages[i].obj.get("/Annots")
    return 0 if a is None else len(a)


def check(entry):
    name = entry["name"]
    print("* %s  (%s)" % (name, entry["note"]))
    out = os.path.join(OUT, name + ".pdf")

    if entry["expect"] == "unsupported":
        if os.path.exists(out):
            fail(name, "must be refused but an output file exists")
        else:
            print("   ok    refused (no output written)")
        return

    if not os.path.exists(out):
        fail(name, "output missing: %s" % out)
        return
    original = open(os.path.join(FIX, entry["original"]), "rb").read()
    merged = open(out, "rb").read()

    if merged[:len(original)] != original:
        fail(name, "original bytes are not an exact prefix of the output")
    else:
        print("   ok    original is an exact prefix (+%d bytes)" % (len(merged) - len(original)))

    q = subprocess.run(["qpdf", "--check", out], capture_output=True, text=True)
    if q.returncode != 0:
        fail(name, "qpdf --check exit %d\n%s" % (q.returncode, (q.stdout + q.stderr).strip()))
    else:
        print("   ok    qpdf --check clean")

    geo, targets = entry["geometry"], entry["targets"]
    with pikepdf.open(out) as pdf, pikepdf.open(os.path.join(FIX, entry["original"])) as orig:
        if len(pdf.pages) != len(orig.pages):
            fail(name, "page count changed")
            return
        for i in range(len(pdf.pages)):
            before, after = annot_count(orig, i), annot_count(pdf, i)
            expected = before + (targets.count(i))
            if after != expected:
                fail(name, "page %d: %d annots, expected %d" % (i, after, expected))
            if i in targets:
                stamps = [a for a in pdf.pages[i].obj.Annots
                          if a.get("/Subtype") == "/Stamp" and "/AP" in a]
                if len(stamps) != targets.count(i):
                    fail(name, "page %d: stamp annotations missing" % i)

    with tempfile.TemporaryDirectory() as tmp:
        for i, (w, h) in enumerate(geo):
            img = render(out, i + 1, tmp)
            if abs(img.size[0] - round(w)) > 1 or abs(img.size[1] - round(h)) > 1:
                fail(name, "page %d renders %dx%d, expected %dx%d" % (i, img.size[0], img.size[1], w, h))
                continue
            W, H = img.size
            tl, br, ctr = img.getpixel((20, 20)), img.getpixel((W - 20, H - 20)), img.getpixel((W // 2, H // 2))
            if i in targets:
                bad = [n for n, ok in (("red top-left", is_red(tl)), ("green bottom-right", is_green(br)),
                                       ("yellow centre", is_yellowish(ctr))) if not ok]
                if bad:
                    fail(name, "page %d overlay wrong: %s (tl=%s br=%s ctr=%s)" % (i, ", ".join(bad), tl, br, ctr))
            elif is_red(tl) or is_green(br):
                fail(name, "page %d is not a target but shows overlay colours" % i)
        print("   ok    rendered %d pages, overlay pixels checked" % len(geo))

        txt = subprocess.run(["pdftotext", out, "-"], capture_output=True, text=True).stdout
        missing = ["PAGE %d" % (i + 1) for i in range(len(geo)) if "PAGE %d" % (i + 1) not in txt]
        if missing:
            fail(name, "text no longer extractable: %s" % missing)
        else:
            print("   ok    page text still extractable")


manifest = json.load(open(os.path.join(FIX, "manifest.json")))
for e in manifest:
    check(e)
print()
if failures:
    print("%d FAILURE(S):" % len(failures))
    for f in failures:
        print(" - " + f)
    sys.exit(1)
print("ALL %d FIXTURES OK" % len(manifest))
