#!/usr/bin/env python3
"""Council runner: three models from three providers grade a document
against docs/council/rubric.md until they all accept (max rounds decided by
the caller). Resumable: all state lives under docs/council/<run>/round-<N>/
in the repository; every command is safe to re-run.

  selftest
  prepare   --run R --round N --doc PATH [--force]
  run       --run R --round N [--member codex|muse|opus ...] [--dry-run]
            [--timeout SEC] [--attempts K]
  status    --run R
  aggregate --run R --round N
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COUNCIL = ROOT / "docs" / "council"
RUBRIC = COUNCIL / "rubric.md"
CRITERIA = [f"C{i}" for i in range(1, 9)]
MEMBERS = ("codex", "muse", "opus")
VERDICTS = ("accept", "revise", "reject")
BACKOFF = (60, 180, 420)


# ---------------------------------------------------------------- schema

def schema():
    score = {"type": "integer", "minimum": 1, "maximum": 5}
    crit = {"type": "object", "additionalProperties": False,
            "properties": {"id": {"type": "string", "enum": CRITERIA},
                           "score": score,
                           "evidence": {"type": "string"},
                           "change": {"type": "string"}},
            "required": ["id", "score", "evidence", "change"]}
    issue = {"type": "object", "additionalProperties": False,
             "properties": {"id": {"type": "string"},
                            "section": {"type": "string"},
                            "scope": {"type": "string", "enum": ["core", "contract"]},
                            "severity": {"type": "string", "enum": ["S0", "S1"]},
                            "problem": {"type": "string"},
                            "fix": {"type": "string"}},
             "required": ["id", "section", "scope", "severity", "problem", "fix"]}
    prev = {"type": "object", "additionalProperties": False,
            "properties": {"id": {"type": "string"},
                           "status": {"type": "string",
                                      "enum": ["resolved", "partially", "unresolved", "regressed"]},
                           "note": {"type": "string"}},
            "required": ["id", "status", "note"]}
    top = {"criteria": {"type": "array", "minItems": 8, "maxItems": 8,
                        "items": crit},
           "blocking": {"type": "array", "items": issue},
           "previous_status": {"type": "array", "items": prev},
           "regressions": {"type": "array", "items": {"type": "string"}},
           "suggestions": {"type": "array", "items": {"type": "string"}},
           "verdict": {"type": "string", "enum": list(VERDICTS)},
           "path_to_accept": {"type": "string"},
           "summary": {"type": "string"}}
    top["verdict_core"] = {"type": "string", "enum": list(VERDICTS)}
    return {"type": "object", "additionalProperties": False,
            "properties": top, "required": list(top)}


def validate(r):
    errs = []
    if not isinstance(r, dict):
        return ["not an object"]
    cr = r.get("criteria")
    if not isinstance(cr, list):
        return ["criteria missing"]
    ids = [x.get("id") if isinstance(x, dict) else None for x in cr]
    for cid in CRITERIA:
        if ids.count(cid) != 1:
            errs.append(f"{cid} appears {ids.count(cid)} times")
    for x in cr:
        if not isinstance(x, dict):
            errs.append("criterion not an object")
            continue
        v = x.get("score")
        if not isinstance(v, int) or isinstance(v, bool) or not 1 <= v <= 5:
            errs.append(f"{x.get('id')}.score = {v!r} outside 1-5")
    if r.get("verdict") not in VERDICTS:
        errs.append(f"verdict = {r.get('verdict')!r}")
    bl = r.get("blocking")
    if not isinstance(bl, list):
        errs.append("blocking missing")
    else:
        for b in bl:
            if not isinstance(b, dict) or not all(
                    isinstance(b.get(k), str) for k in ("id", "section", "problem", "fix")):
                errs.append(f"blocking entry malformed: {b!r}"[:200])
    if r.get("verdict") == "accept" and bl:
        errs.append("verdict accept with non-empty blocking list")
    if not isinstance(r.get("suggestions"), list):
        errs.append("suggestions missing")
    if not isinstance(r.get("summary"), str):
        errs.append("summary missing")
    if not isinstance(r.get("path_to_accept"), str):
        errs.append("path_to_accept missing")
    for b in (r.get("blocking") or []):
        if isinstance(b, dict) and "scope" in b and b["scope"] not in ("core", "contract"):
            errs.append(f"blocking scope {b['scope']!r}")
    if "verdict_core" in r and r["verdict_core"] not in VERDICTS:
        errs.append("verdict_core invalid")
    return errs


# ----------------------------------------------------------------- state

def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def round_dir(run, rnd):
    return COUNCIL / run / f"round-{rnd}"


class State:
    def __init__(self, rdir):
        self.path = rdir / "state.json"
        self.lock = threading.Lock()
        self.d = json.loads(self.path.read_text()) if self.path.exists() else {}

    def save(self):
        atomic_write(self.path, json.dumps(self.d, indent=1))

    def update(self, member, **kw):
        with self.lock:
            m = self.d.setdefault("members", {}).setdefault(member, {})
            m.update(kw)
            m["updated"] = now()
            self.save()


def extract_json(text):
    """The last top-level JSON object in a member's output."""
    dec, last, i = json.JSONDecoder(), None, 0
    while True:
        j = text.find("{", i)
        if j < 0:
            return last
        try:
            obj, end = dec.raw_decode(text, j)
            last, i = obj, end
        except ValueError:
            i = j + 1


