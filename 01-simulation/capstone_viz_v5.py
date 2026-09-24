"""
Capstone: Intelligent Capital Formation - Visualization for Simulation v5.0
DAICO vs Reverse Dutch Auction vs LAF, across behavioral scenarios and
calibration profiles.

Runs the v5 sweeps (same seeds as capstone_sim_v5.py, N=50) and renders five
figures with a `_v5` suffix into figures/, plus capstone_v5_figures.pdf. The
v4 figures are not touched. capstone_viz_v4.py is imported for the shared
style, labels and palette so the two figure sets look like one family.

Chart rules applied (dataviz skill): one colour per mechanism, never by rank
(DAICO blue, RDA orange, LAF green, the seaborn colorblind palette); no
dual-axis charts; profiles are separated into small multiples; a legend for
every multi-series panel; two-hue diverging colour map with a neutral grey
midpoint for the heatmap (orange = worse, blue = better; no red/green).

Usage:  python capstone_viz_v5.py
"""

import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.lines import Line2D
import numpy as np

DOCS_DIR = os.path.dirname(os.path.abspath(__file__))
if DOCS_DIR not in sys.path:
    sys.path.insert(0, DOCS_DIR)

# Importing viz_v4 applies its rcParams and gives us the shared labels/palette.
from capstone_viz_v4 import PALETTE, SHORT_LABELS, PROFILE_TITLES, FOMO_SCENARIOS, FIG_DIR, DPI
from capstone_sim_v4 import SCENARIOS, RealDataCalibration
from capstone_sim_v5 import run_monte_carlo, VERSION

N_RUNS = 50
INK = "0.15"
MUTED = "0.45"

# Fixed colour per mechanism (entity), never reassigned by rank or panel.
C_DAICO = PALETTE[0]   # blue
C_RDA = PALETTE[1]     # orange
C_LAF = PALETTE[2]     # green
MECH = [("DAICO", C_DAICO, None), ("RDA", C_RDA, "//"), ("LAF", C_LAF, "..")]

PROFILES = ("v3", "small", "large")
LABELS = [SHORT_LABELS[lbl] for lbl, _ in SCENARIOS]

# Diverging map for the heatmap: orange (worse) -> neutral grey -> blue (better).
GOODNESS_CMAP = LinearSegmentedColormap.from_list(
    "goodness", [(0.0, "#DE8F05"), (0.5, "#E6E6E3"), (1.0, "#0173B2")])


def run_all_sweeps(n_runs: int) -> dict:
    profiles = {
        "v3": {"n_agents": 30, "rounds": 50, "capital_scale": 1.0, "tap_rate": 0.01,
               "rda_start_price": 10.0, "rda_end_price": 1.0},
        "small": RealDataCalibration.small_project_config(),
        "large": RealDataCalibration.large_project_config(),
    }
    results = {}
    for pname, pconf in profiles.items():
        results[pname] = {}
        for label, params in SCENARIOS:
            print(f"  running: {pname:>5} | {label}", flush=True)
            results[pname][label] = run_monte_carlo(n_runs=n_runs, **{**pconf, **params})
    return results


# ---------------------------------------------------------------------------
# Chart 1: Gini, three mechanisms, one panel per profile
# ---------------------------------------------------------------------------
def chart1_gini_v5(results: dict) -> plt.Figure:
    fig, axes = plt.subplots(1, 3, figsize=(15, 5.2), sharey=True)
    x = np.arange(len(SCENARIOS))
    width = 0.26
    keys = {"DAICO": "daico_gini", "RDA": "rda_gini", "LAF": "laf_gini_value"}
    for ax, prof in zip(axes, PROFILES):
        for i, (name, color, hatch) in enumerate(MECH):
            vals = [results[prof][lbl][keys[name]] for lbl, _ in SCENARIOS]
            ax.bar(x + (i - 1) * width, vals, width * 0.9, label=name, color=color,
                   hatch=hatch, edgecolor="white", linewidth=1.0)
        ax.axhline(0.4, color=MUTED, linestyle="--", linewidth=1.0, label="fairness threshold 0.4")
        ax.set_title(PROFILE_TITLES[prof], color=INK)
        ax.set_xticks(x)
        ax.set_xticklabels(LABELS, rotation=30, ha="right")
        ax.grid(axis="x", visible=False)
    axes[0].set_ylabel("Gini coefficient (DAICO/RDA: tokens; LAF: $ outcome)")
    axes[0].set_ylim(0, 0.8)
    axes[0].legend(frameon=False, loc="upper left", ncol=4, fontsize=8)
    fig.suptitle(f"Token / outcome distribution fairness: DAICO vs RDA vs LAF (v{VERSION}, N={N_RUNS})",
                 fontsize=12, color=INK)
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    return fig


