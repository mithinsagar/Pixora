"""Convert InsightFace SCRFD-10G (buffalo_l / det_10g.onnx) face detector to Core ML for Pixora.

Licence as for convert_arcface.py (pretrained models: non-commercial research use).
Fixed 640x640 RGB input, pre-processing (x - 127.5) / 128 baked in. Outputs, for strides 8/16/32
(2 anchors per cell, row-major): score{s} [N,1] (sigmoid applied), bbox{s} [N,4] distances in stride units,
kps{s} [N,10] 5 landmark offsets in stride units. Decoding + NMS happen in Swift (SCRFDDetector).

usage: python convert_scrfd.py <path/to/det_10g.onnx> [output_dir]
"""
import sys
from pathlib import Path
import numpy as np, onnx, onnxruntime as ort, torch, coremltools as ct
from onnx2torch import convert
from PIL import Image

onnx_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "Models")
out_path = out_dir / "SCRFD10G.mlpackage"
model = convert(onnx.load(str(onnx_path))).eval()
traced = torch.jit.trace(model, torch.rand(1, 3, 640, 640))
names = ["score8", "score16", "score32", "bbox8", "bbox16", "bbox32", "kps8", "kps16", "kps32"]
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 640, 640), scale=1 / 128.0, bias=[-127.5 / 128.0] * 3,
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name=n) for n in names],
    convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT32,  # box/landmark offsets need more than fp16 precision
)
mlmodel.author = "Converted for Pixora from InsightFace buffalo_l det_10g (non-commercial research licence)"
mlmodel.short_description = "SCRFD-10G face detector with 5 landmarks, 640x640"
mlmodel.save(str(out_path))

rng = np.random.default_rng(1)
img = rng.integers(0, 256, (640, 640, 3), dtype=np.uint8)
x = ((img.astype(np.float32) - 127.5) / 128.0).transpose(2, 0, 1)[None]
sess = ort.InferenceSession(str(onnx_path))
ref = sess.run(None, {sess.get_inputs()[0].name: x})
got = ct.models.MLModel(str(out_path)).predict({"image": Image.fromarray(img)})
print(f"saved {out_path}")
for n, r in zip(names, ref):
    print(f"parity {n}: max abs diff {float(np.abs(np.asarray(got[n]).reshape(r.shape) - r).max()):.5f} (value range {float(r.min()):.2f}..{float(r.max()):.2f})")