# --------------------------------------------------------------- prepare

def rubric_text(path=None):
    return Path(path or RUBRIC).read_text(encoding="utf-8")


def previous_round_context(run, rnd):
    if rnd <= 1:
        return ""
    prev = round_dir(run, rnd - 1)
    cons = prev / "consensus.json"
    resp = prev / "response.md"
    if not cons.exists():
        sys.exit(f"round {rnd - 1} has no consensus.json; aggregate it first")
    c = json.loads(cons.read_text())
    parts = [f"# Previous round ({rnd - 1})", "",
             "Verdicts: " + ", ".join(f"{m}: {v}" for m, v in c["verdicts"].items()),
             "", "Blocking issues raised last round:"]
    for m, issues in c["blocking"].items():
        for b in issues:
            parts.append(f"- [{m}] {b['id']} ({b['section']}): {b['problem']} "
                         f"Fix proposed: {b['fix']}")
    if not any(c["blocking"].values()):
        parts.append("- none")
    parts += ["", "## Editor's response (what changed, what was declined and why)", ""]
    parts.append(resp.read_text(encoding="utf-8") if resp.exists()
                 else "(no response recorded)")
    parts += ["", "Re-grade the revised document below from scratch on the absolute "
              "scale. For each blocking issue above, state in your summary whether "
              "it is resolved; re-raise it in `blocking` only if it is not.", ""]
    return "\n".join(parts)


DEFAULT_SUBJECT = ("the founding vision for a from-scratch reboot of Bennett "
                   "(a reversible / quantum compiler toolchain; see the document)")


