#!/usr/bin/env python3
"""Pre-flight check for Bennett-ISA-Spec.md: the example objects must parse,
their hashes must follow the spec's own envelope rule, and their stated
semantics must hold on a reference interpreter. Run before every council
round (council.py prepare --precheck "python3 tools/isa_check.py").

What it implements (from the spec text; version-pinned by the header line):
  - §16  canonical text: header, section order, data lines, function blocks
  - §9.2 semantic envelope + SCC hashing (Tarjan over @symbol references)
  - §14.1 reference interpreter for the lifted subset the examples use:
         lift.const.iN lift.add lift.sub lift.icmp.* lift.zext.iM lift.mov
         lift.addr lift.boundscheck lift.load.iN lift.call lift.ret
         lift.retval qjump qbranch, with activation records, alloctab
         pre-entries, budgets (steps/depth) and fault codes
Exit 1 on any mismatch; prints what differed.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

SPEC = Path(__file__).resolve().parent.parent / "Bennett-ISA-Spec.md"
SECTION_ORDER = ["symbols", "imports", "functions", "data", "devices", "layout",
                 "schedule", "certificate", "coverage"]
FAULT = {"NONE": 0, "STEPS": 1, "HEAP": 2, "DEPTH": 3, "TRAP": 4, "DIV0": 5,
         "SDIV": 6, "MEMFAULT": 7, "EFFECT": 8, "CALLEE": 9}


def jcs(o):
    return json.dumps(o, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(b):
    return hashlib.sha256(b).hexdigest()


# ----------------------------------------------------------------- parsing

def extract_examples(text):
    """Code blocks that start with 'bennett-object' are example objects."""
    blocks = re.findall(r"```\n(bennett-object[^\n]*\n.*?)```", text, re.S)
    return [b.rstrip("\n") + "\n" for b in blocks]


def parse_object(obj):
    lines = obj.rstrip("\n").split("\n")
    assert lines[0].startswith("bennett-object "), "missing header"
    hdr = dict(kv.split("=") for kv in lines[0].split(" ")[1:])
    sections, cur, order = {}, None, []
    i = 1
    while i < len(lines):
        ln = lines[i]
        if ln == "":
            assert i + 1 < len(lines) and lines[i + 1].startswith("section "), \
                f"blank line not followed by section at line {i}"
            i += 1
            continue
        if ln.startswith("section "):
            cur = ln.split(" ", 1)[1]
            assert cur in SECTION_ORDER, f"unknown section {cur}"
            assert cur not in sections, f"duplicate section {cur}"
            order.append(cur)
            sections[cur] = []
            i += 1
            continue
        assert cur is not None, "content before any section"
        sections[cur].append(ln)
        i += 1
    assert order == [s for s in SECTION_ORDER if s in order], f"section order {order}"
    for s in order:
        if s not in ("functions", "data"):
            assert len(sections[s]) == 1, f"section {s} must be one JSON line"
            sections[s] = json.loads(sections[s][0])
            raw = lines[[k for k, l in enumerate(lines) if l == "section " + s][0] + 1]
            assert jcs(sections[s]) == raw, f"section {s} is not JCS-canonical"
    return hdr, sections


def parse_functions(lines):
    """Split the functions section into functions; each: header, regs, blocks."""
    fns, cur = [], None
    for ln in lines:
        if re.match(r"^(fn (cc|r)|oracle|action|perm_action|lproc) @", ln):
            cur = {"head": ln, "regs": None, "blocks": [], "lines": [ln]}
            m = re.match(r"^(?:fn (?:cc|r)|oracle|action|perm_action|lproc) @([A-Za-z_][A-Za-z0-9_.]*) (.*)$", ln)
            cur["kind"] = ln.split(" ")[0] if not ln.startswith("fn") else ln.split(" ")[1]
            cur["name"] = m.group(1)
            # five parenthesised lists
            cur["plists"] = re.findall(r"\(([^()]*)\)", m.group(2))
            fns.append(cur)
        elif ln.startswith("regs "):
            cur["regs"] = ln
            cur["lines"].append(ln)
        elif ln.startswith("^"):
            m = re.match(r"^\^([A-Za-z_][A-Za-z0-9_.]*)\((.*)\):$", ln)
            cur["blocks"].append({"name": m.group(1), "instrs": []})
            cur["lines"].append(ln)
        else:
            assert cur and cur["blocks"], f"instruction outside a block: {ln}"
            cur["blocks"][-1]["instrs"].append(ln)
            cur["lines"].append(ln)
    return fns


def parse_params(pl):
    out = []
    for p in [x for x in pl.split(", ") if x]:
        name, rest = p.split(":", 1)
        parts = rest.split(" ")
        out.append((name, parts[0], parts[1] if len(parts) > 1 else None))
    return out


def parse_regs(regs_line):
    m = re.match(r"^regs \{ (.*) \}", regs_line)
    body = m.group(1).strip()
    d = {}
    for p in [x for x in body.split(", ") if x]:
        n, t = p.split(":")
        d[n] = int(re.match(r"reg\[(\d+)\]", t).group(1))
    return d


def parse_instr(ln):
    lhs, rhs = (ln.split(" = ", 1) if " = " in ln else (None, ln))
    toks = re.findall(r"\([^()]*\)|\S+", rhs)
    op, ops = toks[0], toks[1:]
    return lhs, op, ops


# ----------------------------------------------------------------- hashing

def symbol_refs(fn_lines):
    """References in the body; the header line's own name is a definition."""
    return [m for m in re.findall(r"@([A-Za-z_][A-Za-z0-9_.]*)", "\n".join(fn_lines[1:]))]