# ---------------------------------------------------------------------------
# Chart 2: FOMO effect on fairness, small vs large, LAF line added
# ---------------------------------------------------------------------------
def chart2_fomo_v5(results: dict) -> plt.Figure:
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.2), sharey=True)
    fomo_x = [f for f, _ in FOMO_SCENARIOS]
    series = [("DAICO", "daico_gini", C_DAICO, "o"), ("RDA", "rda_gini", C_RDA, "s"),
              ("LAF", "laf_gini_value", C_LAF, "^")]
    for ax, prof in zip(axes, ("small", "large")):
        ends = []
        for name, key, color, marker in series:
            ys = [results[prof][lbl][key] for _, lbl in FOMO_SCENARIOS]
            ax.plot(fomo_x, ys, marker=marker, markersize=8, linewidth=2, color=color, label=name,
                    markeredgecolor="white", markeredgewidth=1.0)
            ends.append((ys[-1], name))
        # Direct end labels; stagger vertically when two series end within 0.01 of each other.
        ends.sort()
        offsets = [0.0] * len(ends)
        for i in range(1, len(ends)):
            if ends[i][0] - ends[i - 1][0] < 0.01:
                offsets[i - 1] -= 6
                offsets[i] += 6
        for (val, name), dy in zip(ends, offsets):
            ax.annotate(f"{name} {val:.3f}", xy=(fomo_x[-1], val), xytext=(8, dy),
                        textcoords="offset points", va="center", fontsize=8, color=INK)
        ax.set_title(PROFILE_TITLES[prof], color=INK)
        ax.set_xlabel("FOMO level")
        ax.set_xticks(fomo_x)
        ax.set_xlim(-0.05, 0.95)
        ax.grid(axis="x", visible=False)
    axes[0].set_ylabel("Gini coefficient")
    axes[0].legend(frameon=False, loc="lower left")
    fig.suptitle("FOMO effect on fairness: RDA broadens participation as FOMO rises; "
                 "DAICO and LAF are flat because their raise is FOMO-insensitive", fontsize=11, color=INK)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    return fig


# ---------------------------------------------------------------------------
# Chart 3: team-received vs fairness, DAICO -> LAF on the same agents
# ---------------------------------------------------------------------------
def chart3_tradeoff_v5(results: dict) -> plt.Figure:
    fig, axes = plt.subplots(1, 3, figsize=(15, 5.2), sharey=True)
    for ax, prof in zip(axes, PROFILES):
        for lbl, params in SCENARIOS:
            res = results[prof][lbl]
            size = 50 + params["fomo"] * 300
            dx, dy = res["daico_efficiency"], res["daico_gini"]
            lx, ly = res["laf_team_received"], res["laf_gini_value"]
            ax.plot([dx, lx], [dy, ly], color="0.75", linewidth=1, zorder=1)
            ax.scatter([dx], [dy], s=size, color=C_DAICO, marker="o", edgecolors="white",
                       linewidths=1.2, zorder=2)
            ax.scatter([lx], [ly], s=size, color=C_LAF, marker="^", edgecolors="white",
                       linewidths=1.2, zorder=3)
        ax.set_title(PROFILE_TITLES[prof], color=INK)
        ax.set_xlabel("share of raise received by the team")
        ax.xaxis.set_major_formatter(lambda v, _: f"{v:.0%}")
        ax.set_xlim(0.2, 0.7)
    axes[0].set_ylabel("Gini (DAICO: tokens; LAF: $ outcome)")
    handles = [
        Line2D([], [], marker="o", color=C_DAICO, linestyle="", markersize=9, label="DAICO (release efficiency)"),
        Line2D([], [], marker="^", color=C_LAF, linestyle="", markersize=9, label="LAF (team received)"),
        Line2D([], [], color="0.75", linewidth=1, label="same scenario, same agents"),
        Line2D([], [], marker="o", color="0.6", linestyle="", markersize=5, label="FOMO 0"),
        Line2D([], [], marker="o", color="0.6", linestyle="", markersize=11, label="FOMO 0.7"),
    ]
    axes[2].legend(handles=handles, frameon=False, loc="lower right", fontsize=8)
    fig.suptitle("Team funding vs fairness: each grey line joins DAICO and LAF for the same scenario "
                 "on the same agent population (marker size = FOMO)", fontsize=11, color=INK)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    return fig