CONVERGENCE = (
    "Convergence rules for this council (read before grading):\n"
    "1. Blocking means S0 only: two conformant implementations built from the text would "
    "compute different results, the semantics is unsound or self-contradictory, or a normative "
    "decision is missing where one is needed to build. Tag every blocking issue with "
    "`scope` (`core` = machine model, instruction set, regions, validity, memory, formal model, "
    "examples; `contract` = targets, objects/identity, launch, scheduling, certificate, coverage, "
    "grammar) and `severity` (`S0` as defined; `S1` = an implementer would have to choose, but "
    "any choice yields a conformant machine). S1 items belong in `suggestions`, not `blocking`, "
    "unless the document fails to state a default for them.\n"
    "2. Implementation will expose frictions; that is expected and acceptable. Do not block on "
    "field-level completeness of C headers, JSON schemas, numerical procedures or encodings "
    "when the normative obligation is stated and a default is given; list such gaps as "
    "suggestions. Do block on anything that would make an executor compute a different function.\n"
    "3. Fill `previous_status` for every blocking issue of the previous round (by id) with "
    "resolved | partially | unresolved | regressed and a one-line note. List in `regressions` "
    "anything that was correct in the previous snapshot and is wrong now.\n"
    "4. Give `verdict_core` (accept/revise/reject) for the core scope alone, and `verdict` "
    "for the whole document. Core consensus is reached when every member returns "
    "verdict_core = accept with no core-scoped blocking issue.\n"
    "5. A diff from the previous snapshot is attached when one exists: confirm fixes there "
    "first, then re-read the whole document for new S0 issues.\n"
    "6. Formal correctness is pursued after practical revisions, by the maintainer's decision: "
    "in this phase the specification needs correct *statements* with explicit hypotheses, not "
    "proofs. Demands for proof formats, mechanisation, rigorous numerical or SDP witness "
    "schemas, or checker algorithms are S1 (suggestions) as long as the obligation and a default "
    "procedure are stated. Block only on a statement that is false, unsound or ambiguous.\n")


def build_prompt(doc_text, run, rnd, subject=None, rubric=None, contexts=(), diff_text=None):
    task = (
        "You are a member of a three-model council grading the document "
        f"below, {subject or DEFAULT_SUBJECT}. Grade "
        "it against the rubric on the absolute scale. Be exacting and "
        "skeptical: verify every technical premise against your own "
        "knowledge; name any that is false. Grade the vision for being the "
        "right vision, stated precisely; do not deduct for things that are "
        "not built yet. A blocking issue is one that would make the project "
        "build the wrong thing if uncorrected; everything else is a "
        "suggestion. Return `accept` only if the blocking list is empty.\n\n"
        "Be constructive, not only critical: for every blocking issue the "
        "`fix` field must say concretely how to overcome it, at vision level "
        "(the sentence or semantics the document should state, or the "
        "decision it should take), not merely that it is wrong. Where you see "
        "two viable ways out, name both and say which you would take. In "
        "`path_to_accept`, state the minimal set of changes that would make "
        "you return `accept`; if you already accept, say what would raise "
        "the lowest-scoring criterion by one point.\n\n"
        "You may read the repository you are running in (read-only) to check "
        "claims about the current code; its root contains Bennett-NorthStar.md "
        "(the document, identical to the snapshot below), "
        "Bennett-Reboot-Blueprint.md and Bennett-V2-PRD.md (the superseded "
        "plans), worklog/ (session logs; chunk 121 has the 2026-10-28 ground-"
        "truth survey), reviews/2026-09-26-astra/ (the last review campaign), "
        "and src/ (the deprecated v1). Reading is optional; the snapshot "
        "below is what you grade.\n\n"
        "Answer only with JSON matching the schema.")
    ctx = []
    if diff_text:
        ctx.append("# Diff from the previous round's snapshot (unified)\n\n```diff\n" + diff_text + "\n```")
    for c in contexts:
        ctx.append(f"# Background (not graded): `{Path(c).name}`\n\n"
                   + Path(c).read_text(encoding="utf-8"))
    return "\n\n".join(p for p in [
        "# Council", task, CONVERGENCE, previous_round_context(run, rnd),
        "# Rubric", rubric_text(rubric), *ctx,
        f"# The document under review (round {rnd} snapshot)",
        doc_text] if p)