def layout_leaves(layout):
    leaves = {}
    for k, v in layout.items():
        if k in ("globals", "interface_regions"):
            for n, e in v.items():
                if k == "globals":
                    leaves[f"globals.{n}"] = e
                else:
                    for r, ee in e.items():
                        leaves[f"interface_regions.{n}.{r}"] = ee
        else:
            leaves[k] = v
    return leaves


def closure_set(sym, fn, sections):
    """(data entries, layout leaves) in the symbol's closure set per §9.2."""
    layout = sections.get("layout", {})
    leaves = layout_leaves(layout)
    data = dict(l.split(" ") for l in sections.get("data", []))
    if sym["kind"] == "oracle":
        sel = {k: v for k, v in leaves.items()
               if not (k.startswith("interface_regions.") and not k.startswith(f"interface_regions.{sym['name']}."))}
        imgs = {k: data[k] for k in [v.get("image") for v in sel.values() if isinstance(v, dict)] if k}
        return imgs, sel
    if sym["kind"] == "lproc":
        names = re.findall(r"lift\.addr @([A-Za-z_][A-Za-z0-9_.]*)", "\n".join(fn["lines"]))
        sel = {f"globals.{n}": leaves[f"globals.{n}"] for n in names if f"globals.{n}" in leaves}
        imgs = {v["image"]: data[v["image"]] for v in sel.values()}
        return imgs, sel
    return {}, {}


def envelope(version, ptr_width, sig, body_lines, data, leaves, refs):
    parts = [f"isa={version}", f"ptr_width={ptr_width}", jcs(sig)] + body_lines
    parts += [f"data {n} {h}" for n, h in sorted(data.items())]
    parts += [f"layout {k} {jcs(v) if not isinstance(v, int) else v}" for k, v in sorted(leaves.items())]
    parts += list(refs)
    return ("\n".join(parts) + "\n").encode()


