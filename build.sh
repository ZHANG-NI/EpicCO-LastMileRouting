#!/bin/bash
# Build recipe of this solver, as used for every build of the paper's runs.
# Run it from this directory:  bash build.sh <output directory>   ->  <output directory>/solver
set -e
set -o pipefail
CC=${CC:-gcc}
command -v "$CC" > /dev/null || { echo "no C compiler ($CC) on PATH"; exit 1; }
for f in solver/Solvermain.c solver/include/Solver.h tools/tour_length.c scripts/build_TSPLIB.py scripts/tsplib2json.py \
         scripts/analyze_zone_id_order_main.py stages.txt solver.par; do
  [ -f "$f" ] || { echo "$f is missing"; exit 1; }
done
python3 - <<'PY' || exit 1
import re, sys
rows = [l.strip() for l in open("stages.txt").read().splitlines() if l.strip() and not l.strip().startswith("#")]
if not 1 <= len(rows) <= 6:
    sys.exit("stages.txt must hold 1 to 6 variant lines (found %d)" % len(rows))
tot = 0.0
names = set()
for r in rows:
    if not re.match(r"^[A-Za-z][A-Za-z0-9_]{0,15} \| (-[A-Za-z]+( -[A-Za-z]+)*)? ?\| (0?\.[0-9]+|1(\.0+)?) \| [0-9]+(\.[0-9]+)?$", r):
        sys.exit("stages.txt: a line must read  name | flags | share | factor  (found: %s)" % r)
    f = [x.strip() for x in r.split("|")]
    if f[0] in names:
        sys.exit("stages.txt: the name %s occurs twice" % f[0])
    names.add(f[0])
    if float(f[2]) <= 0 or float(f[3]) <= 0:
        sys.exit("stages.txt: share and factor must be positive (%s)" % r)
    tot += float(f[2])
if not 0.99 <= tot <= 1.01:
    sys.exit("stages.txt: the shares must add up to 1 (they add up to %.4f)" % tot)
for l in open("solver.par").read().splitlines():
    l = l.strip()
    if not l or l.startswith("#"):
        continue
    if not re.match(r"^[A-Z_0-9]+ = \S.*$", l):
        sys.exit("solver.par: a line must read  KEY = value  (found: %s)" % l)
    if l.split(" = ")[0] in ("PROBLEM_FILE", "SEED", "TIME_LIMIT", "TOUR_FILE", "RUNS", "OUTPUT_TOUR_FILE", "INITIAL_TOUR_FILE", "INPUT_TOUR_FILE", "MERGE_TOUR_FILE", "PI_FILE", "CANDIDATE_FILE", "SUBPROBLEM_TOUR_FILE"):
        sys.exit("solver.par: %s is set by the launcher or names a file and may not appear here" % l.split(" = ")[0])
