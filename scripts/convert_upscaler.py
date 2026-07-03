# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#     "torch==2.5.1",
#     "coremltools>=8.0",
#     "numpy<2.1",
# ]
# ///
"""Convert Real-ESRGAN's compact general model (realesr-general-x4v3) to a
Core ML package for the in-app 4x upscaler.

The architecture (SRVGGNetCompact) is defined inline so we don't need the
basicsr/realesrgan packages (their torchvision imports rot quickly). Weights
come from the official release. Output: assets/Upscaler.mlpackage, fp16
mlprogram, 512x512 image in -> 2048x2048 image out.

Run:  uv run scripts/convert_upscaler.py
"""

import urllib.request
from pathlib import Path

import coremltools as ct
import torch
import torch.nn as nn
import torch.nn.functional as F

WEIGHTS_URL = (
    "https://github.com/xinntao/Real-ESRGAN/releases/download/"
    "v0.2.5.0/realesr-general-x4v3.pth"
)
ROOT = Path(__file__).resolve().parent.parent
WEIGHTS = ROOT / "scripts" / "realesr-general-x4v3.pth"
OUTPUT = ROOT / "assets" / "Upscaler.mlpackage"
TILE = 512


class SRVGGNetCompact(nn.Module):
    """Real-ESRGAN's compact VGG-style SR net (matches the release weights)."""

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        body = [nn.Conv2d(num_in_ch, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        for _ in range(num_conv):
            body += [nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        body += [nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1)]
        self.body = nn.ModuleList(body)
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for module in self.body:
            out = module(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


class ImageWrapped(nn.Module):
    """Image-in/image-out: Core ML ImageType hands us 0..1 (via scale) and
    wants 0..255 back."""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, image):
        return (self.net(image) * 255.0).clamp(0.0, 255.0)


def main():
    if not WEIGHTS.exists():
        print(f"downloading weights -> {WEIGHTS}")
        urllib.request.urlretrieve(WEIGHTS_URL, WEIGHTS)
    state = torch.load(WEIGHTS, map_location="cpu", weights_only=True)
    params = state.get("params", state)

    net = SRVGGNetCompact()
    net.load_state_dict(params, strict=True)
    net.eval()
    model = ImageWrapped(net).eval()

    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0)],
        outputs=[ct.ImageType(name="upscaled")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = (
        "Real-ESRGAN general x4 (SRVGGNetCompact) — 512x512 tile in, 2048x2048 out"
    )
    OUTPUT.parent.mkdir(exist_ok=True)
    mlmodel.save(str(OUTPUT))
    print(f"saved {OUTPUT}")


if __name__ == "__main__":
    main()