def compute_hashes(hdr, sections):
    symbols = {v["name"]: dict(v, index=k) for k, v in sections["symbols"].items()}
    fns = {f["name"]: f for f in parse_functions(sections.get("functions", []))}
    data_lines = dict(l.split(" ") for l in sections.get("data", []))
    names = list(symbols)
    # reference graph over symbols (interface-region names are not symbols)
    graph = {}
    for n in names:
        if n in fns:
            graph[n] = [r for r in symbol_refs(fns[n]["lines"]) if r in symbols]
        else:
            graph[n] = []
    # Tarjan SCC
    index, low, stack, on, sccs, counter = {}, {}, [], set(), [], [0]

    def strong(v):
        index[v] = low[v] = counter[0]; counter[0] += 1
        stack.append(v); on.add(v)
        for w in graph[v]:
            if w not in index:
                strong(w); low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop(); on.discard(w); comp.append(w)
                if w == v:
                    break
            sccs.append(sorted(comp))
    for v in names:
        if v not in index:
            strong(v)
    scc_of = {v: c for c in sccs for v in c}
    hashes = {}

    def hash_scc(comp):
        # dependencies outside the SCC first
        for v in comp:
            for w in graph[v]:
                if w not in comp and w not in hashes:
                    hash_scc(scc_of[w])
        envs = []
        for v in comp:
            sym = symbols[v]
            if v in fns:
                fn = fns[v]
                body = list(fn["lines"])
                refs = []
                def repl(m):
                    w = m.group(1)
                    if w in comp:
                        return "@$" + str(comp.index(w))
                    if w in symbols:
                        if hashes[w] not in refs:
                            refs.append(hashes[w])
                        return "@" + hashes[w]
                    return m.group(0)
                body = [body[0]] + [re.sub(r"@([A-Za-z_][A-Za-z0-9_.]*)", repl, l) for l in body[1:]]
                data, leaves = closure_set(sym, fn, sections)
                envs.append(envelope(hdr["isa"], hdr["ptr_width"], sym["signature"], body, data, leaves, refs))
            else:  # data symbol
                envs.append(envelope(hdr["isa"], hdr["ptr_width"], sym["signature"], [f"{v} {data_lines[v]}"], {}, {}, []))
        if len(comp) == 1 and comp[0] not in graph[comp[0]]:
            hashes[comp[0]] = sha(envs[0])
        else:
            scc_hash = sha(b"".join(envs))
            for i, v in enumerate(comp):
                hashes[v] = sha(f"{scc_hash}:{i}".encode())
    for comp in sccs:
        if comp[0] not in hashes:
            hash_scc(comp)
    return hashes, symbols


# ------------------------------------------------------ reference interpreter

class Fault(Exception):
    def __init__(self, code):
        self.code = code


class Budget(Exception):
    pass


