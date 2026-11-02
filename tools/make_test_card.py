"""Build a fake camera card from a labelled face dataset (e.g. LFW) to test Pixora end to end.

Creates <out>/DCIM/100TEST/IMG_####.JPG: solo portraits plus side-by-side "group photos" of 2-3 people,
with EXIF capture dates in two events, two RAW+JPEG pairs (placeholder .CR3 files) and one corrupt file.
Ground truth goes to <manifest> (kept outside the card so the app can't see it).

usage: python -I make_test_card.py <dataset_dir> <out_card_dir> <manifest.json>
"""
import json, random, sys
from pathlib import Path
from PIL import Image

dataset, out, manifest_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
random.seed(7)
cast = {"A": "Serena_Williams", "B": "Tony_Blair", "C": "Hugo_Chavez", "D": "Jacques_Chirac"}
pools = {k: sorted((dataset / v).glob("*.jpg")) for k, v in cast.items()}
for k in pools: random.shuffle(pools[k])
take = {k: iter(v) for k, v in pools.items()}

plan = [("A",)] * 8 + [("B",)] * 8 + [("C",)] * 8 + [("D",)] * 5 \
     + [("A", "B")] * 6 + [("A", "C")] * 4 + [("B", "D")] * 3 + [("A", "B", "C")] * 2
random.shuffle(plan)
card = out / "DCIM" / "100TEST"
card.mkdir(parents=True, exist_ok=True)
truth = {}
for i, people in enumerate(plan, start=1):
    tiles = [Image.open(next(take[p])).convert("RGB") for p in people]
    canvas = Image.new("RGB", (250 * len(tiles), 250), (40, 40, 40))
    for j, t in enumerate(tiles): canvas.paste(t, (250 * j, 0))
    canvas = canvas.resize((canvas.width * 2, canvas.height * 2), Image.LANCZOS)
    day, hour = ("2026:09:12", 10 + i // 8) if i <= 22 else ("2026:10:03", 15 + (i - 22) // 8)
    exif = Image.Exif()
    exif[0x010F] = "Canon"; exif[0x0110] = "Canon EOS R6"
    exif.get_ifd(0x8769)[0x9003] = f"{day} {hour:02d}:{(i * 7) % 60:02d}:00"
    exif.get_ifd(0x8769)[0xA434] = "RF24-70mm F2.8 L IS USM"
    name = f"IMG_{i:04d}.JPG"
    canvas.save(card / name, quality=90, exif=exif)
    truth[name] = [cast[p] for p in people]
# A burst: 4 frames of A+B within ~1.5 s, small reframing, the last one slightly soft.
from PIL import ImageFilter
burst_tiles = [Image.open(next(take[p])).convert("RGB") for p in ("A", "B")]
for k in range(4):
    canvas = Image.new("RGB", (500, 250), (40, 40, 40))
    for j, t in enumerate(burst_tiles): canvas.paste(t, (250 * j, 0))
    canvas = canvas.crop((k * 3, k * 2, 500 - (3 - k) * 3, 250 - (3 - k) * 2)).resize((1000, 500), Image.LANCZOS)
    if k == 3: canvas = canvas.filter(ImageFilter.GaussianBlur(3))
    exif = Image.Exif()
    exif[0x010F] = "Canon"; exif[0x0110] = "Canon EOS R6"
    exif.get_ifd(0x8769)[0x9003] = f"2026:10:03 18:30:{10 + k // 2:02d}"
    name = f"IMG_{900 + k:04d}.JPG"
    canvas.save(card / name, quality=90, exif=exif)
    truth[name] = [cast["A"], cast["B"]]

# Two RAW+JPEG pairs (placeholder RAW bytes: never decoded, only paired and copied).
pairs = [n for n, p in truth.items() if len(p) == 2][:2]
for n in pairs: (card / n.replace(".JPG", ".CR3")).write_bytes(b"placeholder raw " * 64)
(card / "IMG_9999.JPG").write_bytes(b"not really a jpeg")
manifest_path.write_text(json.dumps({"cast": cast, "truth": truth, "raw_pairs": pairs, "corrupt": ["IMG_9999.JPG"]}, indent=1))
print(f"{len(truth)} photos, {len(pairs)} RAW pairs, 1 corrupt → {card}")
