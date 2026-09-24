"""
Capstone: Intelligent Capital Formation - Visualization for Simulation v4
DAICO vs Reverse Dutch Auction, across behavioral scenarios and calibration profiles.

Runs the v4 simulation sweeps (v3 defaults / small_project / large_project,
N=50 Monte Carlo each) and renders five publication-quality figures into
docs/figures/, plus a combined PDF.

Usage:  python capstone_viz_v4.py
"""

import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
import numpy as np
import seaborn as sns

# Make capstone_sim_v4 importable regardless of where this script is run from.
DOCS_DIR = os.path.dirname(os.path.abspath(__file__))
if DOCS_DIR not in sys.path:
    sys.path.insert(0, DOCS_DIR)

from capstone_sim_v4 import SCENARIOS, RealDataCalibration, run_monte_carlo

FIG_DIR = os.path.join(DOCS_DIR, "figures")
os.makedirs(FIG_DIR, exist_ok=True)

N_RUNS = 50
DPI = 300

# ---------------------------------------------------------------------------
# Style
# ---------------------------------------------------------------------------
PALETTE = sns.color_palette("colorblind")  # colorblind-friendly, fixed order
# Fixed color assignment by entity (mechanism x profile), never by rank:
C_DAICO_V3 = PALETTE[0]    # blue
C_RDA_V3 = PALETTE[1]      # orange
C_DAICO_SMALL = PALETTE[2] # green
C_RDA_SMALL = PALETTE[3]   # red-brown
C_DAICO_LARGE = PALETTE[4] # purple
C_RDA_LARGE = PALETTE[5]   # brown
PROFILE_COLORS = {"v3": PALETTE[0], "small": PALETTE[2], "large": PALETTE[4]}

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.size": 11,
    "axes.labelsize": 11,
    "axes.titlesize": 12,
    "xtick.labelsize": 10,
    "ytick.labelsize": 10,
    "legend.fontsize": 9,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": True,
    "grid.alpha": 0.25,
    "grid.linewidth": 0.5,
    "figure.autolayout": False,
})

SHORT_LABELS = {
    "Baseline (no behavioral effects)": "Baseline",
    "FOMO = 0.3": "FOMO 0.3",
    "FOMO = 0.5": "FOMO 0.5",
    "FOMO = 0.7": "FOMO 0.7",
    "FOMO=0.5 + Herding=0.3": "F0.5+H0.3",
    "FOMO=0.5 + Herding=0.6": "F0.5+H0.6",
    "High FOMO=0.7 + Herding=0.5": "F0.7+H0.5",
}

PROFILE_TITLES = {
    "v3": "v3 defaults (uncalibrated)",
    "small": "small_project (Solana-scale)",
    "large": "large_project (Casper/Mina/Flow-scale)",
}


# ---------------------------------------------------------------------------
# Run the sweeps (quietly - no run_sweep printing)
# ---------------------------------------------------------------------------
def run_all_sweeps(n_runs: int) -> dict:
    """Return {profile: {scenario_label: metrics_dict}}."""
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
            print(f"  running: {pname:>5} | {label}")
            results[pname][label] = run_monte_carlo(n_runs=n_runs, **{**pconf, **params})
    return results