def prepare(a):
    rdir = round_dir(a.run, a.round)
    if rdir.exists() and any(rdir.glob("out-*.json")) and not a.force:
        sys.exit(f"{rdir} already has member output; use --force to re-prepare")
    doc = Path(a.doc)
    text = doc.read_text(encoding="utf-8")
    if a.precheck:
        print(f"precheck: {a.precheck}")
        p = subprocess.run(a.precheck, shell=True, cwd=ROOT)
        if p.returncode != 0:
            sys.exit("precheck FAILED; the round is not prepared")
    diff_text = None
    prev = round_dir(a.run, a.round - 1) / "doc.md"
    if a.round > 1 and prev.exists():
        import difflib
        diff_text = "".join(difflib.unified_diff(
            prev.read_text(encoding="utf-8").splitlines(True), text.splitlines(True),
            fromfile=f"round-{a.round - 1}/doc.md", tofile=f"round-{a.round}/doc.md", n=2))
        atomic_write(rdir / "diff.patch", diff_text)
    sha = hashlib.sha256(text.encode()).hexdigest()
    rdir.mkdir(parents=True, exist_ok=True)
    atomic_write(rdir / "doc.md", text)
    atomic_write(rdir / "prompt.md", build_prompt(
        text, a.run, a.round, subject=a.subject, rubric=a.rubric,
        contexts=a.context or (), diff_text=diff_text if not a.no_diff else None))
    atomic_write(rdir / "schema.json", json.dumps(schema(), indent=1))
    st = State(rdir)
    st.d.update({"run": a.run, "round": a.round, "doc": str(doc),
                 "doc_sha256": sha, "prepared": now(), "members": {},
                 "rubric": a.rubric or str(RUBRIC), "subject": a.subject,
                 "context": list(a.context or [])})
    st.save()
    print(f"prepared {rdir} (doc sha256 {sha[:12]}, prompt "
          f"{len((rdir / 'prompt.md').read_text())} chars)")


# ------------------------------------------------------------------- run

def member_cmd(m, rdir):
    sch = rdir / "schema.json"
    prompt = rdir / "prompt.md"
    out = rdir / f"out-{m}.json"
    env = dict(os.environ)
    stdin = subprocess.DEVNULL
    if m == "codex":
        cmd = ["codex", "exec", "-m", "gpt-6-astra",
               "-c", "model_reasoning_effort=xhigh", "-s", "read-only",
               "--ephemeral", "--skip-git-repo-check",
               "--output-schema", str(sch), "-o", str(out), "--", "-"]
        stdin = open(prompt, "rb")
    elif m == "muse":
        cmd = ["muse", "exec", "--model", "muse-wonder-full-1.0",
               "--reasoning-effort", "high", "--output-schema", str(sch),
               "--prompt-file", str(prompt), "--workspace", str(ROOT),
               "--disable-web-tools", "--disable-reminders",
               "--disable-request-user-input", "--no-session-log"]
    elif m == "opus":
        for k in list(env):
            if k == "CLAUDECODE" or k.startswith("CLAUDE_CODE_"):
                env.pop(k)
        cmd = ["claude", "-p", "--model", "opus", "--output-format", "json",
               "--json-schema", sch.read_text(), "--allowedTools", "Read",
               "Grep", "Glob", "--max-turns", "40"]
        stdin = open(prompt, "rb")
    else:
        raise ValueError(m)
    return cmd, env, stdin, out


def parse_member_output(m, stdout, out):
    if m == "codex":
        if out.exists():
            return extract_json(out.read_text(encoding="utf-8"))
        return extract_json(stdout)
    if m == "opus":
        obj = extract_json(stdout)
        if isinstance(obj, dict):
            so = obj.get("structured_output")
            if isinstance(so, dict):
                return so
            return extract_json(obj.get("result") or "") or obj
        return obj
    return extract_json(stdout)


