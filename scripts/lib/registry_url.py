"""Where is the instance registry? — the Python twin of registry-url.sh.

Order: RE_REGISTRY_URL; then the address startUniverse.sh wrote to
$CI_DIR/.universe-registry-url (removed by stopUniverse.sh when the shim stops);
then http://127.0.0.1:${RE_REGISTRY_PORT:-5999}/re-registry.json, the
fixed-port default. A literal :5999 is wrong under --free-ports, where the shim
takes an OS-assigned port.
"""
import os
from pathlib import Path

_CI_DIR = Path(__file__).resolve().parents[2]


def registry_url() -> str:
    env = os.environ.get("RE_REGISTRY_URL", "").strip()
    if env:
        return env
    try:
        path = os.environ.get("RE_UNIVERSE_REGISTRY_URL_FILE") or (_CI_DIR / ".universe-registry-url")
        first = Path(path).read_text().splitlines()[0].strip()
    except (OSError, IndexError):
        first = ""
    if first:
        return first
    return f"http://127.0.0.1:{os.environ.get('RE_REGISTRY_PORT', '5999')}/re-registry.json"
