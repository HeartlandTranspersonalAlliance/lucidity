"""Source and real static-export contracts. No services or network calls."""
import hashlib
import json
from pathlib import Path
import re
import sys

manifest = json.loads(Path(sys.argv[1]).read_text())
source = Path(sys.argv[2])
config = json.loads((source / "config.json").read_text())
placeholders = sorted(re.findall(r"\$([A-Z0-9_]+)", json.dumps(config)))
assert placeholders == manifest["placeholders"], "public runtime contract changed"
runtime_hash = "0c949f4996f9a89698e4b5c586de32249c3b69b7baadb64d220073cc04acba14"
assert hashlib.sha256((source / "public/wasm_exec.js").read_bytes()).hexdigest() == runtime_hash
assert config["authClientSecret"] == "$AUTH_CLIENT_SECRET"
assert 'output: "export"' in (source / "next.config.js").read_text()
assert (source / "src/assets/fonts/Inter.ttf").stat().st_size > 0
assert "GNU AFFERO GENERAL PUBLIC LICENSE" in (source / "LICENSE").read_text()
assert json.loads((source / "package.json").read_text())["engines"]["node"] == ">=24.0.0"
assert json.loads((source / "package-lock.json").read_text())["lockfileVersion"] == 3
assert 'https://pkgs.netbird.io/wasm/client/v0.81.3' in (source / "src/utils/config.ts").read_text()
assert 'fetch(WASM_CONFIG.WASM_PATH)' in (source / "src/modules/remote-access/useNetBirdClient.ts").read_text()

if len(sys.argv) == 4:
    out = Path(sys.argv[3])
    for name in ["index.html", "wasm_exec.js", "OidcTrustedDomains.js.tmpl",
                 "licenses/netbird-dashboard-LICENSE", "licenses/Inter-OFL.txt",
                 "licenses/THIRD-PARTY-LICENSES.txt", "licenses/netbird-client-LICENSE",
                 "licenses/Go-LICENSE", "licenses/IronRDP-LICENSE-MIT",
                 "licenses/IronRDP-LICENSE-APACHE", "licenses/SOURCES.txt"]:
        assert (out / name).stat().st_size > 0, name
    assert hashlib.sha256((out / "wasm_exec.js").read_bytes()).hexdigest() == runtime_hash
    assert (out / "_next/static").is_dir()
    wasm = (out / "netbird-client.wasm").read_bytes()
    assert wasm[:4] == b"\0asm"
    assert hashlib.sha256(wasm).hexdigest() == "7823ff6ed813387cebb4f0337da4acd81f09d0c5cd40ed99f069340aa38140a0"
    del wasm
    assets = {
        "ironrdp_web.d.ts": "a7818512bb18bd5cc3f237d616e6a203742c7152a60aaffca336b8f12dc67678",
        "ironrdp_web.js": "d325a35d6c86d7a83f0ca48079898323ec03d96c6f93ba2f824317476bcda207",
        "ironrdp_web_bg.wasm": "7f83df3fdd07985e90e74f932aa9a0ad4fa3debb07d36b3430004f1b2c20ae33",
        "ironrdp_web_bg.wasm.d.ts": "df61fad9d7c70c9b4f850be687efb699f10676da3b6dd989e384985c8d387fa1",
    }
    for name, digest in assets.items():
        assert hashlib.sha256((out / "ironrdp-pkg" / name).read_bytes()).hexdigest() == digest, name
    # Runtime rendering is deliberately deferred. Every public placeholder must
    # survive Next's actual export; evaluating the derivation alone cannot prove it.
    found = set()
    local_client = False
    for path in out.rglob("*.js"):
        text = path.read_text()
        found.update(re.findall(r"\$([A-Z0-9_]+)", text))
        local_client |= "/netbird-client.wasm" in text
        assert "https://pkgs.netbird.io/wasm/client/v0.81.3" not in text
    assert local_client, "same-origin browser client fallback missing"
    assert set(placeholders) <= found, f"lost runtime placeholders: {set(placeholders) - found}"
    assert "$NETBIRD_MGMT_API_ENDPOINT" in (out / "OidcTrustedDomains.js.tmpl").read_text()
    assert not (out / "node_modules").exists()
print("NetBird dashboard contract passed")