def run_member(m, rdir, st, timeout, attempts, dry):
    cmd, env, stdin, out = member_cmd(m, rdir)
    shown = " ".join(shlex.quote(c) if len(c) < 120 else f"<{len(c)} chars>"
                     for c in cmd)
    print(f"[{m}] {shown}")
    if dry:
        if stdin is not subprocess.DEVNULL:
            stdin.close()
        return
    prev = st.d.get("members", {}).get(m, {}).get("attempts", 0)
    for k in range(prev, prev + attempts):
        st.update(m, status="running", attempts=k + 1, started=now())
        t0 = time.time()
        try:
            if stdin is not subprocess.DEVNULL:
                stdin.seek(0)
            p = subprocess.run(cmd, capture_output=True, text=True, env=env,
                               stdin=stdin, timeout=timeout, cwd=ROOT)
            rc, so, se = p.returncode, p.stdout, p.stderr
        except subprocess.TimeoutExpired as e:
            rc, so, se = -1, (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or ""), f"TIMEOUT after {timeout}s"
        secs = round(time.time() - t0)
        atomic_write(rdir / f"raw-{m}-{k + 1}.txt",
                     f"exit {rc} in {secs}s\n--stdout--\n{so}\n--stderr--\n{se}")
        obj = parse_member_output(m, so, out) if rc == 0 else None
        errs = validate(obj) if obj is not None else ["no JSON object in output"]
        if rc == 0 and not errs:
            atomic_write(out, json.dumps(obj, indent=1))
            st.update(m, status="done", exit=rc, seconds=secs)
            print(f"[{m}] done in {secs}s (attempt {k + 1})")
            if stdin is not subprocess.DEVNULL:
                stdin.close()
            return
        if out.exists() and errs:
            out.unlink()  # codex wrote an invalid last message; do not keep it
        st.update(m, status="failed", exit=rc, seconds=secs, errors=errs[:5])
        print(f"[{m}] attempt {k + 1} failed (exit {rc}, {secs}s): {errs[:3]}")
        if k + 1 < prev + attempts:
            wait = BACKOFF[min(k, len(BACKOFF) - 1)]
            print(f"[{m}] retrying in {wait}s")
            time.sleep(wait)
    if stdin is not subprocess.DEVNULL:
        stdin.close()


def run_cmd(a):
    rdir = round_dir(a.run, a.round)
    if not (rdir / "prompt.md").exists():
        sys.exit(f"{rdir} not prepared")
    st = State(rdir)
    members = a.member or list(MEMBERS)
    todo = []
    for m in members:
        out = rdir / f"out-{m}.json"
        if out.exists() and not validate(json.loads(out.read_text())):
            print(f"[{m}] already done; skipping")
            continue
        todo.append(m)
    threads = [threading.Thread(target=run_member,
                                args=(m, rdir, st, a.timeout, a.attempts, a.dry_run))
               for m in todo]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    missing = [m for m in members if not (rdir / f"out-{m}.json").exists()]
    if a.dry_run:
        return
    if missing:
        print(f"INCOMPLETE: {missing}; re-run `run` to retry")
        sys.exit(2)
    print("all members done")


# ---------------------------------------------------------------- status

def status_cmd(a):
    base = COUNCIL / a.run
    if not base.exists():
        sys.exit(f"no run {a.run}")
    for rdir in sorted(base.glob("round-*")):
        st = State(rdir).d
        print(f"{rdir.name}: prepared {st.get('prepared')} doc {st.get('doc_sha256', '')[:12]}")
        for m in MEMBERS:
            s = st.get("members", {}).get(m, {})
            done = (rdir / f"out-{m}.json").exists()
            print(f"  {m:6} {'done ' if done else s.get('status', 'pending'):8}"
                  f" attempts={s.get('attempts', 0)} {s.get('errors', '') or ''}")
        c = rdir / "consensus.json"
        if c.exists():
            cj = json.loads(c.read_text())
            print(f"  consensus: agree={cj['agree']} verdicts={cj['verdicts']}")


# ------------------------------------------------------------- aggregate

