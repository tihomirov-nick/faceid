#!/usr/bin/env python3
"""Converts the Silent-Face-Anti-Spoofing models (Minivision, Apache 2.0) to Core ML and checks them against PyTorch.

    python3 scripts/convert_spoof_models.py <folder with MiniFASNet.py and the .pth files> <output folder>

Writes MiniFASNetV2.mlpackage (2.7_80x80_MiniFASNetV2.pth) and MiniFASNetV1SE.mlpackage (4_0_0_80x80_MiniFASNetV1SE.pth).
Input "input": 1x3x80x80, B, G, R planes, values 0...255 (no normalization, as in the original code).
Output "logits": 3 numbers; after softmax, class 1 is a live face."""
import importlib.util
import os
import sys

import coremltools as ct
import numpy as np
import torch

MODELS = [("2.7_80x80_MiniFASNetV2.pth", "MiniFASNetV2"), ("4_0_0_80x80_MiniFASNetV1SE.pth", "MiniFASNetV1SE")]


def load_definitions(folder):
    spec = importlib.util.spec_from_file_location("MiniFASNet", os.path.join(folder, "MiniFASNet.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(src, dst):
    definitions = load_definitions(src)
    for weights, name in MODELS:
        # 80x80 input: the last depthwise convolution covers the whole 5x5 map (get_kernel in the original code).
        net = getattr(definitions, name)(conv6_kernel=(5, 5))
        state = torch.load(os.path.join(src, weights), map_location="cpu", weights_only=True)
        state = {k[7:] if k.startswith("module.") else k: v for k, v in state.items()}
        net.load_state_dict(state)
        net.eval()

        example = torch.rand(1, 3, 80, 80) * 255
        traced = torch.jit.trace(net, example)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="input", shape=(1, 3, 80, 80), dtype=np.float32)],
            outputs=[ct.TensorType(name="logits", dtype=np.float32)],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS14,
        )
        mlmodel.short_description = (f"Silent-Face-Anti-Spoofing {name} ({weights}): 80x80 face crop, B, G, R planes, "
                                     "0-255 -> logits for (spoof, live, spoof).")
        mlmodel.license = "Apache License 2.0 (Minivision Silent-Face-Anti-Spoofing)"
        path = os.path.join(dst, f"{name}.mlpackage")
        mlmodel.save(path)

        loaded = ct.models.MLModel(path)
        rng = np.random.default_rng(3)
        worst = 0.0
        for _ in range(8):
            x = rng.uniform(0, 255, (1, 3, 80, 80)).astype(np.float32)
            with torch.no_grad():
                reference = torch.softmax(net(torch.from_numpy(x)), 1).numpy()
            logits = loaded.predict({"input": x})["logits"]
            result = np.exp(logits - logits.max()) / np.exp(logits - logits.max()).sum()
            worst = max(worst, float(np.abs(reference - result).max()))
        print(f"{name}: Core ML vs PyTorch, largest probability difference {worst:.4f}")
        if worst > 0.02:
            sys.exit(f"{name}: the converted model differs from the original")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
