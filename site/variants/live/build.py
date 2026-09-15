#!/usr/bin/env python3
"""Build the LIVE business-portal preview (real sign-in, production backend).

Pulls the production files from origin/main (behavior identical to the live
site) and layers the V5 light theme (site/variants/v5-theme.css) on top —
the same theme the mock V5 preview evaluates. Nothing functional is changed.

Output (mirrors the /biz/signin/ layout so relative refs resolve):
    site/variants/live/signin/index.html
    site/variants/live/portal.css      (origin/main, verbatim)
    site/variants/live/portal.js       (origin/main, verbatim)

Regenerate with:  python3 site/variants/live/build.py   (from the worktree root)
"""
import re
import subprocess
import sys
from pathlib import Path

WORKTREE = Path(__file__).resolve().parents[3]   # build.py -> live -> variants -> site -> root
OUT = WORKTREE / "site" / "variants" / "live"
THEME_VERSION = "1"


def git_show(ref_path: str) -> str:
    r = subprocess.run(
        ["git", "show", f"origin/main:{ref_path}"],
        cwd=WORKTREE, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"git show failed for {ref_path}:\n{r.stderr}")
    return r.stdout


def main() -> None:
    (OUT / "signin").mkdir(parents=True, exist_ok=True)

    html = git_show("site/biz/signin/index.html")
    css = git_show("site/biz/portal.css")
    js = git_show("site/biz/portal.js")

    # normalize cache-busters (the live preview is redeployed explicitly)
    html = re.sub(r"\.\./portal\.css\?v=\d+", "../portal.css", html)
    html = re.sub(r"\.\./portal\.js\?v=\d+", "../portal.js", html)

    # layer the V5 light theme after the portal stylesheet
    theme_link = (
        f'  <link rel="stylesheet" href="../../v5-theme.css?v={THEME_VERSION}">\n'
    )
    anchor = '<link rel="stylesheet" href="../portal.css">'
    assert anchor in html, "portal.css link not found in signin HTML"
    html = html.replace(anchor, anchor + "\n" + theme_link, 1)

    # preview chrome: a small badge so the live page is never mistaken for prod
    badge = (
        '<div class="live-preview-badge" style="position:fixed;top:10px;left:50%;'
        "transform:translateX(-50%);z-index:100;background:rgba(24,20,12,.88);"
        "color:#ffd98a;font:700 10.5px/1 Inter,system-ui,sans-serif;"
        "letter-spacing:.14em;padding:8px 14px;border-radius:999px;"
        'border:1px solid rgba(212,166,0,.35);white-space:nowrap;">'
        "LIVE PREVIEW · REAL SIGN-IN · STAGING ONLY</div>\n"
    )
    m = re.search(r"<body[^>]*>", html)
    assert m, "no <body> in signin HTML"
    html = html[:m.end()] + "\n" + badge + html[m.end():]

    (OUT / "signin" / "index.html").write_text(html)
    (OUT / "portal.css").write_text(css)
    (OUT / "portal.js").write_text(js)

    # sanity: every id the theme overrides must exist in the page
    for sel in ["authView", "chatsView", "phoneStep", "emailStep", "codeStep",
                "codeTarget", "leadsList", "threadCard", "phoneForm",
                "authForm", "codeForm"]:
        assert f'id="{sel}"' in html, f"missing id {sel}"
    print(f"live preview built in {OUT} "
          f"(html {len(html)//1024}k, css {len(css)//1024}k, js {len(js)//1024}k)")


if __name__ == "__main__":
    main()
