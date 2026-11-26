#!/usr/bin/env python3
"""Check the relative links of README.md and docs/*.md: each linked file
exists and each #anchor names a heading of its page (GitHub's slugs). Also
checks that every docs page starts with front matter (title, description,
order). Run by scripts/ci.sh; exits 1 listing every broken link."""
import glob
import os
import re
import sys

LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
FENCE = re.compile(r"^(```|~~~)")


def slug(heading):
    s = heading.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def anchors(path):
    seen, out = {}, set()
    fenced = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if FENCE.match(line):
                fenced = not fenced
            if fenced:
                continue
            m = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
            if m:
                base = slug(re.sub(r"`|\*|\[([^\]]*)\]\([^)]*\)", r"\1", m.group(1)))
                n = seen.get(base, 0)
                seen[base] = n + 1
                out.add(base if n == 0 else f"{base}-{n}")
    return out


def links(path):
    fenced = False
    with open(path, encoding="utf-8") as fh:
        for no, line in enumerate(fh, 1):
            if FENCE.match(line):
                fenced = not fenced
            if fenced:
                continue
            line = re.sub(r"`[^`]*`", "", line)
            for m in LINK.finditer(line):
                yield no, m.group(1)


BARE_TAG = re.compile(r"</?[A-Za-z][\w.-]*>")


def bare_tags(path):
    """Lines with a bare <word> outside code spans and fences: Markdown renderers
    treat it as an unknown HTML tag and drop it, so the reader loses the text."""
    fenced = False
    with open(path, encoding="utf-8") as fh:
        for no, line in enumerate(fh, 1):
            if FENCE.match(line.lstrip()):
                fenced = not fenced
                continue
            if fenced:
                continue
            for m in BARE_TAG.finditer(re.sub(r"`[^`]*`", "", line)):
                yield no, m.group(0)


def main():
    pages = ["README.md"] + sorted(glob.glob("docs/*.md"))
    bad = []
    for page in pages[1:]:
        for no, tag in bare_tags(page):
            bad.append(f"{page}:{no}: bare {tag} outside a code span is dropped by HTML renderers; escape it or use backticks")
    for page in pages:
        if page.startswith("docs/"):
            with open(page, encoding="utf-8") as fh:
                head = fh.read().split("\n---\n", 1)[0]
            if not head.startswith("---\n") or any(f"\n{k}:" not in head for k in ("title", "description", "order")):
                bad.append(f"{page}: front matter needs title, description and order")
        for no, target in links(page):
            if re.match(r"^[a-z]+:", target):
                continue
            file, _, anchor = target.partition("#")
            dest = os.path.normpath(os.path.join(os.path.dirname(page), file)) if file else page
            if not os.path.exists(dest):
                bad.append(f"{page}:{no}: {target}: no such file")
                continue
            if anchor and dest.endswith(".md") and anchor not in anchors(dest):
                bad.append(f"{page}:{no}: {target}: no heading #{anchor} in {dest}")
    for b in bad:
        print(b)
    if bad:
        print(f"{len(bad)} docs problem(s)")
        sys.exit(1)


if __name__ == "__main__":
    main()
