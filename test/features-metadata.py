#!/usr/bin/env python3
"""Each add-on is a dev-container feature that a project's devcontainer.json
names (ghcr.io/ali-syria/sdd-workbench/<id>:1), so its metadata must hold:
the id is its folder's name, the version is semver, every option has a type
and a default of that type, and its install.sh is there and executable.

T5 (test/run.sh) already installs each add-on on the base and checks its
tools on both architectures; this checks what only the feature's packaging
says. Standard library only. Exit 1 on any problem."""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FEATURES = os.path.join(ROOT, "features")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
TYPES = {"string": str, "boolean": bool}


def problems_of(name):
    folder = os.path.join(FEATURES, name)
    out = []
    try:
        with open(os.path.join(folder, "devcontainer-feature.json"), encoding="utf-8") as fh:
            meta = json.load(fh)
    except (OSError, ValueError) as exc:
        return [f"{name}: devcontainer-feature.json unreadable: {exc}"]
    if meta.get("id") != name:
        out.append(f"{name}: id is {meta.get('id')!r}, not its folder's name")
    if not SEMVER.match(str(meta.get("version", ""))):
        out.append(f"{name}: version {meta.get('version')!r} is not x.y.z")
    if not meta.get("name") or not meta.get("description"):
        out.append(f"{name}: needs a name and a description")
    for option, spec in (meta.get("options") or {}).items():
        kind = TYPES.get(spec.get("type")) if isinstance(spec, dict) else None
        if kind is None:
            out.append(f"{name}: option {option} has no type a feature may declare")
            continue
        if not isinstance(spec.get("default"), kind):
            out.append(f"{name}: option {option}'s default is not a {spec['type']}")
        allowed = spec.get("enum")
        if allowed and spec.get("default") not in allowed:
            out.append(f"{name}: option {option}'s default is not one of its enum")
    script = os.path.join(folder, "install.sh")
    if not os.path.isfile(script):
        out.append(f"{name}: no install.sh")
    elif not os.access(script, os.X_OK):
        out.append(f"{name}: install.sh is not executable")
    return out


def main():
    names = sorted(n for n in os.listdir(FEATURES)
                   if os.path.isdir(os.path.join(FEATURES, n)))
    found = [p for n in names for p in problems_of(n)]
    for n in names:
        print(f"{'FAIL' if any(p.startswith(n + ':') for p in found) else 'ok  '}  {n}")
    for p in found:
        print(f"  {p}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
