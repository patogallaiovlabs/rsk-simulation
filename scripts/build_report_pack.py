#!/usr/bin/env python3
"""Assemble every A/B run in this project into a queryable report pack.

    scripts/build_report_pack.py            # -> results/report-pack/

Regenerate it any time; it reads only collected results and overwrites the pack.
Re-run it after an in-flight rotation finishes to pick up the new cycles.

Outputs
  runs.csv          one row per ARM (the raw measurement unit)
  cycle_deltas.csv  one row per scenario x metric x cycle (the analysis unit)
  pooled.csv/.json  one row per scenario x metric (the reportable claim, with p-values)
  excluded.csv      every arm/cycle deliberately left out, with the reason
  sweep_runs.csv    one row per gas-limit sweep RUN (single build, gas limit varied)
  sweep_curves.csv  one row per scenario x gas limit: the curve points + linearity
  README.md         briefing: methodology, what is claimable, what is not
"""
import os, sys, csv, json, glob, re, statistics as st
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paired_stats as PS

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "results", "report-pack")
def discover_scenarios():
    """Scenario names are read off disk, not hardcoded, so a future rotation is picked
    up by re-running this script with no code change."""
    names = set()
    for pat, rx in ((os.path.join(ROOT, "results/boton", "bseq*-*"), r"bseq\d+-([a-z]+)-(?:fwd|rev)$"),
                    (os.path.join(ROOT, "results/local-ab", "seq*-*"), r"seq\d+-([a-z]+)-(?:baseline|tip)$")):
        for d in glob.glob(pat):
            m = re.match(rx, os.path.basename(d))
            if m:
                names.add(m.group(1))
    return sorted(names)
BUILDS = {"baseline": "47a2eb63a", "tip": "392ae5506"}


def boton_arm_rows(rows, excluded):
    for d in sorted(glob.glob(os.path.join(ROOT, "results/boton", "bseq*-*"))):
        base = os.path.basename(d)
        m = re.match(r"bseq(\d+)-([a-z]+)-(fwd|rev)$", base)
        if not m:
            continue
        cyc, scen, slot = int(m.group(1)), m.group(2), m.group(3)
        for role in ("baseline", "tip"):
            f = glob.glob(os.path.join(d, f"*_{role}.json"))
            if not f:
                continue
            j = json.load(open(f[0]))
            # NAMING TRAP: files are named by BOX ROLE. In the reversed slot box A ran
            # the tip build, so the file called "baseline" holds tip's numbers.
            build = role if slot == "fwd" else ("tip" if role == "baseline" else "baseline")
            box = "A" if role == "baseline" else "B"
            pb = j.get("per_block", {})
            row = {
                "track": "boton", "scenario": scen, "cycle": cyc, "slot": slot,
                "box": box, "build": build, "build_commit": BUILDS.get(build, ""),
                "threshold": j.get("threshold"), "qualifying_blocks": j.get("qualifying_blocks"),
                "total_records": j.get("total_connect_records"),
                "util_mean": round(j.get("gas_utilization_mean") or 0, 4),
                "gas_limit": j.get("gas_limit"), "dir": os.path.relpath(d, ROOT),
            }
            for met in PS.METRICS:
                row[f"{met}_mean"] = (pb.get(met) or {}).get("mean")
                row[f"{met}_p50"] = (pb.get(met) or {}).get("p50")
                row[f"{met}_p95"] = (pb.get(met) or {}).get("p95")
            rows.append(row)
            if j.get("threshold") is not None and abs(j["threshold"] - 0.9) > 1e-9:
                excluded.append({
                    "track": "boton", "scenario": scen, "cycle": cyc,
                    "what": f"{base}/{role}", "reason": f"threshold {j['threshold']} != 0.9",
                    "detail": f"mean utilization {row['util_mean']:.0%} over "
                              f"{row['qualifying_blocks']} blocks — different block population",
                })


