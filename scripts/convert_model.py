#!/usr/bin/env python3
"""Converts SFace (OpenCV Zoo face_recognition_sface_2021dec.onnx, Apache 2.0) to Core ML and checks that
the Core ML model gives the same embeddings as the ONNX original.

    python3 scripts/convert_model.py <face_recognition_sface_2021dec.onnx> <SFace.mlpackage>

Needs numpy, onnx, onnx2torch, torch, coremltools and onnxruntime: scripts/fetch_model.sh installs them
into a virtual environment and runs this script."""
import sys

import coremltools as ct
import numpy as np
import onnx
import onnxruntime
import torch
from onnx2torch import convert


def cosine(a, b):
    a, b = a.ravel(), b.ravel()
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def main(src, dst):
    model = onnx.load(src)
    graph = model.graph
    # The MXNet export lists every weight as a graph input too; only the image is a real input.
    weights = {init.name for init in graph.initializer}
    inputs = [i for i in graph.input if i.name not in weights]
    del graph.input[:]
    graph.input.extend(inputs)
    assert [i.name for i in graph.input] == ["data"], [i.name for i in graph.input]

    net = convert(model).eval()
    example = torch.rand(1, 3, 112, 112) * 255
    traced = torch.jit.trace(net, example)

    # Input: aligned 112x112 face, RGB, 0...255 (the model subtracts 127.5 and divides by 128 itself).
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="data", shape=(1, 3, 112, 112), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = ("SFace face embedding: aligned 112x112 RGB face (0-255, NCHW) -> 128 numbers. "
                                 "Converted from OpenCV Zoo face_recognition_sface_2021dec.onnx.")
    mlmodel.license = "Apache License 2.0 (OpenCV Zoo face_recognition_sface)"
    mlmodel.version = "2021dec"
    mlmodel.input_description["data"] = "Aligned face, 1x3x112x112, RGB, values 0...255"
    mlmodel.output_description["embedding"] = "Face embedding, 1x128 (not normalized)"
    mlmodel.save(dst)

    # Same answers as the original: random images and smooth face-like gradients.
    options = onnxruntime.SessionOptions()
    options.log_severity_level = 3  # the MXNet export warns about every weight listed as an input
    session = onnxruntime.InferenceSession(src, options, providers=["CPUExecutionProvider"])
    loaded = ct.models.MLModel(dst)
    rng = np.random.default_rng(7)
    worst = 1.0
    for i in range(8):
        if i % 2:
            x = rng.uniform(0, 255, (1, 3, 112, 112)).astype(np.float32)
        else:
            base = np.linspace(0, 255, 112, dtype=np.float32)
            x = np.stack([np.add.outer(base, base[::-1]) / 2 * (0.6 + 0.2 * c) for c in range(3)])[None]
            x = np.clip(x + rng.normal(0, 12, x.shape), 0, 255).astype(np.float32)
        reference = session.run(None, {"data": x})[0]
        result = loaded.predict({"data": x})["embedding"]
        worst = min(worst, cosine(reference, result))
    print(f"Core ML vs ONNX: worst cosine similarity {worst:.5f}")
    if worst < 0.999:
        sys.exit("the converted model differs from the original")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