def aggregate_cmd(a):
    rdir = round_dir(a.run, a.round)
    outs = {}
    for m in MEMBERS:
        f = rdir / f"out-{m}.json"
        if not f.exists():
            print(f"{m}: no output")
            continue
        r = json.loads(f.read_text())
        errs = validate(r)
        if errs:
            print(f"{m}: rejected: {errs}")
            continue
        outs[m] = r
    if not outs:
        sys.exit("no valid member output")
    names = list(outs)
    by = {m: {x["id"]: x for x in r["criteria"]} for m, r in outs.items()}
    lines = [f"# Council — {a.run} round {a.round}", "",
             f"Document snapshot sha256 {State(rdir).d.get('doc_sha256', '')[:12]}; "
             f"rubric {State(rdir).d.get('rubric', 'docs/council/rubric.md')}. "
             f"Members: {', '.join(names)}. "
             "Scores are advisory.", "",
             "| | " + " | ".join(names) + " | mean | spread ≥ 2 |",
             "|---|" + "---|" * (len(names) + 2)]
    means = []
    for cid in CRITERIA:
        v = [by[m][cid]["score"] for m in names]
        mean = round(sum(v) / len(v), 2)
        means.append(mean)
        lines.append(f"| {cid} | " + " | ".join(map(str, v)) +
                     f" | {mean} | {'yes' if max(v) - min(v) >= 2 else ''} |")
    verdicts = {m: outs[m]["verdict"] for m in names}
    blocking = {m: outs[m]["blocking"] for m in names}
    agree = (len(names) == len(MEMBERS) and all(v == "accept" for v in verdicts.values())
             and not any(blocking.values()))
    core_verdicts = {m: outs[m].get("verdict_core") for m in names}
    core_blocking = {m: [b for b in blocking[m] if b.get("scope") == "core"] for m in names}
    core_agree = (len(names) == len(MEMBERS) and all(v == "accept" for v in core_verdicts.values())
                  and not any(core_blocking.values()))
    lines += ["", f"Overall mean: {round(sum(means) / len(means), 2)}",
              "", "Verdicts: " + ", ".join(f"**{m}: {v}**" for m, v in verdicts.items()),
              "", "Core verdicts: " + ", ".join(f"**{m}: {v}**" for m, v in core_verdicts.items()),
              "", f"**Consensus: {'YES' if agree else 'no'}**   **Core consensus: {'YES' if core_agree else 'no'}**",
              "", "Blocking by scope/severity: " + ", ".join(
                  f"{m}: core {sum(1 for b in blocking[m] if b.get('scope') == 'core')} / "
                  f"contract {sum(1 for b in blocking[m] if b.get('scope') == 'contract')}"
                  f" (S0 {sum(1 for b in blocking[m] if b.get('severity') == 'S0')})" for m in names), ""]
    regs = {m: outs[m].get("regressions") or [] for m in names}
    if any(regs.values()):
        lines += ["## Regressions reported", ""] + [f"- **[{m}]** {r}" for m in names for r in regs[m]] + [""]
    ps = {m: outs[m].get("previous_status") or [] for m in names}
    if any(ps.values()):
        lines += ["## Previous-round blockers, status", ""]
        for m in names:
            for e in ps[m]:
                lines.append(f"- [{m}] {e['id']}: **{e['status']}** — {e['note']}")
        lines.append("")
    lines += ["## Blocking issues", ""]
    n = 0
    for m in names:
        for b in blocking[m]:
            n += 1
            lines.append(f"- **[{m}] {b['id']}** ({b['section']}; {b.get('scope', '?')}/{b.get('severity', '?')}): "
                         f"{b['problem']} *Fix:* {b['fix']}")
    if n == 0:
        lines.append("- none")
    for m in names:
        r = outs[m]
        lines += ["", f"## {m}", "", r["summary"], "",
                  f"**Path to accept:** {r.get('path_to_accept', '')}", ""]
        lines += [f"- **{x['id']} {x['score']}**: {x['evidence']} *Change:* {x['change']}"
                  for x in r["criteria"]]
        lines += ["", "Suggestions:"] + [f"{i + 1}. {s}" for i, s in enumerate(r["suggestions"])]
    atomic_write(rdir / "report.md", "\n".join(lines) + "\n")
    atomic_write(rdir / "consensus.json", json.dumps(
        {"agree": agree, "core_agree": core_agree, "verdicts": verdicts, "core_verdicts": core_verdicts,
         "blocking": blocking, "means": dict(zip(CRITERIA, means)), "members": names}, indent=1))
    print(f"wrote {rdir / 'report.md'}; consensus agree={agree} verdicts={verdicts}")


