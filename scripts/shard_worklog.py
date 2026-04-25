#!/usr/bin/env python3
"""Shard WORKLOG.md into worklog/<N>_<date>_<slug>.md chunks of ~200-300 lines.

Rules:
  * Greedy pack ## sections into chunks until adding the next would push past
    MAX_LINES; close the current chunk and start a new one.
  * If a single ## section is itself > MAX_LINES, split it at ### boundaries
    using the same greedy pack rules.
  * Filenames sort chronologically (oldest first) — we reverse the chunk list
    after packing because the source WORKLOG.md is reverse-chronological.
  * Preserve byte-for-byte content (so concatenating output in REVERSE order
    reproduces the input exactly).
"""

import re
import sys
from pathlib import Path

WORKLOG = Path("/home/tobiasosborne/Projects/Bennett.jl/WORKLOG.md")
OUT_DIR = Path("/home/tobiasosborne/Projects/Bennett.jl/worklog")

MIN_LINES = 200
MAX_LINES = 320  # small overhead allowed; lets some natural sections fit whole

DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
SLUG_RE = re.compile(r"[^a-z0-9]+")


def slugify(s: str, maxlen: int = 50) -> str:
    s = s.lower()
    s = SLUG_RE.sub("_", s).strip("_")
    return s[:maxlen].rstrip("_") or "section"


def parse_h2_sections(lines):
    sections = []
    cur_start = 0
    cur_heading = None
    for i, line in enumerate(lines):
        if line.startswith("## "):
            sections.append({
                "start": cur_start, "end": i,
                "heading": cur_heading, "lines": i - cur_start,
            })
            cur_start = i
            cur_heading = line.rstrip("\n")
    sections.append({
        "start": cur_start, "end": len(lines),
        "heading": cur_heading, "lines": len(lines) - cur_start,
    })
    return sections


def split_section_at_h3(section, lines):
    """If a single ## section exceeds MAX_LINES, split it into pieces at ### boundaries.
    Returns a list of pseudo-section dicts (each spans a contiguous line range and
    is treated as atomic by the packer). Each piece carries the parent's heading
    so file naming still works."""
    s, e = section["start"], section["end"]
    if section["lines"] <= MAX_LINES:
        return [section]
    # Find ### boundaries inside this section
    h3_positions = [i for i in range(s, e) if lines[i].startswith("### ")]
    if not h3_positions:
        return [section]  # nothing we can do
    # Build sub-section spans: [s..h3[0]), [h3[0]..h3[1]), ..., [h3[-1]..e)
    boundaries = [s] + h3_positions + [e]
    parts = []
    for i in range(len(boundaries) - 1):
        a, b = boundaries[i], boundaries[i + 1]
        if a == b:
            continue
        parts.append({
            "start": a, "end": b,
            "heading": section["heading"],  # all parts inherit the parent's H2
            "lines": b - a,
            "is_split": i > 0,
        })
    # Now greedy-pack the sub-section parts back into chunks ≤ MAX_LINES
    packed = []
    cur = []
    cur_size = 0
    for p in parts:
        if cur and cur_size + p["lines"] > MAX_LINES:
            packed.append(merge_parts(cur))
            cur = [p]
            cur_size = p["lines"]
        else:
            cur.append(p)
            cur_size += p["lines"]
    if cur:
        packed.append(merge_parts(cur))
    return packed


def merge_parts(parts):
    return {
        "start": parts[0]["start"],
        "end": parts[-1]["end"],
        "heading": parts[0]["heading"],
        "lines": sum(p["lines"] for p in parts),
    }


def section_date(section):
    if section["heading"] is None:
        return None
    m = DATE_RE.search(section["heading"])
    return m.group(1) if m else None


def section_slug(section):
    if section["heading"] is None:
        return "preamble"
    h = re.sub(r"^#+\s*", "", section["heading"])
    h = DATE_RE.sub("", h)
    h = re.sub(r"^\s*[—\-:]+\s*", "", h)
    return slugify(h)


def chunk_sections(sections):
    """Greedy pack: include sections until adding the next would exceed MAX_LINES."""
    chunks = []
    cur = []
    cur_size = 0
    for sec in sections:
        if not cur:
            cur, cur_size = [sec], sec["lines"]
            continue
        if cur_size + sec["lines"] > MAX_LINES:
            chunks.append(cur)
            cur, cur_size = [sec], sec["lines"]
            continue
        cur.append(sec)
        cur_size += sec["lines"]
    if cur:
        chunks.append(cur)
    return chunks


def main():
    raw = WORKLOG.read_text()
    lines = raw.splitlines(keepends=True)
    print(f"Read {len(lines)} lines from {WORKLOG}", file=sys.stderr)

    h2_sections = parse_h2_sections(lines)
    # Pre-split any over-MAX H2 sections at H3 boundaries
    flat_sections = []
    for s in h2_sections:
        flat_sections.extend(split_section_at_h3(s, lines))
    print(f"After H3 sub-splitting: {len(flat_sections)} pseudo-sections", file=sys.stderr)

    chunks = chunk_sections(flat_sections)
    chunks.reverse()  # so chunk 000 = oldest content
    print(f"Chunked into {len(chunks)} files", file=sys.stderr)

    # Wipe OUT_DIR contents (we own it)
    for f in OUT_DIR.iterdir():
        f.unlink()

    placements = []
    for ci, chunk in enumerate(chunks):
        first_dated = next((s for s in chunk if section_date(s)), None)
        if first_dated:
            d = section_date(first_dated)
        elif chunk[0]["heading"] is None:
            d = "0000-00-00"
        else:
            d = "9999-99-99"
        slug = section_slug(chunk[0])
        path = OUT_DIR / f"{ci:03d}_{d}_{slug}.md"
        chunk_text = "".join("".join(lines[sec["start"]:sec["end"]]) for sec in chunk)
        path.write_text(chunk_text)
        placements.append({
            "index": ci, "filename": path.name,
            "lines": sum(s["lines"] for s in chunk),
            "first_heading": chunk[0]["heading"] or "(preamble)",
            "n_sections": len(chunk),
        })

    # Verification: concat output in REVERSE order (chronological back to reverse-chrono)
    concat = "".join(
        (OUT_DIR / p["filename"]).read_text()
        for p in sorted(placements, key=lambda x: x["index"], reverse=True)
    )
    if concat == raw:
        print("OK: byte-for-byte match", file=sys.stderr)
    else:
        print(f"MISMATCH: input={len(raw)} bytes, output={len(concat)} bytes", file=sys.stderr)
        for i, (a, b) in enumerate(zip(raw, concat)):
            if a != b:
                print(f"  diverge at byte {i}: raw={a!r} vs concat={b!r}", file=sys.stderr)
                break
        sys.exit(2)

    # Size summary
    over = [p for p in placements if p["lines"] > MAX_LINES]
    under = [p for p in placements if p["lines"] < MIN_LINES]
    print(f"\nSize summary: {len(placements)} chunks, {len(over)} over MAX ({MAX_LINES}), {len(under)} under MIN ({MIN_LINES})", file=sys.stderr)
    for p in over:
        print(f"  OVER  {p['lines']:4d} {p['filename']}", file=sys.stderr)
    for p in under:
        print(f"  UNDER {p['lines']:4d} {p['filename']}", file=sys.stderr)

    print("---PLACEMENTS---")
    for p in placements:
        h = p["first_heading"].lstrip("#").strip()
        print(f"{p['filename']}\t{p['lines']}\t{h[:90]}")


if __name__ == "__main__":
    main()