def local_arm_rows(rows, excluded):
    pats = [("results/local-ab", False), ("results/local-ab/_quarantine", True)]
    for sub, quarantined in pats:
        for d in sorted(glob.glob(os.path.join(ROOT, sub, "seq*-*"))):
            base = os.path.basename(d)
            m = re.match(r"seq(\d+)-([a-z]+)-(baseline|tip)$", base)
            if not m:
                continue
            cyc, scen, arm = int(m.group(1)), m.group(2), m.group(3)
            vals = PS.local_arm(d)
            row = {
                "track": "local", "scenario": scen, "cycle": cyc, "slot": "serial",
                "box": "local", "build": arm, "build_commit": BUILDS.get(arm, ""),
                "threshold": 0.9,
                "qualifying_blocks": len(vals["totalMs"]) if vals else 0,
                "total_records": "", "util_mean": "", "gas_limit": 25_000_000,
                "dir": os.path.relpath(d, ROOT),
            }
            for met in PS.METRICS:
                v = (vals or {}).get(met) or []
                row[f"{met}_mean"] = round(st.fmean(v), 1) if v else None
                row[f"{met}_p50"] = round(st.median(v), 1) if v else None
                # p95 stays empty on the local track: boton's p95 comes from the
                # collector, and computing one here with a different definition would
                # invite cross-track comparisons of two different statistics.
                row[f"{met}_p95"] = None
            rows.append(row)
            if quarantined:
                excluded.append({
                    "track": "local", "scenario": scen, "cycle": cyc, "what": base,
                    "reason": "quarantined — concurrent workload",
                    "detail": "overlapped another running arm during the rotation switch; "
                              "see results/local-ab/_quarantine/README.md",
                })


SWEEP_SRC = os.path.join(ROOT, "results/sweep/sweep-runs.csv")
OPT_NAMES = {"14": "mainnet", "7": "ecdsa", "15": "blockfiller", "11": "calldata",
             "6": "storagereads", "16": "indexer"}
BOX_NAMES = {"5.78.115.226": "us-west", "178.156.204.38": "us-east", "local": "local"}


