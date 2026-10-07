#!/bin/bash
# Downloads the face recognition and anti-spoofing models, checks their SHA-256 and converts them to Core ML.
# Result: Resources/SFace.mlpackage, Resources/MiniFASNetV2.mlpackage, Resources/MiniFASNetV1SE.mlpackage
# and their licenses. The converted models are in git; this script is only needed to rebuild them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DL="$ROOT/Vendor/downloads"
VENV="$DL/venv"

# opencv_zoo commit ba91a3b (2022-01-06), Apache 2.0
SFACE_URL="https://github.com/opencv/opencv_zoo/raw/ba91a3b91d00d76e86540d4013f944bd6b514e39/models/face_recognition_sface"
# Silent-Face-Anti-Spoofing commit b6d5f04 (2020-08-05), Apache 2.0
FAS_URL="https://github.com/minivision-ai/Silent-Face-Anti-Spoofing/raw/b6d5f04ad78778917853b25c778acef6d5626d15"

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
fetch "$FAS_URL/src/model_lib/MiniFASNet.py" "$DL/minifasnet/MiniFASNet.py" \
    e498c4ec5e1ddfaba62b941a126c19d65aa564999f3309661fe43ee8bf38acd7
fetch "$FAS_URL/resources/anti_spoof_models/2.7_80x80_MiniFASNetV2.pth" "$DL/minifasnet/2.7_80x80_MiniFASNetV2.pth" \
    a5eb02e1843f19b5386b953cc4c9f011c3f985d0ee2bb9819eea9a142099bec0
fetch "$FAS_URL/resources/anti_spoof_models/4_0_0_80x80_MiniFASNetV1SE.pth" "$DL/minifasnet/4_0_0_80x80_MiniFASNetV1SE.pth" \
    84ee1d37d96894d5e82de5a57df044ef80a58be2b218b5ed7cdfd875ec2f5990
fetch "$FAS_URL/LICENSE" "$DL/minifasnet/LICENSE" daf94bf1dc9cc5700fe5af2c7c0cbd1836e70d509ed78fd0bebef7432edee6fb

# Python packages for the conversion (versions it was checked with).
if [ ! -x "$VENV/bin/python" ]; then
    /usr/bin/python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
fi
"$VENV/bin/pip" install -q numpy==2.0.2 onnx==1.19.1 onnx2torch==1.5.15 torch==2.8.0 coremltools==9.0 onnxruntime==1.19.2

rm -rf Resources/SFace.mlpackage Resources/MiniFASNetV2.mlpackage Resources/MiniFASNetV1SE.mlpackage
"$VENV/bin/python" -I scripts/convert_model.py "$DL/sface/face_recognition_sface_2021dec.onnx" Resources/SFace.mlpackage 2>&1 \
    | grep -E "Core ML vs|differs|Error" || true
"$VENV/bin/python" -I scripts/convert_spoof_models.py "$DL/minifasnet" Resources 2>&1 | grep -E "Core ML vs|differs|Error" || true
[ -d Resources/SFace.mlpackage ] && [ -d Resources/MiniFASNetV2.mlpackage ] && [ -d Resources/MiniFASNetV1SE.mlpackage ] \
    || { echo "conversion failed"; exit 1; }
cp "$DL/sface/LICENSE" Resources/LICENSE-sface.txt
cp "$DL/minifasnet/LICENSE" Resources/LICENSE-minifasnet.txt
echo "models converted OK"
