#!/usr/bin/env python3
"""Apply the failure-coding codebook to the 82-row inventory.

Inputs (read-only):
  dataset_82_projects.md   the source-linked inventory (rows parsed in file order)
  coding/row_codes.csv     one hand-coded decision row per inventory row

Outputs (overwritten):
  output/dataset_82_coded.csv     source fields joined with the codes
  output/coding_summary.json      counts used by the final report
  output/descriptive_tables.md    descriptive tables (no inferential statistics)

The script validates every code against the rules in FAILURE-CODING-CODEBOOK.md
(section 6) and exits non-zero on any violation. Python 3.10+, stdlib only.
"""
from __future__ import annotations

import csv
import json
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "dataset_82_projects.md"
CODES = HERE / "coding" / "row_codes.csv"
OUT = HERE / "output"

MECHANISMS = ["ICO", "RDA", "Bonding Curve", "DAICO", "LBP"]
SECTION_MAP = dict(zip("12345", MECHANISMS))
LINK_RE = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+)\)")

RECORD_TYPES = ["campaign", "platform", "project", "governance_event", "proposal", "aggregate"]
FIT_ELIGIBLE = {"yes", "partial", "hybrid", "variant", "attempted_cancelled"}
FIT_VALUES = FIT_ELIGIBLE | {"no", "contradicted", "unverified", "n/a"}
SURVIVING = ["active", "active_diminished", "rebranded_or_merged"]
FAILED = ["dead_inactive", "halted_refunded"]
OUTCOMES = SURVIVING + FAILED + ["unknown", "not_applicable"]
MODES = ["exit_scam", "soft_rug", "governance_failure", "liquidity_trap", "slow_death",
         "regulatory_shutdown"]
FAILURE_CODES = MODES + ["other", "unknown"]
ALL_MODES = FAILURE_CODES + ["not_failed", "not_applicable"]
CONFIDENCE = ["High", "Medium", "Low"]
# Modes that describe what happened after the raise (the accountability-gap
# hypothesis); used only for a descriptive share, never as a causal claim.
POST_RAISE_MODES = {"exit_scam", "soft_rug", "governance_failure", "slow_death"}


def parse_inventory() -> list[dict]:
    rows, section, in_table = [], None, False
    for lineno, line in enumerate(SOURCE.read_text(encoding="utf-8").splitlines(), 1):
        heading = re.match(r"^## (\d)\.\s", line)
        if heading:
            section = SECTION_MAP.get(heading.group(1))
            in_table = False
            continue
        if line.startswith("## ") or line.startswith("### "):
            if line.startswith("## "):
                section = None
            in_table = False
            continue
        if not line.startswith("|"):
            in_table = False
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells and cells[0] == "#":
            in_table = section is not None and len(cells) == 9
            continue
        if set("".join(cells)) <= set("-: ") or not in_table:
            continue
        if len(cells) != 9:
            raise SystemExit(f"line {lineno}: expected 9 cells, got {len(cells)}")
        n, name, year, raised, token, status, notes, source, conf = cells
        links = LINK_RE.findall(source)
        rows.append({
            "category": section, "printed_row_no": n, "name": name, "year": year,
            "amount_raw": raised, "token_chain": token, "status_raw": status,
            "notes": notes, "source_urls": " | ".join(u for _, u in links) or source,
            "source_confidence": conf,
        })
    for i, row in enumerate(rows, 1):
        row["row_id"] = f"R{i:02d}"
    return rows


