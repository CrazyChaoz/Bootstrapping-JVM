#!/usr/bin/env python3
"""dist-upstream.py CONFIG.json: the third-party part of a distribution laid out like the
published one (dist.nix with upstreamLock):

  - every component of the lock (dists/VERSION.json): its jar (from CONFIG's "jars", named as in
    the lock) and its registry entry (alias.*, dependencies, jarFile), in the lock's directory
    (dependencies on components not built left out);
  - LICENSE: the source tree's LICENSE and the license section of the components, as
    build-logic's GenerateLicenseFile writes it;
  - the source tree's packaging/distributions-full/src/toplevel files (NOTICE, README, init.d).

CONFIG: {"out", "lock", "jars": {component: jar path | null}, "license", "toplevel"}
"""
import json
import os
import shutil
import sys


def main(config_path):
    cfg = json.load(open(config_path))
    out = cfg["out"]
    lock = json.load(open(cfg["lock"]))

    # components of the lock whose jar is not built: a registry entry naming one would make
    # Gradle's module registry fail when it resolves it (native-platform's platform jars), so
    # they are left out of the dependencies (the one place where the entries differ)
    unbuilt = {k for k, c in lock["components"].items() if c["jarFile"] and cfg["jars"].get(k) is None}

    for key, c in lock["components"].items():
        d = os.path.join(out, c["dir"])
        os.makedirs(d, exist_ok=True)
        lines = [
            f"alias.group={c['group']}",
            f"alias.name={c['name']}",
            f"alias.version={c['version']}",
            "dependencies=" + ",".join(x for x in c["dependencies"] if x not in unbuilt),
        ]
        jar = cfg["jars"].get(key)
        if c["jarFile"]:
            if jar is None:
                continue  # not built (passthru.upstreamGaps)
            shutil.copyfile(jar, os.path.join(d, c["jarFile"]))
            lines.append(f"jarFile={c['jarFile']}")
        with open(os.path.join(d, key + ".properties"), "w") as f:
            f.write("\n".join(lines) + "\n")

    # GenerateLicenseFile
    sections = {}
    for c in lock["components"].values():
        coord = f"{c['group']}:{c['name']}"
        name, url = lock["licenses"][coord]
        sections.setdefault(name, (url, set()))[1].add(coord)
    text = open(cfg["license"], encoding="utf-8").read().rstrip()
    text += "\n\n\n" + "=" * 80 + "\nLicenses for included components:\n"
    for name in sorted(sections):
        url, coords = sections[name]
        text += "\n" + "-" * 80 + "\n" + name + "\n" + (url + "\n" if url else "") + "\n"
        text += "".join(c + "\n" for c in sorted(coords))
    with open(os.path.join(out, "LICENSE"), "w", encoding="utf-8") as f:
        f.write(text)

    for root, _, files in os.walk(cfg["toplevel"]):
        for name in files:
            src = os.path.join(root, name)
            dst = os.path.join(out, os.path.relpath(src, cfg["toplevel"]))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)


if __name__ == "__main__":
    main(sys.argv[1])
