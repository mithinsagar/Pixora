#!/usr/bin/env python3
"""Convert SigLIP 2 giant to Core ML for Pixora's search by what's in a photo.

usage: convert_siglip2.py OUT_DIR [vision|text|both]
Needs torch==2.7.0, numpy==2.2.6, coremltools==9.0 and transformers. Weights are Apache-2.0.
The vision model takes a 384x384 image and scales it to [-1, 1] itself; both models return a unit-length embedding.
"""
import os, sys
import coremltools as ct
import numpy as np
import torch
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
from transformers import AutoModel

REPO = "google/siglip2-giant-opt-patch16-384"
out, which = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "both")
model = AutoModel.from_pretrained(REPO, dtype=torch.float32, attn_implementation="eager").eval()

def embedding(o):
    return o.pooler_output if hasattr(o, "pooler_output") else o

class Vision(torch.nn.Module):
    def __init__(self): super().__init__(); self.m = model.vision_model
    def forward(self, image):
        return torch.nn.functional.normalize(self.m(pixel_values=image).pooler_output, dim=-1)

class Text(torch.nn.Module):
    def __init__(self): super().__init__(); self.m = model.text_model
    def forward(self, tokens):
        return torch.nn.functional.normalize(self.m(input_ids=tokens).pooler_output, dim=-1)

def save(mlmodel, name):
    mlmodel.save(os.path.join(out, f"{name}16.mlpackage"))
    config = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel", weight_threshold=2048))
    linear_quantize_weights(mlmodel, config).save(os.path.join(out, f"{name}8.mlpackage"))
    print("saved", name, flush=True)

with torch.no_grad():
    if which in ("vision", "both"):
        traced = torch.jit.trace(Vision().eval(), torch.zeros(1, 3, 384, 384), check_trace=False)
        print("traced vision", flush=True)
        m = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT16,
                       inputs=[ct.ImageType(name="image", shape=(1, 3, 384, 384), scale=1 / 127.5, bias=[-1, -1, -1], color_layout=ct.colorlayout.RGB)],
                       outputs=[ct.TensorType(name="embedding", dtype=np.float32)])
        save(m, "PixoraSeeVision")
    if which in ("text", "both"):
        traced = torch.jit.trace(Text().eval(), torch.ones(1, 64, dtype=torch.int32), check_trace=False)
        print("traced text", flush=True)
        m = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14, compute_precision=ct.precision.FLOAT16,
                       inputs=[ct.TensorType(name="tokens", shape=(1, 64), dtype=np.int32)],
                       outputs=[ct.TensorType(name="embedding", dtype=np.float32)])
        save(m, "PixoraSeeText")
