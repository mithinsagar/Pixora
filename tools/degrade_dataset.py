"""Make harder copies of a person-folder dataset to test robustness: low light, blur, low resolution.
usage: python -I degrade_dataset.py <dataset_dir> <out_dir> <lowlight|blur|lowres>"""
import sys, random
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter
src, out, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
rng = np.random.default_rng(3)
for d in sorted(p for p in src.iterdir() if p.is_dir() or p.is_symlink()):
    d = d.resolve()
    (out / d.name).mkdir(parents=True, exist_ok=True)
    for f in sorted(d.glob("*.jpg")):
        im = Image.open(f).convert("RGB")
        if mode == "lowlight":   # ~2.5 stops under, gamma-crushed shadows, sensor noise
            a = np.asarray(im, dtype=np.float32) / 255.0
            a = (a * 0.18) ** 1.15 * 255.0 + rng.normal(0, 4.0, a.shape)
            im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
        elif mode == "blur":     # missed focus / motion
            im = im.filter(ImageFilter.GaussianBlur(radius=2.5))
        elif mode == "lowres":   # face ~30 px wide, as in a big group shot
            im = im.resize((70, 70), Image.BILINEAR).resize((250, 250), Image.BILINEAR)
        im.save(out / d.name / f.name, quality=88)
print("done", mode)