PY
if [ "$2" = check ]; then                   # compile errors only, no binary, no model
  "$CC" -O1 -w -fcommon -fsyntax-only -Isolver/include solver/*.c tools/tour_length.c 2>&1 | tail -n 150
  python3 - <<'PY' 2>&1 | tail -n 40
import glob
for f in sorted(glob.glob("scripts/*.py")):          # syntax only; nothing is written next to the sources
    try:
        compile(open(f, encoding="utf-8").read(), f, "exec")
    except SyntaxError as ex:
        print("%s: %s" % (f, ex))
PY
  exit 0
fi
"$CC" -O3 -w -fcommon -Isolver/include solver/*.c -o "$1/prog" -lm 2>&1 | tail -n 150
"$CC" -O3 -w tools/tour_length.c -o "$1/tour_length" 2>&1 | tail -n 20
rm -rf "$1/scripts"
cp -r scripts "$1/scripts"
find "$1/scripts" -name '__pycache__' -prune -exec rm -rf {} + 2> /dev/null || true
cp stages.txt solver.par "$1/"
H="${LMR_HIST:-}"
if [ -z "$H" ]; then
  for c in "$LMR_DATA" "$SE_ROOT/common/tools/lmr_data" "$HOME/tools/lmr_data"; do
    if [ -n "$c" ] && [ -d "$c/hist" ]; then H="$c/hist"; break; fi
  done
fi
[ -f "$H/route_data.json" ] && [ -f "$H/actual_sequences.json" ] || { echo "the history routes (route_data.json, actual_sequences.json) were not found (LMR_HIST or <data>/hist)"; exit 1; }
t0=$(date +%s)
( cd "$1/scripts" && python3 analyze_zone_id_order_main.py --r_file "$H/route_data.json" --s_file "$H/actual_sequences.json" --out_file "$1/model.json" ) > "$1/model_build.log" 2>&1 \
  || { echo "the model build failed:"; tail -n 40 "$1/model_build.log"; exit 1; }
[ -s "$1/model.json" ] || { echo "the model build wrote no model.json:"; tail -n 40 "$1/model_build.log"; exit 1; }
ln -sf "$H/route_data.json" "$1/route_data.json"
echo "$H" > "$1/history_dir.txt"
echo "model built from $(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$H/route_data.json") history routes in $(( $(date +%s) - t0 )) s"
cat > "$1/solver" <<'LAUNCHER'
#!/usr/bin/env python3
"""solver <instance.lmb> <solution> -t <seconds> -seed <int> [-keep]: proposes a stop sequence for every route of the
batch of (instance, seed) and writes them to <solution> (the challenge's proposed-sequences JSON). One process at a
time; the working directory <solution>.work/ is removed at the end (-keep leaves it)."""
import os
import shutil
import subprocess
import sys
import time
from fractions import Fraction

import hashlib as _hl
import json as _js
import os as _os


def data_root():
    for c in (_os.environ.get("LMR_DATA"), _os.path.join(_os.environ.get("SE_ROOT", ""), "common", "tools", "lmr_data"),
              _os.path.join(_os.path.expanduser("~"), "tools", "lmr_data")):
        if c and _os.path.isdir(c):
            return c
    return None


def load(path):
    with open(path, encoding="utf-8") as f:
        fam = _js.load(f)
    if fam.get("kind") not in ("family", "fixed"):
        raise ValueError("not an instance file of this problem")
    return fam


def batch_ids(fam, seed):
    """Route ids of the batch of (instance, seed), sorted. A family: the B routes of the pool with the smallest hash of
    (family name, route id, seed) - the same on every machine and Python version."""
    if fam["kind"] == "fixed":
        return sorted(fam["routes"])
    key = lambda r: _hl.md5(("%s|%s|%d" % (fam["name"], r, int(seed))).encode()).hexdigest()
    return sorted(sorted(fam["pool"], key=key)[:int(fam["batch"])])


def route_dir(fam):
    if fam.get("root"):
        return fam["root"]
    root = data_root()
    if not root:
        raise RuntimeError("the data directory (lmr_data) was not found")
    return _os.path.join(root, fam.get("dir", "val"))


def read_route(fam, rid):
    with open(_os.path.join(route_dir(fam), rid + ".json"), encoding="utf-8") as f:
        return _js.load(f)


def materialise(fam, seed, directory):
    """Writes new_route_data.json, new_package_data.json and new_travel_times.json of the batch into `directory`
    (the names and the format of the challenge's apply inputs); returns the route ids."""
    ids = batch_ids(fam, seed)
    R, P, T = {}, {}, {}
    for rid in ids:
        d = read_route(fam, rid)
        R[rid], P[rid], T[rid] = d["route"], d["packages"], d["travel"]
    _os.makedirs(directory, exist_ok=True)
    for name, obj in (("new_route_data.json", R), ("new_package_data.json", P), ("new_travel_times.json", T)):
        with open(_os.path.join(directory, name), "w", encoding="utf-8") as f:
            _js.dump(obj, f)
    return ids

T0 = time.time()
here = os.path.dirname(os.path.abspath(__file__))
a = sys.argv[1:]
inst, sol = os.path.abspath(a[0]), os.path.abspath(a[1])
T = float(a[a.index("-t") + 1])
seed = int(a[a.index("-seed") + 1])
keep = "-keep" in a
fam = load(inst)
W = sol + ".work"
shutil.rmtree(W, ignore_errors=True)
os.makedirs(W)
log = open(os.path.join(W, "log.txt"), "w")


def say(s):
    log.write("%7.1f s  %s\n" % (time.time() - T0, s))
    log.flush()


ids = materialise(fam, seed, os.path.join(W, "in"))
say("batch of %d routes written" % len(ids))
stages = []
for line in open(os.path.join(here, "stages.txt")).read().splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        f = [x.strip() for x in line.split("|")]
        stages.append((f[0], f[1].split(), float(f[2]), Fraction(f[3])))      # the factor as an exact decimal
par_lines = [l.strip() for l in open(os.path.join(here, "solver.par")).read().splitlines() if l.strip() and not l.strip().startswith("#")]
py = sys.executable or "python3"
env = dict(os.environ)
env["PYTHONDONTWRITEBYTECODE"] = "1"
# 1. the instances of every variant (the builder, once per variant)
for name, flags, share, factor in stages:
    d = os.path.join(W, name)
    cmd = [py, os.path.join(here, "scripts", "build_TSPLIB.py"), "--r_file", os.path.join(W, "in", "new_route_data.json"),
           "--t_file", os.path.join(W, "in", "new_travel_times.json"), "--p_file", os.path.join(W, "in", "new_package_data.json"),
           "--z_file", os.path.join(here, "model.json"), "--br_file", os.path.join(here, "route_data.json")] + flags + [d]
    rc = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT, cwd=os.path.join(here, "scripts"), env=env)
    n = len([x for x in os.listdir(d) if x.endswith(".ctsptw")]) if os.path.isdir(d) else 0
    say("variant %s: builder rc %d, %d instances" % (name, rc, n))
# 2. the solver: all routes of the first variant, then of the second, ...; the time left for solving is divided by
#    the shares; inside a variant every route gets the same share of what is left of the variant's time
reserve = 3.0 + 0.05 * len(ids)                      # merge, tour -> sequence, writing
solve_end = T0 + T - reserve
left_share = sum(s[2] for s in stages)
tours = {}
for name, flags, share, factor in stages:
    d = os.path.join(W, name)
    insts = sorted(x for x in os.listdir(d) if x.endswith(".ctsptw")) if os.path.isdir(d) else []
    td = os.path.join(W, "TOURS-" + name)
    os.makedirs(td, exist_ok=True)
    stage_end = time.time() + max(0.0, solve_end - time.time()) * share / max(1e-9, left_share)
    left_share -= share
    for i, x in enumerate(insts):
        tl = min(60.0, max(0.2, (stage_end - time.time()) / (len(insts) - i)))
        base = x[:-len(".ctsptw")]
        par = os.path.join(W, "p.par")
        with open(par, "w") as f:
            f.write("PROBLEM_FILE = %s\n" % os.path.join(d, x))
            for l in par_lines:
                f.write(l + "\n")
            f.write("SEED = %d\nTIME_LIMIT = %.2f\nTOUR_FILE = %s\n" % (seed, tl, os.path.join(td, base + ".tour")))
        try:
            subprocess.call([os.path.join(here, "prog"), par], stdout=log, stderr=subprocess.STDOUT, cwd=W, timeout=tl + 30.0)
        except subprocess.TimeoutExpired:
            say("variant %s %s: solver killed after %.1f s" % (name, base, tl + 30.0))
        tp = os.path.join(td, base + ".tour")
        if os.path.exists(tp) and os.path.getsize(tp) > 0:
            try:
                L = int(subprocess.check_output([os.path.join(here, "tour_length"), tp], timeout=20).split()[0])
                c = tours.setdefault(base, [])
                c.append(((L * factor.numerator) // factor.denominator, len(c), tp))     # floor(factor x length), exact
            except Exception as ex:
                say("variant %s %s: no length (%r)" % (name, base, ex))
    say("variant %s: %d routes solved" % (name, sum(1 for b in tours if any(t[2].startswith(td) for t in tours[b]))))
# 3. merge: per route the variant with the smallest floor(factor x length), ties to the earlier line
md = os.path.join(W, "TOURS")
os.makedirs(md, exist_ok=True)
for base, c in tours.items():
    shutil.copyfile(min(c)[2], os.path.join(md, base + ".tour"))
# 4. tours -> proposed sequences
first = os.path.join(W, stages[0][0], "tsp2ext.json")
out = os.path.join(W, "proposed_sequences.json")
rc = 1
if os.path.exists(first) and tours:
    rc = subprocess.call([py, os.path.join(here, "scripts", "tsplib2json.py"), "--tour_dir", md, "--tsplib2ext_file", first, "--out_json", out],
                         stdout=log, stderr=subprocess.STDOUT, cwd=os.path.join(here, "scripts"), env=env)
if rc == 0 and os.path.exists(out):
    shutil.copyfile(out, sol)
say("done: %d of %d routes with a tour" % (len(tours), len(ids)))
print("RESULT routes %d with_tour %d seconds %.1f" % (len(ids), len(tours), time.time() - T0))
log.close()
if not keep:
    shutil.rmtree(W, ignore_errors=True)
sys.exit(0 if rc == 0 else 1)
LAUNCHER
chmod +x "$1/solver"