def collect_sweep():
    """Gas-limit sweep: ONE build, gas limit varied. Shape differs from the A/B tracks --
    there is no tip-vs-baseline delta here, so it gets its own files rather than being
    forced into the paired-cycle schema."""
    if not os.path.exists(SWEEP_SRC):
        return [], []
    runs = list(csv.DictReader(open(SWEEP_SRC)))
    cells = {}
    for r in runs:
        r["scenario"] = OPT_NAMES.get(r["scenario_opt"], r["scenario_opt"])
        r["box"] = BOX_NAMES.get(r["machine"], r["machine"])
        # Under-filled runs measure the load generator, not the node. They stay in
        # sweep_runs.csv (auditable) but never reach a curve point.
        if not r.get("totalMs_p50") or r.get("verdict") == "EXCLUDE-UNDERFILL":
            continue
        # BUILD IS PART OF THE KEY. sweep-runs.csv accumulates across sweeps (tip
        # 392ae5506, baseline 47a2eb63a, ...). Without the build in the key, two builds'
        # runs at the same gas limit average into one meaningless curve -- silently,
        # because the shape still looks plausible.
        k = (r["scenario"], r["box"], r.get("build", "?"), int(r["gas_limit"]) // 1000000)
        c = cells.setdefault(k, {"p50": [], "p95": [], "max": [], "util": []})
        for f, col in (("p50", "totalMs_p50"), ("p95", "totalMs_p95"), ("max", "totalMs_max")):
            try: c[f].append(float(r[col]))
            except (ValueError, TypeError): pass
        try: c["util"].append(float(r["mean_util"]))
        except (ValueError, TypeError): pass

    curves = []
    for (sc, bx, bd) in sorted({(k[0], k[1], k[2]) for k in cells}):
        ks = sorted([k for k in cells if k[0] == sc and k[1] == bx and k[2] == bd],
                    key=lambda k: k[3])
        lo, hi = ks[0], ks[-1]
        for k in ks:
            c = cells[k]
            if not c["p50"]:
                continue
            med = st.median(c["p50"])
            row = {
                "scenario": sc, "box": bx, "build": bd, "gas_limit_m": k[3],
                "cycles": len(c["p50"]),
                "mean_util": round(st.mean(c["util"]), 4) if c["util"] else "",
                "totalMs_p50": round(med, 1),
                "totalMs_p95": round(st.median(c["p95"]), 1) if c["p95"] else "",
                "totalMs_max": round(st.median(c["max"]), 1) if c["max"] else "",
                "us_per_Mgas": round(1000 * med / k[3], 1),
                "pct_of_10s_interval_p95": round(st.median(c["p95"]) / 100.0, 2) if c["p95"] else "",
                "curve_points": len(ks),
            }
            if len(ks) >= 2 and k == hi:
                gx = hi[3] / lo[3]
                r50 = med / max(st.median(cells[lo]["p50"]), 1e-9)
                row["gas_growth_x"] = round(gx, 2)
                row["time_growth_x"] = round(r50, 2)
                row["linearity"] = ("SUPER-LINEAR" if r50 > gx * 1.15
                                    else "sub-linear" if r50 < gx * 0.85 else "linear")
            # A curve needs >=3 points to claim a shape; 2 is a slope, 1 is a dot.
            row["curve_claimable"] = ("yes" if len(ks) >= 3 else
                                      "slope only (2 points)" if len(ks) == 2 else "no (1 point)")
            curves.append(row)
    return runs, curves


def main():
    os.makedirs(OUT, exist_ok=True)
    SCEN = discover_scenarios()
    rows, excluded = [], []
    boton_arm_rows(rows, excluded)
    local_arm_rows(rows, excluded)

    cols = (["track", "scenario", "cycle", "slot", "box", "build", "build_commit",
             "threshold", "qualifying_blocks", "total_records", "util_mean", "gas_limit"]
            + [f"{m}_{p}" for m in PS.METRICS for p in ("mean", "p50", "p95")] + ["dir"])
    with open(os.path.join(OUT, "runs.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in sorted(rows, key=lambda r: (r["track"], r["scenario"], r["cycle"], r["build"])):
            w.writerow(r)

    deltas, pooled = [], []
    for track in ("boton", "local"):
        for sc in SCEN:
            res = (PS.collect_boton(sc, 0.9, []) if track == "boton" else PS.collect_local(sc))
            for met, pts in res.items():
                for cyc, d in sorted(pts):
                    deltas.append({"track": track, "scenario": sc, "metric": met,
                                   "cycle": cyc, "delta_pct": round(d, 2)})
                if not pts:
                    continue
                ds = [d for _, d in sorted(pts)]
                k, n, p = PS.sign_test(ds)
                pooled.append({
                    "track": track, "scenario": sc, "metric": met, "cycles": len(ds),
                    "median_delta_pct": round(st.median(ds), 2),
                    "tip_faster": k, "non_tied": n,
                    "sign_p": None if p is None else round(p, 4),
                    "significant_p05": bool(p is not None and p < 0.05),
                    "claimable": ("significant" if (p is not None and p < 0.05)
                                  else ("direction only" if len(ds) >= 2 else "single cycle")),
                })
    for name, data, cols2 in (
            ("cycle_deltas.csv", deltas, ["track", "scenario", "metric", "cycle", "delta_pct"]),
            ("pooled.csv", pooled, ["track", "scenario", "metric", "cycles", "median_delta_pct",
                                    "tip_faster", "non_tied", "sign_p", "significant_p05", "claimable"]),
            ("excluded.csv", excluded, ["track", "scenario", "cycle", "what", "reason", "detail"])):
        with open(os.path.join(OUT, name), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols2, extrasaction="ignore")
            w.writeheader()
            w.writerows(data)

    sweep_runs, sweep_curves = collect_sweep()
    if sweep_runs:
        rcols = (["scenario", "box", "gas_limit", "cycle", "build", "mean_util",
                  "qualifying_blocks", "totalMs_p50", "totalMs_p95", "totalMs_max",
                  "executeMs_p50", "txExecutionMs_p50", "statePersistMs_p50",
                  "saveReceiptsMs_p50", "verdict"])
        with open(os.path.join(OUT, "sweep_runs.csv"), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=rcols, extrasaction="ignore")
            w.writeheader(); w.writerows(sweep_runs)
        ccols = ["scenario", "box", "build", "gas_limit_m", "cycles", "mean_util", "totalMs_p50",
                 "totalMs_p95", "totalMs_max", "us_per_Mgas", "pct_of_10s_interval_p95",
                 "curve_points", "curve_claimable", "gas_growth_x", "time_growth_x", "linearity"]
        with open(os.path.join(OUT, "sweep_curves.csv"), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=ccols, extrasaction="ignore")
            w.writeheader(); w.writerows(sweep_curves)

    json.dump({"generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "builds": BUILDS, "arms": len(rows), "cycle_deltas": len(deltas),
               "pooled_claims": len(pooled), "excluded": len(excluded),
               "sweep_runs": len(sweep_runs), "sweep_curves": len(sweep_curves),
               "pooled": pooled, "sweep": sweep_curves}, open(os.path.join(OUT, "pooled.json"), "w"), indent=2)
    print(f"report pack -> {os.path.relpath(OUT, ROOT)}")
    print(f"  runs.csv          {len(rows)} arms")
    print(f"  cycle_deltas.csv  {len(deltas)} cycle deltas")
    print(f"  pooled.csv        {len(pooled)} pooled claims "
          f"({sum(1 for p in pooled if p['significant_p05'])} significant at p<0.05)")
    print(f"  excluded.csv      {len(excluded)} exclusions")
    if sweep_runs:
        print(f"  sweep_runs.csv    {len(sweep_runs)} sweep runs")
        print(f"  sweep_curves.csv  {len(sweep_curves)} curve points "
              f"({sum(1 for c in sweep_curves if c.get('linearity'))} curves with a linearity verdict)")


if __name__ == "__main__":
    main()