def run_oracle(hdr, sections, name, ins, regions, B, depth_limit=64):
    fns = {f["name"]: f for f in parse_functions(sections["functions"])}
    oracle = fns[name]
    layout = sections.get("layout", {})
    leaves = layout_leaves(layout)
    data = dict(l.split(" ") for l in sections.get("data", []))
    # memory + alloctab pre-entries: globals (layout order) then interface regions
    mem, alloctab = {}, []
    for gname, g in layout.get("globals", {}).items():
        img = bytes.fromhex(data[g["image"]])
        for i, b in enumerate(img):
            mem[g["base"] + i] = b
        alloctab.append([g["base"], g["size"], 1, 1])
    irs = layout.get("interface_regions", {}).get(name, {})
    mem_params = parse_params(oracle["plists"][3])
    for (rname, rtype, role) in mem_params:
        A, W = map(int, re.match(r"region\[(\d+),(\d+)\]", rtype).groups())
        base = irs[rname]["base"]
        for i, b in enumerate(regions[rname]):
            mem[base + i] = b
        alloctab.append([base, 2 ** A, 1, 1])
    addr_of = {g: e["base"] for g, e in layout.get("globals", {}).items()}
    addr_of.update({r: irs[r]["base"] for r in irs})
    ptr_mask = (1 << int(hdr["ptr_width"])) - 1
    state = {"steps": 0, "depth": 0, "result": 0}

    def step():
        state["steps"] += 1
        if state["steps"] > B:
            raise Budget()

    def inrange(p, n):
        return any(l and b <= p and p + n <= b + sz for (b, sz, l, pin) in alloctab)

    def exec_fn(fn, env):
        regs = parse_regs(fn["regs"]) if fn["regs"] else {}
        widths = dict(regs)
        if fn["kind"] == "lproc":
            for (n, t, _) in parse_params(fn["plists"][0]) + parse_params(fn["plists"][1]):
                widths[n] = int(re.match(r"reg\[(\d+)\]", t).group(1))
        else:
            for (n, t, _) in parse_params(fn["plists"][0]):
                widths[n] = int(re.match(r"wire\[(\d+)\]", t).group(1))
        blocks = {b["name"]: b for b in fn["blocks"]}
        cur = fn["blocks"][0]["name"]
        pc = 0
        while True:
            ln = blocks[cur]["instrs"][pc]
            lhs, op, ops = parse_instr(ln)
            step()

            def rd(n):
                return env[n]

            def wr(n, v):
                env[n] = v & ((1 << widths[n]) - 1)
            if op.startswith("lift.const"):
                wr(lhs, int(ops[0]))
            elif op in ("lift.add", "lift.sub", "lift.mov"):
                a = rd(ops[0]); b = rd(ops[1]) if op != "lift.mov" else 0
                wr(lhs, a + b if op == "lift.add" else a - b if op == "lift.sub" else a)
            elif op.startswith("lift.icmp."):
                pred = op.split(".")[-1]; a, b = rd(ops[0]), rd(ops[1])
                wr(lhs, {"eq": a == b, "ne": a != b, "ult": a < b, "ule": a <= b}[pred])
            elif op.startswith("lift.zext."):
                wr(lhs, rd(ops[0]))
            elif op == "lift.addr":
                wr(lhs, addr_of[ops[0][1:]])
            elif op == "lift.boundscheck":
                if not inrange(rd(ops[0]), int(ops[1])):
                    raise Fault(FAULT["MEMFAULT"])
            elif op.startswith("lift.load."):
                n = int(op.split(".i")[1]) // 8; a = rd(ops[0])
                if not inrange(a, n):
                    raise Fault(FAULT["MEMFAULT"])
                wr(lhs, sum(mem.get(a + i, 0) << (8 * i) for i in range(n)))
            elif op == "lift.call":
                callee = fns[ops[0][1:]]
                args = [rd(x) for x in ops[1].strip("()").split(", ") if x]
                if state["depth"] + 1 > depth_limit:
                    raise Fault(FAULT["DEPTH"])
                state["depth"] += 1
                cenv = {}
                for (pn, _, _), v in zip(parse_params(callee["plists"][0]), args):
                    cenv[pn] = v
                r = exec_fn(callee, cenv)
                wr(lhs, r)
            elif op == "lift.ret":
                if state["depth"] == 0:
                    raise Fault(FAULT["TRAP"])
                state["depth"] -= 1
                return rd(ops[0])
            elif op == "lift.retval":
                state["result"] ^= rd(ops[0])
                return None
            elif op == "qbranch":
                cur = ops[1][1:] if rd(ops[0]) else ops[2][1:]; pc = 0; continue
            elif op == "qjump":
                cur = ops[0][1:]; pc = 0; continue
            else:
                raise AssertionError(f"interpreter: unsupported row {op}")
            pc += 1

    env = {n: v for (n, _, _), v in zip(parse_params(oracle["plists"][0]), ins)}
    try:
        exec_fn(oracle, env)
        return (state["result"], 0, state["steps"])
    except Budget:
        return (0, FAULT["STEPS"], state["steps"])
    except Fault as f:
        return (0, f.code, state["steps"])


# ------------------------------------------------------------------- checks