def load_codes() -> list[dict]:
    with CODES.open(encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def validate(source: list[dict], codes: list[dict]) -> list[str]:
    errors = []
    if len(source) != 82:
        errors.append(f"expected 82 inventory rows, parsed {len(source)}")
    if len(codes) != len(source):
        errors.append(f"{len(codes)} code rows for {len(source)} inventory rows")
    by_id = {c["row_id"]: c for c in codes}
    for src, code in zip(source, codes):
        rid = src["row_id"]
        if code["row_id"] != rid:
            errors.append(f"{rid}: code row out of order ({code['row_id']})")
            continue
        if code["name"] != src["name"] or code["category"] != src["category"] \
                or code["printed_row_no"] != src["printed_row_no"]:
            errors.append(f"{rid}: name/category/printed number differ from the inventory")
        checks = [
            ("record_type", RECORD_TYPES), ("mechanism_fit", FIT_VALUES),
            ("outcome_status", OUTCOMES), ("failure_mode", ALL_MODES),
            ("confidence", CONFIDENCE), ("eligible_campaign", ["Y", "N"]),
        ]
        for field, allowed in checks:
            if code[field] not in allowed:
                errors.append(f"{rid}: {field}={code[field]!r} not allowed")
        expected_eligible = (code["record_type"] == "campaign" and not code["duplicate_of"]
                             and code["mechanism_fit"] in FIT_ELIGIBLE)
        if (code["eligible_campaign"] == "Y") != expected_eligible:
            errors.append(f"{rid}: eligibility does not follow the rule")
        dup = code["duplicate_of"]
        if dup and (dup not in by_id or by_id[dup]["entity_id"] != code["entity_id"]):
            errors.append(f"{rid}: duplicate_of {dup} missing or a different entity")
        outcome, mode = code["outcome_status"], code["failure_mode"]
        if code["record_type"] in ("governance_event", "proposal", "aggregate"):
            if mode != "not_applicable":
                errors.append(f"{rid}: non-entity records take failure_mode=not_applicable")
        elif outcome in SURVIVING and mode != "not_failed":
            errors.append(f"{rid}: surviving outcome must be not_failed")
        elif outcome in FAILED and mode not in FAILURE_CODES:
            errors.append(f"{rid}: failed outcome needs a failure code")
        elif outcome == "unknown" and mode != "unknown":
            errors.append(f"{rid}: unknown outcome must have unknown mode")
        if mode in MODES and not code.get("failure_evidence"):
            errors.append(f"{rid}: failure mode without evidence")
        if code["raise_usd"]:
            try:
                float(code["raise_usd"])
            except ValueError:
                errors.append(f"{rid}: raise_usd not numeric")
    return errors


def money(x: float) -> str:
    if x >= 1e9:
        return f"${x / 1e9:.2f}B"
    if x >= 1e6:
        return f"${x / 1e6:.2f}M"
    return f"${x / 1e3:.0f}K"


def md_table(headers: list[str], rows: list[list]) -> str:
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join("---" if i == 0 else "---:" for i in range(len(headers))) + "|"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def build(source: list[dict], codes: list[dict]) -> tuple[list[dict], dict, str]:
    merged = [{**src, **{k: v for k, v in code.items() if k not in src or k == "row_id"}}
              for src, code in zip(source, codes)]
    eligible = [r for r in merged if r["eligible_campaign"] == "Y"]
    summary: dict = {"rows": len(merged), "distinct_entities": len({r["entity_id"] for r in merged})}

    # Table 1: record types
    t1 = defaultdict(Counter)
    for r in merged:
        t1[r["category"]][r["record_type"]] += 1
    summary["record_types"] = dict(Counter(r["record_type"] for r in merged))
    summary["record_types_by_mechanism"] = {m: dict(t1[m]) for m in MECHANISMS}
    rows1 = [[m] + [t1[m][t] for t in RECORD_TYPES] + [sum(t1[m].values())] for m in MECHANISMS]
    rows1.append(["**Total**"] + [summary["record_types"].get(t, 0) for t in RECORD_TYPES] + [len(merged)])

    # Table 2: eligibility funnel
    funnel = {}
    rows2 = []
    for m in MECHANISMS + ["Total"]:
        sel = merged if m == "Total" else [r for r in merged if r["category"] == m]
        camp = [r for r in sel if r["record_type"] == "campaign"]
        dups = [r for r in camp if r["duplicate_of"]]
        fit_out = [r for r in camp if not r["duplicate_of"] and r["mechanism_fit"] not in FIT_ELIGIBLE]
        elig = [r for r in sel if r["eligible_campaign"] == "Y"]
        funnel[m] = {"rows": len(sel), "non_campaign": len(sel) - len(camp), "campaign": len(camp),
                     "duplicates": len(dups), "mechanism_excluded": len(fit_out), "eligible": len(elig)}
        rows2.append([m, len(sel), len(sel) - len(camp), len(camp), len(dups), len(fit_out), len(elig)])
    summary["funnel"] = funnel

    # Table 3: outcomes of eligible campaigns
    outcome_by = {}
    rows3 = []
    for m in MECHANISMS + ["Total"]:
        sel = eligible if m == "Total" else [r for r in eligible if r["category"] == m]
        c = Counter(r["outcome_status"] for r in sel)
        surv = sum(c[o] for o in SURVIVING)
        fail = sum(c[o] for o in FAILED)
        unk = c["unknown"]
        share = f"{fail / len(sel):.0%}" if sel else "-"
        outcome_by[m] = {"n": len(sel), "surviving": surv, "failed": fail, "unknown": unk,
                         "by_status": dict(c)}
        rows3.append([m, len(sel), surv, fail, unk, share])
    summary["outcomes"] = outcome_by

    # Table 4: failure modes among failed eligible campaigns
    failed = [r for r in eligible if r["outcome_status"] in FAILED]
    modes = Counter(r["failure_mode"] for r in failed)
    summary["failure_modes"] = {k: modes.get(k, 0) for k in FAILURE_CODES}
    summary["failed_campaigns"] = [
        {"row_id": r["row_id"], "name": r["name"], "mechanism": r["category"],
         "outcome": r["outcome_status"], "failure_mode": r["failure_mode"],
         "confidence": r["confidence"]} for r in failed]
    coded = [r for r in failed if r["failure_mode"] in MODES]
    post = [r for r in coded if r["failure_mode"] in POST_RAISE_MODES]
    summary["post_raise_share_of_coded"] = {"coded": len(coded), "post_raise": len(post)}
    t4 = defaultdict(Counter)
    for r in failed:
        t4[r["failure_mode"]][r["category"]] += 1
    rows4 = [[mode] + [t4[mode][m] for m in MECHANISMS] + [modes.get(mode, 0)]
             for mode in FAILURE_CODES if modes.get(mode, 0)]
    rows4.append(["**Total failed**"] + [sum(1 for r in failed if r["category"] == m) for m in MECHANISMS]
                 + [len(failed)])

    # Table 5: capital raised
    cap = {}
    rows5 = []
    for m in MECHANISMS + ["All eligible"]:
        sel = eligible if m == "All eligible" else [r for r in eligible if r["category"] == m]
        vals = sorted(float(r["raise_usd"]) for r in sel if r["raise_usd"])
        if vals:
            cap[m] = {"n": len(vals), "median": statistics.median(vals), "min": vals[0],
                      "max": vals[-1], "sum": sum(vals)}
            rows5.append([m, len(vals), money(statistics.median(vals)), money(vals[0]),
                          money(vals[-1]), money(sum(vals))])
    allv = sorted((float(r["raise_usd"]), r["name"]) for r in eligible if r["raise_usd"])
    top3 = allv[-3:]
    cap["top3_share"] = sum(v for v, _ in top3) / cap["All eligible"]["sum"]
    cap["top3_names"] = [n for _, n in reversed(top3)]
    summary["capital"] = cap

    # Table 6: evidence quality and missing data (eligible campaigns)
    conf = Counter(r["confidence"] for r in eligible)
    approx = sum(1 for r in eligible if "~" in r["amount_raw"] or "approx" in r["amount_raw"].lower())
    no_amount = sum(1 for r in eligible if not r["raise_usd"])
    with_evidence = sum(1 for r in failed if r.get("evidence_url"))
    summary["evidence"] = {"confidence": dict(conf), "approximate_amounts": approx,
                           "missing_amounts": no_amount,
                           "failed_with_dated_evidence": with_evidence}
    rows6 = [["Code confidence High / Medium / Low",
              f"{conf['High']} / {conf['Medium']} / {conf['Low']}"],
             ["Amount reported as approximate (~)", approx],
             ["No usable capital-raised figure", no_amount],
             ["Failed campaigns with a dated outcome source", f"{with_evidence} of {len(failed)}"],
             ["Jurisdiction and intermediary fields", "not recorded (RQ3/RQ4 discussed qualitatively)"]]

    # Table 7: DAICO adoption
    daico = [r for r in merged if r["category"] == "DAICO"]
    rows7 = [[r["row_id"], r["name"], r["record_type"], r["mechanism_fit"],
              r["outcome_status"], money(float(r["raise_usd"])) if r["raise_usd"] else "-"] for r in daico]
    summary["daico"] = {"rows": len(daico), "eligible": sum(1 for r in daico if r["eligible_campaign"] == "Y"),
                        "with_raise": sum(1 for r in daico if r["raise_usd"])}

    # Table 8: duplicates and shared entities
    shared = defaultdict(list)
    for r in merged:
        shared[r["entity_id"]].append(r["row_id"])
    rows8 = [[eid, ", ".join(ids)] for eid, ids in sorted(shared.items()) if len(ids) > 1]
    summary["duplicates"] = [{"row_id": r["row_id"], "duplicate_of": r["duplicate_of"]}
                             for r in merged if r["duplicate_of"]]

    md = [
        "# Coded inventory: descriptive tables",
        "",
        "Generated by `code_inventory.py` from `dataset_82_projects.md` and "
        "`coding/row_codes.csv`. Unit for Tables 3-6: eligible fundraising "
        "campaigns. The inventory is a curated, source-linked list, not a random "
        "sample, so shares describe this list rather than the market. No "
        "inferential statistics are reported.",
        "",
        "## Table 1. Source rows by mechanism and record type",
        md_table(["Mechanism"] + RECORD_TYPES + ["Rows"], rows1),
        "",
        "## Table 2. Eligibility funnel",
        md_table(["Mechanism", "Rows", "Non-campaign", "Campaign rows", "Duplicates",
                  "Mechanism not evidenced", "Eligible"], rows2),
        "",
        "## Table 3. Outcomes of eligible campaigns at the mid-2026 cutoff",
        md_table(["Mechanism", "n", "Surviving", "Failed", "Unknown", "Failed share"], rows3),
        "",
        "## Table 4. Failure modes among failed eligible campaigns",
        md_table(["Failure code"] + MECHANISMS + ["Total"], rows4),
        "",
        f"Post-raise accountability modes (exit scam, soft rug, governance failure, slow death) "
        f"account for {len(post)} of the {len(coded)} failures that met a codebook threshold. "
        "This is a descriptive share within a small curated list, not a test of the "
        "accountability-gap hypothesis.",
        "",
        "## Table 5. Capital raised by eligible campaigns (nominal USD as reported)",
        md_table(["Mechanism", "n with amount", "Median", "Min", "Max", "Sum"], rows5),
        "",
        f"The three largest raises ({', '.join(cap['top3_names'])}) make up "
        f"{cap['top3_share']:.0%} of the sum, so medians are more informative than totals.",
        "",
        "## Table 6. Evidence quality and missing data (eligible campaigns)",
        md_table(["Item", "Value"], rows6),
        "",
        "## Table 7. DAICO rows",
        md_table(["Row", "Name", "Record type", "Mechanism fit", "Outcome", "Raise"], rows7),
        "",
        "## Table 8. Entities with more than one row",
        md_table(["Entity", "Rows"], rows8),
        "",
    ]
    return merged, summary, "\n".join(md)


def main() -> int:
    source = parse_inventory()
    codes = load_codes()
    errors = validate(source, codes)
    if errors:
        print("Coding validation failed:", *errors, sep="\n  ", file=sys.stderr)
        return 1
    merged, summary, md = build(source, codes)
    OUT.mkdir(exist_ok=True)
    fields = list(merged[0].keys())
    with (OUT / "dataset_82_coded.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        writer.writerows(merged)
    (OUT / "coding_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    (OUT / "descriptive_tables.md").write_text(md, encoding="utf-8")
    elig = summary["funnel"]["Total"]["eligible"]
    out = summary["outcomes"]["Total"]
    print(f"validated {len(merged)} rows; {elig} eligible campaigns; "
          f"{out['surviving']} surviving / {out['failed']} failed / {out['unknown']} unknown")
    print("failure modes:", {k: v for k, v in summary["failure_modes"].items() if v})
    return 0


if __name__ == "__main__":
    sys.exit(main())
