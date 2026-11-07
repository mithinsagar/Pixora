# Third-party notices

Pixora's own code is MIT-licensed (see [LICENSE](LICENSE)). The downloadable app also contains the following.

## InsightFace models: SCRFD-10G (face detection) and ArcFace R50 (face recognition)

- Source: the `buffalo_l` model pack from [deepinsight/insightface](https://github.com/deepinsight/insightface)
  (release v0.7), converted to Core ML with the scripts in `tools/`.
- License: the InsightFace code is MIT-licensed, but its **pretrained models are available for non-commercial research
  purposes only**. Because the app bundles them, **Pixora as distributed is for personal, non-commercial use**. For
  commercial use you would need to obtain a commercial licence from InsightFace or swap in models you are licensed to
  use.
- The model files are not stored in this repository; they are built by `tools/convert_scrfd.py` and
  `tools/convert_arcface.py` and included only in the release disk image.

## SigLIP 2 (optional search model)

- Source: [google/siglip2-giant-opt-patch16-384](https://huggingface.co/google/siglip2-giant-opt-patch16-384), Apache License 2.0.
- Changed for Pixora: converted to Core ML, weights compressed to 8 bits, output scaled to unit length, tokenizer repacked (`tools/convert_siglip2.py`, `tools/export_see_tokens.py`).
- Not part of the app or this repository. It's a separate download from this project's releases, with its licence and notice inside, fetched only when you ask for it.

## Apple frameworks

Vision, Core ML, CryptoKit, AVFoundation and the other system frameworks Pixora uses are part of macOS.

## Music

The optional "Soft tones" background music is synthesised by Pixora's own code while a slideshow plays; it contains no
recordings. Pixora ships no other music. Audio files you choose yourself are played from where they are and are not
copied or uploaded.

## Evaluation datasets

LFW, CPLFW and COCO 2017 were used only on the development machine to measure accuracy. They are not included in the app or in
this repository.
