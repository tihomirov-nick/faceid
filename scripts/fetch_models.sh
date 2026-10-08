#!/bin/bash
# Downloads the face recognition model, checks its SHA-256 and converts it to Core ML.
# Result: Resources/SFace.mlpackage and its license. The converted model is in git; this script is only needed to
# rebuild it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DL="$ROOT/Vendor/downloads"
VENV="$DL/venv"

# opencv_zoo commit ba91a3b (2022-01-06), Apache 2.0
SFACE_URL="https://github.com/opencv/opencv_zoo/raw/ba91a3b91d00d76e86540d4013f944bd6b514e39/models/face_recognition_sface"

fetch() { # url destination sha256
    if [ ! -f "$2" ] || [ "$(shasum -a 256 "$2" | awk '{print $1}')" != "$3" ]; then
        mkdir -p "$(dirname "$2")"
        curl -sSL --fail -o "$2.download" "$1"
        actual=$(shasum -a 256 "$2.download" | awk '{print $1}')
        if [ "$actual" != "$3" ]; then
            rm -f "$2.download"
            echo "SHA256 mismatch for $(basename "$2")"
            exit 1
        fi
        mv "$2.download" "$2"
    fi
}

fetch "$SFACE_URL/face_recognition_sface_2021dec.onnx" "$DL/sface/face_recognition_sface_2021dec.onnx" \
    0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
fetch "$SFACE_URL/LICENSE" "$DL/sface/LICENSE" cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

# Python packages for the conversion (versions it was checked with).
if [ ! -x "$VENV/bin/python" ]; then
    /usr/bin/python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
fi
"$VENV/bin/pip" install -q numpy==2.0.2 onnx==1.19.1 onnx2torch==1.5.15 torch==2.8.0 coremltools==9.0 onnxruntime==1.19.2

rm -rf Resources/SFace.mlpackage
"$VENV/bin/python" -I scripts/convert_model.py "$DL/sface/face_recognition_sface_2021dec.onnx" Resources/SFace.mlpackage 2>&1 \
    | grep -E "Core ML vs|differs|Error" || true
[ -d Resources/SFace.mlpackage ] || { echo "conversion failed"; exit 1; }
cp "$DL/sface/LICENSE" Resources/LICENSE-sface.txt
echo "model converted OK"
