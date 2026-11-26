"""Render the app icons from design/clapless/clapless-icon.svg with headless Chrome. Run from anywhere."""
import json, re, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
svg = (ROOT / "design/clapless/clapless-icon.svg").read_text()


def render(markup: str, size: int, out: Path, inset: float = 0.0):
    pad = size * inset
    box = size - 2 * pad
    sized = markup.replace("<svg ", '<svg width="100%" height="100%" ', 1)
    page = ('<html><body style="margin:0;background:transparent">'
            f'<div style="width:{box}px;height:{box}px;padding:{pad}px">{sized}</div></body></html>')
    with tempfile.TemporaryDirectory() as tmp:
        html = Path(tmp) / "icon.html"
        html.write_text(page)
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--default-background-color=00000000", f"--window-size={size},{size}",
                        f"--screenshot={out}", html.as_uri()], check=True, capture_output=True)


def catalog(path: Path, images):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2))


assets = ROOT / "Resources/Assets.xcassets"
assets.mkdir(parents=True, exist_ok=True)
(assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))

# iPhone: square and opaque, because iOS cuts the corners itself.
phone = assets / "AppIconPhone.appiconset"
catalog(phone, [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}])
render(re.sub(r' rx="116"', "", svg), 1024, phone / "icon-1024.png")

# Mac: the rounded tile with the usual margin around it.
mac = assets / "AppIconMac.appiconset"
mac.mkdir(parents=True, exist_ok=True)
master = mac / "icon_1024.png"
render(svg, 1024, master, inset=100 / 1024)
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        name = f"icon_{pixels}.png"
        if pixels != 1024:
            subprocess.run(["sips", "-z", str(pixels), str(pixels), str(master), "--out", str(mac / name)],
                           check=True, capture_output=True)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
catalog(mac, images)

ink = assets / "Ink.colorset"
ink.mkdir(parents=True, exist_ok=True)
(ink / "Contents.json").write_text(json.dumps({"colors": [{"idiom": "universal", "color": {"color-space": "srgb",
    "components": {"red": "0x0C", "green": "0x0C", "blue": "0x0E", "alpha": "1.000"}}}],
    "info": {"author": "xcode", "version": 1}}, indent=2))
print("icons written")
