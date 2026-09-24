"""
Sensitivity appendix for simulation v5.0: how much of the LAF result is driven
by assumption A4 (the DAICO destroy-vote propensity reused as the per-round
probability of a rational/whale becoming concerned and exiting).

Runs the baseline scenario for all three calibration profiles with the A4
probability scaled by 1.0 (DAICO parity, the main run), 0.5, 0.25 and 0.0
(nobody ever loses faith without a signal). Everything else is identical to
the main run, including seeds. Output is a small table on stdout; it is NOT
part of simulation_v5_results.txt.

Run:  python sim_v5_sensitivity.py
"""

import sys
import capstone_sim_v5 as v5
from capstone_sim_v4 import RealDataCalibration

N = 50
SCALES = [1.0, 0.5, 0.25, 0.0]
PROFILES = {
    "v3": {"n_agents": 30, "rounds": 50, "capital_scale": 1.0, "tap_rate": 0.01,
           "rda_start_price": 10.0, "rda_end_price": 1.0},
    "small": RealDataCalibration.small_project_config(),
    "large": RealDataCalibration.large_project_config(),
}
KEYS = [("laf_team_received", "TeamRcv", "{:.1%}"), ("laf_recovery_total", "RecovAll", "{:.1%}"),
        ("laf_recovery_quitters", "RecovQ", "{:.1%}"), ("laf_quit_frac", "Quit%", "{:.1%}"),
        ("laf_terminal", "Term%", "{:.0%}"), ("laf_gini_value", "Gini$", "{:.3f}"),
        ("laf_checkpoints", "CP", "{:.2f}"), ("laf_act_pause", "PAUSE", "{:.2f}"),
        ("laf_rule2_pauses", "Rule2", "{:.2f}"), ("laf_signal_triggers", "Sig", "{:.2f}")]


def main():
    print(f"v5 sensitivity: A4 concern probability scale, baseline scenario, N={N}")
    print(f"{'profile':<7} {'scale':>5} | " + " ".join(f"{h:>8}" for _, h, _ in KEYS))
    print("-" * (16 + 9 * len(KEYS)))
    rows = {}
    for pname, pconf in PROFILES.items():
        for s in SCALES:
            v5.LAF_CONCERN_SCALE = s
            res = v5.run_monte_carlo(n_runs=N, fomo=0.0, herding=0.0, **pconf)
            rows[(pname, s)] = res
            print(f"{pname:<7} {s:>5.2f} | " + " ".join(f"{fmt.format(res[k]):>8}" for k, _, fmt in KEYS))
    v5.LAF_CONCERN_SCALE = 1.0
    # Check: scale 1.0 must reproduce the main run's baseline numbers exactly.
    main_v3 = v5.run_monte_carlo(n_runs=N, fomo=0.0, herding=0.0, **PROFILES["v3"])
    assert main_v3["laf_team_received"] == rows[("v3", 1.0)]["laf_team_received"]
    print("check: scale 1.0 reproduces the main run (v3 baseline) -> ok")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
