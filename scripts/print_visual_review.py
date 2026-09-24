"""Make CI-rendered JPEG review copies accessible through text-only job connectors."""
import base64
from pathlib import Path
import sys

directory = Path(sys.argv[1])
images = sorted(directory.glob("*.jpg"))
assert images, "No review images: the render test must run, not skip"
for path in images:
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    print(f"LUMEN_VISUAL_BEGIN|{path.stem}|native")
    for offset in range(0, len(encoded), 4096):
        print(encoded[offset:offset + 4096])
    print(f"LUMEN_VISUAL_END|{path.stem}")
print(f"Rendered {len(images)} production SwiftUI review states.")
