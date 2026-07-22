#!/usr/bin/env python3
"""Render android/MainActivity.kt.tmpl over the Tauri-generated MainActivity.

The generated activity is a bare `class MainActivity : TauriActivity()`. We keep
its package, base class and imports (so however the CLI reaches TauriActivity
keeps working) and swap in our body, which adds immersive full screen and
back-navigation into the web app's view stack.

Usage: patch-main-activity.py <generated MainActivity.kt> <template>
"""
import re
import sys


def main() -> int:
    generated, template = sys.argv[1], sys.argv[2]
    src = open(generated, encoding="utf-8").read()

    pkg = re.search(r"^\s*package\s+([\w.]+)", src, re.M)
    if not pkg:
        print("no package declaration found in:\n" + src, file=sys.stderr)
        return 1

    cls = re.search(r"^\s*class\s+MainActivity\s*:\s*([\w.]+)\s*\(", src, re.M)
    if not cls:
        print("no MainActivity class declaration found in:\n" + src, file=sys.stderr)
        return 1

    # Imports the CLI emitted (TauriActivity may come in via one of them).
    imports = [ln.strip() for ln in src.splitlines() if ln.strip().startswith("import ")]
    # Drop any our template adds itself, so they can't be duplicated.
    ours = {"android.os.Build", "android.os.Bundle", "android.view.View",
            "android.view.ViewGroup", "android.webkit.WebView"}
    imports = [i for i in imports if i.removeprefix("import ").strip() not in ours]

    out = open(template, encoding="utf-8").read()
    out = out.replace("__PACKAGE__", pkg.group(1))
    out = out.replace("__BASE__", cls.group(1))
    out = out.replace("__IMPORTS__", "\n".join(imports))

    with open(generated, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("----- patched -----")
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
