#!/usr/bin/env python3
"""Add Harbor's immersive + back-navigation behaviour to the generated MainActivity.

STRICTLY ADDITIVE. An earlier version replaced the whole class and dropped the
CLI's `enableEdgeToEdge()` call (which Tauri makes *before* super.onCreate) —
the app then crashed on launch. So we never touch what the CLI emitted; we only
append our own overrides before the class's closing brace, and immersive mode is
applied from onWindowFocusChanged (fires right after the activity appears)
rather than by editing onCreate.

Usage: patch-main-activity.py <generated MainActivity.kt> <snippet>
"""
import re
import sys

MARKER = "harborApplyImmersive"


def main() -> int:
    generated, snippet_path = sys.argv[1], sys.argv[2]
    src = open(generated, encoding="utf-8").read()

    if MARKER in src:
        print("already patched, nothing to do")
        return 0

    cls = re.search(r"^\s*class\s+MainActivity\s*:\s*[\w.]+\s*\([^)]*\)", src, re.M)
    if not cls:
        print("no MainActivity class declaration found in:\n" + src, file=sys.stderr)
        return 1

    snippet = open(snippet_path, encoding="utf-8").read().rstrip() + "\n"

    tail = src[cls.end():]
    if tail.lstrip().startswith("{"):
        # Class has a body: insert our members before its final closing brace.
        close = src.rstrip().rfind("}")
        if close == -1:
            print("could not find closing brace in:\n" + src, file=sys.stderr)
            return 1
        out = src[:close] + "\n" + snippet + "}\n"
    else:
        # Bodyless `class MainActivity : TauriActivity()` — give it one.
        out = src[:cls.end()] + " {\n" + snippet + "}\n" + tail

    # Imports our snippet needs, added only when absent.
    needed = ["android.os.Build", "android.view.View", "android.view.ViewGroup",
              "android.webkit.WebView"]
    missing = [i for i in needed if not re.search(rf"^\s*import\s+{re.escape(i)}\s*$", out, re.M)]
    if missing:
        pkg = re.search(r"^\s*package\s+[\w.]+\s*$", out, re.M)
        at = pkg.end() if pkg else 0
        out = out[:at] + "\n" + "".join(f"import {i}\n" for i in missing) + out[at:]

    with open(generated, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("----- patched -----")
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