# ---------------------------------------------------------------------------
# Chart 1: Gini comparison, grouped bars
# ---------------------------------------------------------------------------
def chart1_gini_comparison(results: dict) -> plt.Figure:
    labels = [SHORT_LABELS[lbl] for lbl, _ in SCENARIOS]
    series = [
        ("DAICO v3", "v3", "daico_gini", C_DAICO_V3, None),
        ("RDA v3", "v3", "rda_gini", C_RDA_V3, "//"),
        ("DAICO small", "small", "daico_gini", C_DAICO_SMALL, None),
        ("RDA small", "small", "rda_gini", C_RDA_SMALL, "//"),
        ("DAICO large", "large", "daico_gini", C_DAICO_LARGE, None),
        ("RDA large", "large", "rda_gini", C_RDA_LARGE, "//"),
    ]

    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(len(SCENARIOS))
    width = 0.13

    for i, (name, prof, key, color, hatch) in enumerate(series):
        vals = [results[prof][lbl][key] for lbl, _ in SCENARIOS]
        ax.bar(x + (i - 2.5) * width, vals, width * 0.92, label=name,
               color=color, hatch=hatch, edgecolor="white", linewidth=0.5)

    ax.axhline(0.4, color="0.35", linestyle="--", linewidth=1.2,
               label="fairness threshold (0.4)")

    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=20, ha="right")
    ax.set_ylabel("Gini coefficient (token distribution)")
    ax.set_title("Token Distribution Fairness: DAICO vs RDA across Calibration Profiles")
    ax.set_ylim(0, max(0.75, ax.get_ylim()[1]))
    ax.legend(ncol=4, frameon=False, loc="upper left")
    ax.grid(axis="x", visible=False)
    fig.tight_layout()
    return fig


# ---------------------------------------------------------------------------
# Chart 2: FOMO effect on fairness, line chart, small vs large
# ---------------------------------------------------------------------------
FOMO_SCENARIOS = [
    (0.0, "Baseline (no behavioral effects)"),
    (0.3, "FOMO = 0.3"),
    (0.5, "FOMO = 0.5"),
    (0.7, "FOMO = 0.7"),
]


def chart2_fomo_fairness(results: dict) -> plt.Figure:
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.5), sharey=True)
    fomo_x = [f for f, _ in FOMO_SCENARIOS]

    for ax, prof in zip(axes, ("small", "large")):
        d_gini = [results[prof][lbl]["daico_gini"] for _, lbl in FOMO_SCENARIOS]
        r_gini = [results[prof][lbl]["rda_gini"] for _, lbl in FOMO_SCENARIOS]

        ax.plot(fomo_x, d_gini, marker="o", markersize=7, linewidth=2,
                color=PROFILE_COLORS["v3"], label="DAICO Gini")
        ax.plot(fomo_x, r_gini, marker="s", markersize=7, linewidth=2,
                color=PALETTE[1], label="RDA Gini")

        # Annotate the RDA improvement from FOMO=0 -> FOMO=0.7
        if r_gini[0] > 0:
            change = (r_gini[-1] - r_gini[0]) / r_gini[0]
            verb = "improvement" if change < 0 else "increase"
            ax.annotate(f"RDA Gini {abs(change):.0%} {verb}\n(FOMO 0 → 0.7)",
                        xy=(fomo_x[-1], r_gini[-1]),
                        xytext=(0.42, r_gini[-1] + (0.10 if change < 0 else -0.14)),
                        fontsize=9, color=PALETTE[1],
                        arrowprops=dict(arrowstyle="->", color=PALETTE[1], lw=1))

        ax.set_title(PROFILE_TITLES[prof])
        ax.set_xlabel("FOMO level")
        ax.set_xticks(fomo_x)
        ax.grid(axis="x", visible=False)

    axes[0].set_ylabel("Gini coefficient (token distribution)")
    axes[0].legend(frameon=False, loc="center left")
    fig.suptitle("FOMO Effect on Fairness: rising FOMO broadens RDA participation and lowers its Gini",
                 fontsize=12)
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    return fig