# -------------------------------------------------------------- selftest

def selftest():
    good = {"criteria": [{"id": c, "score": 3, "evidence": "e", "change": "c"}
                         for c in CRITERIA],
            "blocking": [], "suggestions": ["s"], "verdict": "accept", "summary": "ok",
            "path_to_accept": "none", "verdict_core": "accept", "previous_status": [], "regressions": []}
    assert validate(good) == [], validate(good)
    bad = json.loads(json.dumps(good))
    bad["criteria"][0]["score"] = 6
    bad["verdict"] = "accept"
    bad["blocking"] = [{"id": "B1", "section": "§3", "scope": "core", "severity": "S0", "problem": "p", "fix": "f"}]
    errs = validate(bad)
    assert any("outside 1-5" in e for e in errs) and any("accept with non-empty" in e for e in errs), errs
    assert validate({"criteria": "x"}) == ["criteria missing"]
    assert extract_json('noise {"a": 1} more {"b": [1,2]} tail') == {"b": [1, 2]}
    assert extract_json("none") is None
    opus_wrap = json.dumps({"type": "result", "structured_output": good, "result": "x"})
    assert parse_member_output("opus", opus_wrap, Path("/nonexistent")) == good
    sch = schema()
    assert set(sch["required"]) >= {"criteria", "blocking", "suggestions", "verdict", "path_to_accept", "summary"}
    assert "verdict_core" in sch["properties"] and "previous_status" in sch["properties"]
    with tempfile.TemporaryDirectory() as td:
        rdir = Path(td)
        atomic_write(rdir / "prompt.md", "p")
        atomic_write(rdir / "schema.json", json.dumps(sch))
        for m in MEMBERS:
            cmd, env, stdin, out = member_cmd(m, rdir)
            assert cmd[0] == m if m != "opus" else cmd[0] == "claude", cmd
            if m == "opus":
                assert not any(k.startswith("CLAUDE_CODE_") or k == "CLAUDECODE" for k in env)
                assert "--allowedTools" in cmd and cmd[-1] != "p", "prompt must go on stdin"
            if m == "codex":
                assert cmd[-1] == "-" and stdin is not subprocess.DEVNULL
            if stdin is not subprocess.DEVNULL:
                stdin.close()
        st = State(rdir)
        st.update("codex", status="running", attempts=1)
        assert json.loads((rdir / "state.json").read_text())["members"]["codex"]["attempts"] == 1
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    p = sub.add_parser("prepare")
    p.add_argument("--run", required=True)
    p.add_argument("--round", type=int, required=True)
    p.add_argument("--doc", required=True)
    p.add_argument("--force", action="store_true")
    p.add_argument("--rubric", help="rubric path (default docs/council/rubric.md)")
    p.add_argument("--subject", help="one phrase describing the document")
    p.add_argument("--context", action="append",
                   help="background document(s) appended to the prompt, not graded")
    p.add_argument("--precheck", help="shell command that must exit 0 before the round is prepared")
    p.add_argument("--no-diff", action="store_true", help="do not attach the diff from the previous round")
    r = sub.add_parser("run")
    r.add_argument("--run", required=True)
    r.add_argument("--round", type=int, required=True)
    r.add_argument("--member", action="append", choices=MEMBERS)
    r.add_argument("--dry-run", action="store_true")
    r.add_argument("--timeout", type=int, default=3600)
    r.add_argument("--attempts", type=int, default=4)
    s = sub.add_parser("status")
    s.add_argument("--run", required=True)
    g = sub.add_parser("aggregate")
    g.add_argument("--run", required=True)
    g.add_argument("--round", type=int, required=True)
    a = ap.parse_args()
    {"selftest": lambda a: selftest(), "prepare": prepare, "run": run_cmd,
     "status": status_cmd, "aggregate": aggregate_cmd}[a.cmd](a)


if __name__ == "__main__":
    main()
