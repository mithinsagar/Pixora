"""Convert the FaceNet (InceptionResnetV1, VGGFace2) face-embedding network to Core ML.

Source network and weights: https://github.com/timesler/facenet-pytorch (MIT licence code;
weights originally trained by David Sandberg's facenet project on VGGFace2). Check the
VGGFace2 dataset terms yourself before any commercial use.

The produced model takes a 160x160 RGB face crop and returns a 512-d L2-normalised embedding.
Pre-processing (x - 127.5) / 128 is baked into the Core ML input, so the app can feed images directly.

Usage:  tools/.venv/bin/python tools/convert_facenet.py  [output_dir]
"""
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
from PIL import Image
from facenet_pytorch import InceptionResnetV1

out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Models")
out_dir.mkdir(parents=True, exist_ok=True)
out_path = out_dir / "FaceNet512.mlpackage"

model = InceptionResnetV1(pretrained="vggface2").eval()
example = torch.rand(1, 3, 160, 160) * 2 - 1
traced = torch.jit.trace(model, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="face", shape=(1, 3, 160, 160),
                         scale=1 / 128.0, bias=[-127.5 / 128.0] * 3,
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS14,
)
mlmodel.author = "Converted for Pixora from timesler/facenet-pytorch (MIT)"
mlmodel.short_description = "FaceNet InceptionResnetV1 (VGGFace2) 512-d face embedding"
mlmodel.user_defined_metadata["rollcall.cropScale"] = "1.3"
mlmodel.user_defined_metadata["rollcall.embedderID"] = "facenet-vggface2-512"
mlmodel.save(str(out_path))

# Parity check: same random image through PyTorch and Core ML.
rng = np.random.default_rng(0)
img = Image.fromarray(rng.integers(0, 256, (160, 160, 3), dtype=np.uint8))
x = (torch.from_numpy(np.asarray(img, dtype=np.float32)).permute(2, 0, 1)[None] - 127.5) / 128.0
with torch.no_grad():
    ref = model(x).numpy().ravel()
got = np.asarray(ct.models.MLModel(str(out_path)).predict({"face": img})["embedding"]).ravel()
got = got / np.linalg.norm(got)
print(f"saved {out_path}")
print(f"parity cosine(torch, coreml) = {float(np.dot(ref, got)):.5f}")