# ---------------------------------------------------------------------------
# Chart 4: where the raise ends up under LAF (stacked, single axis)
# ---------------------------------------------------------------------------
def chart4_capital_split_v5(results: dict) -> plt.Figure:
    fig, axes = plt.subplots(1, 3, figsize=(15, 5.4), sharey=True)
    y = np.arange(len(SCENARIOS))
    seg = [("laf_team_received", "team received (stream)", C_LAF),
           ("laf_recovery_total", "returned to investors (rage quit)", C_DAICO),
           (None, "still in vault", "#BFC5C9")]
    for ax, prof in zip(axes, PROFILES):
        team = np.array([results[prof][lbl]["laf_team_received"] for lbl, _ in SCENARIOS])
        back = np.array([results[prof][lbl]["laf_recovery_total"] for lbl, _ in SCENARIOS])
        vault = np.clip(1.0 - team - back, 0, 1)
        left = np.zeros(len(SCENARIOS))
        for vals, (_, name, color) in zip((team, back, vault), seg):
            ax.barh(y, vals, left=left, height=0.62, color=color, label=name,
                    edgecolor="white", linewidth=1.5)
            for i, v in enumerate(vals):
                if v >= 0.08:
                    ax.text(left[i] + v / 2, y[i], f"{v:.0%}", ha="center", va="center",
                            fontsize=8, color="white" if color != "#BFC5C9" else INK)
            left = left + vals
        daico = [results[prof][lbl]["daico_retention"] for lbl, _ in SCENARIOS]
        # Reference marker sits on the upper edge of each bar so it never covers a segment label.
        ax.scatter(daico, y - 0.31, marker="v", s=48, color="white", edgecolors=INK, linewidths=1.2,
                   zorder=4, label="DAICO capital retention (reference)")
        ax.set_yticks(y)
        ax.set_yticklabels(LABELS)
        ax.invert_yaxis()
        ax.set_xlim(0, 1)
        ax.xaxis.set_major_formatter(lambda v, _: f"{v:.0%}")
        ax.set_xlabel("share of total raise")
        ax.set_title(PROFILE_TITLES[prof], color=INK)
        ax.grid(axis="y", visible=False)
    axes[0].legend(frameon=False, loc="lower left", fontsize=8, bbox_to_anchor=(0, -0.42), ncol=2)
    fig.suptitle("LAF: where the raise ends up after the horizon (team / investors / vault), "
                 "with DAICO's retention on the same agents for reference", fontsize=11, color=INK)
    fig.tight_layout(rect=[0, 0.06, 1, 0.94])
    return fig


# ---------------------------------------------------------------------------
# Chart 5: metric heatmap, v4 columns + LAF columns
# ---------------------------------------------------------------------------
HEATMAP_METRICS = [
    ("daico_efficiency", "DAICO\nefficiency", True, "{:.1%}"),
    ("daico_gini", "DAICO\nGini", False, "{:.3f}"),
    ("rda_gini", "RDA\nGini", False, "{:.3f}"),
    ("rda_participants", "RDA\nparticipants", True, "{:.0f}"),
    ("rda_volatility", "RDA\nvolatility", False, "{:.4f}"),
    ("laf_team_received", "LAF team\nreceived", True, "{:.1%}"),
    ("laf_gini_value", "LAF\nGini $", False, "{:.3f}"),
    ("laf_recovery_quitters", "LAF recovery\n(quitters)", True, "{:.1%}"),
    ("laf_quit_frac", "LAF rage-\nquit rate", False, "{:.1%}"),
    ("laf_terminal", "LAF\nterminal", False, "{:.0%}"),
]
PER_PROFILE_COLS = {"rda_participants", "rda_volatility"}