# ---------------------------------------------------------------------------
# Chart 3: Efficiency vs fairness trade-off, scatter
# ---------------------------------------------------------------------------
def chart3_tradeoff(results: dict) -> plt.Figure:
    fig, ax = plt.subplots(figsize=(10, 6))

    for prof in ("v3", "small", "large"):
        xs, ys, sizes = [], [], []
        for lbl, params in SCENARIOS:
            res = results[prof][lbl]
            xs.append(res["daico_efficiency"])
            ys.append(res["daico_gini"])
            sizes.append(50 + params["fomo"] * 400)
        ax.scatter(xs, ys, s=sizes, color=PROFILE_COLORS[prof],
                   alpha=0.75, edgecolors="white", linewidths=1.2,
                   label=PROFILE_TITLES[prof])

    # Size legend (FOMO level), separate from color legend
    for fomo in (0.0, 0.3, 0.7):
        ax.scatter([], [], s=50 + fomo * 400, color="0.5", alpha=0.6,
                   edgecolors="white", label=f"FOMO = {fomo}")

    ax.set_xlabel("DAICO release efficiency (funds released / total raised)")
    ax.set_ylabel("DAICO Gini coefficient")
    ax.set_title("Efficiency vs Fairness Trade-off (DAICO, all scenarios)\n"
                 "point size = FOMO level")
    ax.xaxis.set_major_formatter(lambda v, _: f"{v:.0%}")
    ax.legend(frameon=False, loc="best")
    fig.tight_layout()
    return fig


# ---------------------------------------------------------------------------
# Chart 4: RDA participation and raised amount (bar + line, twin axis)
# ---------------------------------------------------------------------------
def chart4_rda_participation(results: dict) -> plt.Figure:
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.5))
    labels = [SHORT_LABELS[lbl] for lbl, _ in SCENARIOS]
    x = np.arange(len(SCENARIOS))

    for ax, prof in zip(axes, ("small", "large")):
        raised = [results[prof][lbl]["rda_pool"] for lbl, _ in SCENARIOS]
        parts = [results[prof][lbl]["rda_participants"] for lbl, _ in SCENARIOS]

        bar_color = PROFILE_COLORS[prof]
        ax.bar(x, raised, 0.6, color=bar_color, alpha=0.85,
               edgecolor="white", linewidth=0.5)
        ax.set_ylabel("RDA total raised (sim units)", color=bar_color)
        ax.tick_params(axis="y", labelcolor=bar_color)
        ax.yaxis.set_major_formatter(lambda v, _: f"{v:,.0f}")
        ax.set_xticks(x)
        ax.set_xticklabels(labels, rotation=30, ha="right")
        ax.grid(visible=False)

        ax2 = ax.twinx()
        line_color = "0.15"
        ax2.plot(x, parts, marker="o", markersize=6, linewidth=2,
                 color=line_color)
        ax2.set_ylabel("Participants (count)", color=line_color)
        ax2.tick_params(axis="y", labelcolor=line_color)
        ax2.spines["top"].set_visible(False)
        ax2.grid(visible=False)

        ax.set_title(PROFILE_TITLES[prof])

    fig.suptitle("RDA: FOMO drives participation and total raised (bars = raised, line = participants)",
                 fontsize=12)
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    return fig


# ---------------------------------------------------------------------------
# Chart 5: Comprehensive metric heatmap (21 rows x 5 metrics)
# ---------------------------------------------------------------------------
# (metric key, column title, higher_is_better, format)
HEATMAP_METRICS = [
    ("daico_efficiency", "DAICO\nefficiency", True, "{:.1%}"),
    ("daico_gini", "DAICO\nGini", False, "{:.3f}"),
    ("rda_gini", "RDA\nGini", False, "{:.3f}"),
    ("rda_participants", "RDA\nparticipants", True, "{:.0f}"),
    ("rda_volatility", "RDA\nvolatility", False, "{:.4f}"),
]