def main():
    text = SPEC.read_text(encoding="utf-8")
    examples = extract_examples(text)
    assert len(examples) >= 2, "expected at least two example objects"
    failures = []
    printed = dict(re.findall(r"^([A-Za-z_][A-Za-z0-9_.]*) = ([0-9a-f]{64})$", text, re.M))
    for obj in examples:
        hdr, sections = parse_object(obj)
        hashes, symbols = compute_hashes(hdr, sections)
        for n, h in hashes.items():
            ih = symbols[n]["interface_hash"]
            if ih != h:
                failures.append(f"{n}: symbols interface_hash {ih[:12]} != computed {h[:12]}")
            if printed.get(n) != h:
                failures.append(f"{n}: printed table hash {str(printed.get(n))[:12]} != computed {h[:12]}")
        names = set(symbols)
        if "inc8" in names:
            env_block = re.search(r"```\n(isa=0\.[0-9]+\n.*?)```", text, re.S)
            if not env_block or sha(env_block.group(1).encode()) != hashes["inc8"]:
                failures.append("printed inc8 envelope bytes do not hash to the inc8 hash")
            for x in range(256):
                r, c, st = run_oracle(hdr, sections, "inc8", [x], {}, 3)
                if (r, c) != ((x + 1) & 255, 0):
                    failures.append(f"inc8({x}) B=3 -> {(r, c)}")
                r, c, st = run_oracle(hdr, sections, "inc8", [x], {}, 2)
                if (r, c) != (0, FAULT["STEPS"]):
                    failures.append(f"inc8({x}) B=2 -> {(r, c)} expected STEPS")
        if "sum_db" in names:
            import random
            rnd = random.Random(7)
            db = [rnd.randrange(256) for _ in range(16)]
            for n in range(0, 24):
                r, c, st = run_oracle(hdr, sections, "sum_db", [n], {"db": db}, 10 ** 6)
                exp = (sum(db[:n]) & 255, 0) if n <= 16 else (0, FAULT["MEMFAULT"])
                if (r, c) != exp:
                    failures.append(f"sum_db({n}) -> {(r, c)} expected {exp}")
            for n in (1, 3, 7):
                r, c, _ = run_oracle(hdr, sections, "sum_db", [n], {"db": db}, 10 ** 6, depth_limit=n)
                if c != FAULT["DEPTH"]:
                    failures.append(f"sum_db({n}) depth_limit={n} -> code {c}, expected DEPTH")
                r, c, _ = run_oracle(hdr, sections, "sum_db", [n], {"db": db}, 10 ** 6, depth_limit=n + 1)
                if c != 0:
                    failures.append(f"sum_db({n}) depth_limit={n + 1} -> code {c}, expected success")
            _, _, st = run_oracle(hdr, sections, "sum_db", [0], {"db": db}, 10 ** 6)
            r, c, _ = run_oracle(hdr, sections, "sum_db", [0], {"db": db}, st - 1)
            if c != FAULT["STEPS"]:
                failures.append(f"sum_db(0) with B=steps-1 -> code {c}, expected STEPS")
        # layout disjointness
        lay = sections.get("layout")
        if lay:
            rngs = [(0, lay["null_size"], "null")]
            rngs += [(g["base"], g["base"] + g["size"], n) for n, g in lay.get("globals", {}).items()]
            rngs += [(lay["heap_base"], lay["heap_base"] + lay["heap_limit_max"], "heap")]
            for o, rs in lay.get("interface_regions", {}).items():
                fn = next(f for f in parse_functions(sections["functions"]) if f["name"] == o)
                for (rn, rt, _) in parse_params(fn["plists"][3]):
                    A = int(re.match(r"region\[(\d+),", rt).group(1))
                    rngs.append((rs[rn]["base"], rs[rn]["base"] + 2 ** A, rn))
            rngs.sort()
            for (a0, a1, an), (b0, b1, bn) in zip(rngs, rngs[1:]):
                if a1 > b0:
                    failures.append(f"layout ranges overlap: {an} [{a0},{a1}) and {bn} [{b0},{b1})")
            if rngs[-1][1] > 2 ** lay["H"]:
                failures.append(f"layout exceeds 2^H: {rngs[-1]}")
    if failures:
        print("ISA CHECK FAILED:")
        for f in failures:
            print(" -", f)
        sys.exit(1)
    print(f"isa_check ok: {len(examples)} example objects parse, hash per §9.2, and execute as stated")


if __name__ == "__main__":
    main()