def chart5_heatmap_v5(results: dict) -> plt.Figure:
    row_labels, raw = [], []
    for prof in PROFILES:
        for lbl, _ in SCENARIOS:
            row_labels.append(f"{prof} | {SHORT_LABELS[lbl]}")
            raw.append([results[prof][lbl][k] for k, _, _, _ in HEATMAP_METRICS])
    raw = np.array(raw)
    n_scen = len(SCENARIOS)
    good = np.zeros_like(raw)
    for j, (key, _, higher_better, _) in enumerate(HEATMAP_METRICS):
        if key in PER_PROFILE_COLS:
            for b in range(len(PROFILES)):
                block = raw[b * n_scen:(b + 1) * n_scen, j]
                rng = block.max() - block.min()
                good[b * n_scen:(b + 1) * n_scen, j] = (block - block.min()) / rng if rng > 0 else 0.5
        else:
            col = raw[:, j]
            rng = col.max() - col.min()
            good[:, j] = (col - col.min()) / rng if rng > 0 else 0.5
        if not higher_better:
            good[:, j] = 1 - good[:, j]

    fig, ax = plt.subplots(figsize=(15, 8.5))
    im = ax.imshow(good, cmap=GOODNESS_CMAP, aspect="auto", vmin=0, vmax=1)
    ax.set_xticks(range(len(HEATMAP_METRICS)))
    ax.set_xticklabels([t for _, t, _, _ in HEATMAP_METRICS], fontsize=9)
    ax.set_yticks(range(len(row_labels)))
    ax.set_yticklabels(row_labels, fontsize=9)
    ax.grid(visible=False)
    for b in (1, 2):
        ax.axhline(b * n_scen - 0.5, color=INK, linewidth=1.2)
    ax.axvline(4.5, color=INK, linewidth=1.2)
    for i in range(raw.shape[0]):
        for j, (_, _, _, fmt) in enumerate(HEATMAP_METRICS):
            ax.text(j, i, fmt.format(raw[i, j]), ha="center", va="center", fontsize=8, color=INK)
    cbar = fig.colorbar(im, ax=ax, shrink=0.6, pad=0.02)
    cbar.set_label("relative goodness (blue = better, orange = worse)", fontsize=9)
    ax.set_title(f"Metric comparison v{VERSION}: 7 scenarios x 3 profiles, DAICO / RDA (left) and LAF (right)\n"
                 "participants and volatility coloured within profile; all other columns coloured globally",
                 fontsize=11, color=INK)
    fig.tight_layout()
    return fig


def main():
    print(f"Capstone viz v{VERSION} -- running sweeps (N={N_RUNS} Monte Carlo per scenario)")
    results = run_all_sweeps(N_RUNS)

    charts = [
        ("fig1_gini_comparison_v5.png", chart1_gini_v5),
        ("fig2_fomo_fairness_v5.png", chart2_fomo_v5),
        ("fig3_efficiency_tradeoff_v5.png", chart3_tradeoff_v5),
        ("fig4_laf_capital_split_v5.png", chart4_capital_split_v5),
        ("fig5_metric_heatmap_v5.png", chart5_heatmap_v5),
    ]
    pdf_path = os.path.join(FIG_DIR, "capstone_v5_figures.pdf")
    with PdfPages(pdf_path) as pdf:
        for fname, fn in charts:
            fig = fn(results)
            out = os.path.join(FIG_DIR, fname)
            fig.savefig(out, dpi=DPI, bbox_inches="tight")
            pdf.savefig(fig, bbox_inches="tight")
            plt.close(fig)
            print(f"  saved {out}")
    print(f"  saved {pdf_path}")

    for prof, scen_map in results.items():
        for lbl, res in scen_map.items():
            assert 0 <= res["daico_gini"] <= 1 and 0 <= res["rda_gini"] <= 1, (prof, lbl)
            assert 0 <= res["laf_gini_value"] <= 1 and 0 <= res["laf_gini"] <= 1, (prof, lbl)
            assert 0 <= res["laf_team_received"] <= 1 and 0 <= res["laf_recovery_total"] <= 1, (prof, lbl)
            assert res["laf_team_received"] + res["laf_recovery_total"] <= 1 + 1e-9, (prof, lbl)
    print("All v5 figures generated; metric sanity checks passed.")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