def chart5_heatmap(results: dict) -> plt.Figure:
    profiles = ("v3", "small", "large")
    row_labels, raw = [], []
    for prof in profiles:
        for lbl, _ in SCENARIOS:
            row_labels.append(f"{prof} | {SHORT_LABELS[lbl]}")
            raw.append([results[prof][lbl][k] for k, _, _, _ in HEATMAP_METRICS])
    raw = np.array(raw)  # 21 x 5

    # Goodness score in [0,1] per cell. Scale-dependent columns (participants,
    # volatility, raised amounts) are normalized within each profile block so
    # colors compare scenarios, not raw scale differences between profiles.
    # Bounded columns (efficiency, both Ginis) are normalized globally.
    per_profile_cols = {"rda_participants", "rda_volatility"}
    good = np.zeros_like(raw)
    n_scen = len(SCENARIOS)
    for j, (key, _, higher_better, _) in enumerate(HEATMAP_METRICS):
        if key in per_profile_cols:
            for b in range(len(profiles)):
                block = raw[b * n_scen:(b + 1) * n_scen, j]
                rng = block.max() - block.min()
                norm = (block - block.min()) / rng if rng > 0 else np.full_like(block, 0.5)
                good[b * n_scen:(b + 1) * n_scen, j] = norm
        else:
            col = raw[:, j]
            rng = col.max() - col.min()
            good[:, j] = (col - col.min()) / rng if rng > 0 else 0.5
        if not higher_better:
            good[:, j] = 1 - good[:, j]

    fig, ax = plt.subplots(figsize=(12, 8))
    im = ax.imshow(good, cmap="RdYlGn", aspect="auto", vmin=0, vmax=1)

    ax.set_xticks(range(len(HEATMAP_METRICS)))
    ax.set_xticklabels([t for _, t, _, _ in HEATMAP_METRICS])
    ax.set_yticks(range(len(row_labels)))
    ax.set_yticklabels(row_labels, fontsize=9)
    ax.grid(visible=False)

    # Separator lines between profile blocks
    for b in (1, 2):
        ax.axhline(b * n_scen - 0.5, color="black", linewidth=1.2)

    # Annotate raw values
    for i in range(raw.shape[0]):
        for j, (_, _, _, fmt) in enumerate(HEATMAP_METRICS):
            ax.text(j, i, fmt.format(raw[i, j]), ha="center", va="center",
                    fontsize=8, color="black")

    cbar = fig.colorbar(im, ax=ax, shrink=0.6, pad=0.02)
    cbar.set_label("relative goodness (green = better)", fontsize=9)
    ax.set_title("Comprehensive Metric Comparison: 7 scenarios x 3 calibration profiles\n"
                 "(participants & volatility colored within-profile; efficiency & Gini colored globally)",
                 fontsize=11)
    fig.tight_layout()
    return fig


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    print(f"Capstone viz v4 -- running sweeps (N={N_RUNS} Monte Carlo per scenario)")
    results = run_all_sweeps(N_RUNS)

    charts = [
        ("fig1_gini_comparison.png", chart1_gini_comparison),
        ("fig2_fomo_fairness.png", chart2_fomo_fairness),
        ("fig3_efficiency_tradeoff.png", chart3_tradeoff),
        ("fig4_rda_participation.png", chart4_rda_participation),
        ("fig5_metric_heatmap.png", chart5_heatmap),
    ]

    pdf_path = os.path.join(FIG_DIR, "capstone_v4_figures.pdf")
    with PdfPages(pdf_path) as pdf:
        for fname, fn in charts:
            fig = fn(results)
            out = os.path.join(FIG_DIR, fname)
            fig.savefig(out, dpi=DPI, bbox_inches="tight")
            pdf.savefig(fig, bbox_inches="tight")
            plt.close(fig)
            print(f"  saved {out}")
    print(f"  saved {pdf_path}")

    # Sanity checks: every scenario/profile produced valid bounded metrics.
    for prof, scen_map in results.items():
        for lbl, res in scen_map.items():
            assert 0 <= res["daico_gini"] <= 1, (prof, lbl, res["daico_gini"])
            assert 0 <= res["rda_gini"] <= 1, (prof, lbl, res["rda_gini"])
            assert 0 <= res["daico_efficiency"] <= 1, (prof, lbl)
            assert res["rda_participants"] >= 0, (prof, lbl)
    print("All figures generated; metric sanity checks passed.")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
