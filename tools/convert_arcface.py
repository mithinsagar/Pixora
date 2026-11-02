"""Convert InsightFace's ArcFace R50 (buffalo_l / w600k_r50.onnx) to Core ML for Pixora.

Model: https://github.com/deepinsight/insightface (code MIT; the pretrained buffalo_l models are released for
non-commercial research use only — fine for personal use, check the terms before anything else).
Trained on WebFace600K; much more robust to pose, lighting and demographic variation than 2018-era FaceNet.

Input: 112x112 RGB face aligned with the standard 5-point ArcFace template; pre-processing (x - 127.5) / 127.5
is baked into the Core ML input. Output: 512-d embedding (L2-normalise before use).

usage: python convert_arcface.py <path/to/w600k_r50.onnx> [output_dir]
"""
import sys
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
import coremltools as ct
from onnx2torch import convert
from PIL import Image

onnx_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "Models")
out_dir.mkdir(parents=True, exist_ok=True)
out_path = out_dir / "ArcFaceR50.mlpackage"

model = convert(onnx.load(str(onnx_path))).eval()
example = torch.rand(1, 3, 112, 112) * 2 - 1
traced = torch.jit.trace(model, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), scale=1 / 127.5, bias=[-1.0] * 3,
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS14,
)
mlmodel.author = "Converted for Pixora from InsightFace buffalo_l w600k_r50 (non-commercial research licence)"
mlmodel.short_description = "ArcFace ResNet-50 (WebFace600K) 512-d face embedding, 5-point aligned 112x112 input"
mlmodel.user_defined_metadata["rollcall.embedderID"] = "arcface-r50-w600k"
mlmodel.user_defined_metadata["rollcall.alignment"] = "arcface5"
mlmodel.save(str(out_path))

# Parity: same random face through onnxruntime and Core ML.
rng = np.random.default_rng(0)
img = rng.integers(0, 256, (112, 112, 3), dtype=np.uint8)
x = ((img.astype(np.float32) - 127.5) / 127.5).transpose(2, 0, 1)[None]
sess = ort.InferenceSession(str(onnx_path))
ref = sess.run(None, {sess.get_inputs()[0].name: x})[0].ravel()
got = np.asarray(ct.models.MLModel(str(out_path)).predict({"face": Image.fromarray(img)})["embedding"]).ravel()
cos = float(np.dot(ref / np.linalg.norm(ref), got / np.linalg.norm(got)))
print(f"saved {out_path}")
print(f"parity cosine(onnxruntime, coreml) = {cos:.5f}")
