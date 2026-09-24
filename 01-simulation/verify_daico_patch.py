#!/usr/bin/env python3
"""验证 DAICO 动态阈值 patch：FOMO/herding 参数是否对 raise/destroy 频率有显著影响。

三组 agent 数量 x 三组 FOMO level，每组 1000 次 Monte Carlo。
"""
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

import random
from dataclasses import dataclass, field
from capstone_sim_v4 import DAICOSim, Agent

RUNS = 1000
TICKS = 20  # 每次模拟跑 20 轮
FOMO_LEVELS = [0.0, 0.5, 1.0]
AGENT_COUNTS = [5, 50, 340]

# Agent type distribution (from sim defaults)
TYPE_DIST = {
    "rational": 0.3,
    "speculator": 0.2,
    "fomo_follower": 0.2,
    "whale": 0.2,
    "sybil": 0.1,
}


def make_agents(n: int, fomo_level: float) -> list[Agent]:
    agents = []
    for i in range(n):
        # Distribute types proportionally
        cumulative = 0.0
        roll = random.random()
        agent_type = "rational"
        for t, prob in TYPE_DIST.items():
            cumulative += prob
            if roll < cumulative:
                agent_type = t
                break
        agents.append(Agent(
            id=i,
            agent_type=agent_type,
            capital=1000.0,
            fomo_sensitivity=fomo_level,
            herding_sensitivity=fomo_level * 0.8,
        ))
    return agents


def run_trial(n: int, fomo_level: float) -> dict:
    """Run one DAICO simulation, return stats."""
    daico = DAICOSim()
    agents = make_agents(n, fomo_level)

    # Contribute some funds
    for a in agents:
        daico.contribute(a, min(a.capital, 100.0))

    raise_count = 0
    initial_tap = daico.tap_rate
    for _ in range(TICKS):
        old_tap = daico.tap_rate
        daico.tick(agents)
        if daico.tap_rate > old_tap:
            raise_count += 1
        if daico.destroyed:
            break

    return {
        "destroyed": daico.destroyed,
        "raise_count": raise_count,
        "final_tap": daico.tap_rate,
        "rounds": daico.rounds,
    }


def main():
    print("DAICO Patch 验证 — FOMO/Herding 影响测试")
    print("=" * 70)
    print(f"每组 {RUNS} 次 Monte Carlo, {TICKS} ticks/run")
    print()

    for n in AGENT_COUNTS:
        print(f"\n--- n={n} agents ---")
        print(f"{'FOMO':>6} | {'Destroy%':>9} | {'Avg Raises':>10} | {'Avg Final Tap':>13} | {'Avg Rounds':>10}")
        print("-" * 60)

        results = {}
        for fomo in FOMO_LEVELS:
            random.seed(42)  # reproducible
            trials = [run_trial(n, fomo) for _ in range(RUNS)]

            destroy_pct = sum(1 for t in trials if t["destroyed"]) / RUNS * 100
            avg_raises = sum(t["raise_count"] for t in trials) / RUNS
            avg_tap = sum(t["final_tap"] for t in trials) / RUNS
            avg_rounds = sum(t["rounds"] for t in trials) / RUNS

            results[fomo] = {
                "destroy_pct": destroy_pct,
                "avg_raises": avg_raises,
                "avg_tap": avg_tap,
                "avg_rounds": avg_rounds,
            }

            print(f"{fomo:>6.1f} | {destroy_pct:>8.1f}% | {avg_raises:>10.2f} | {avg_tap:>13.5f} | {avg_rounds:>10.1f}")

        # Check if FOMO has meaningful effect
        d0 = results[0.0]["destroy_pct"]
        d1 = results[1.0]["destroy_pct"]
        r0 = results[0.0]["avg_raises"]
        r1 = results[1.0]["avg_raises"]

        print(f"\n  Effect: Destroy {d0:.1f}% -> {d1:.1f}% (delta {d1-d0:+.1f}pp)")
        print(f"  Effect: Raises {r0:.2f} -> {r1:.2f} (delta {r1-r0:+.2f})")

        if abs(d1 - d0) < 1.0 and abs(r1 - r0) < 0.5:
            print("  ⚠️  FOMO effect still negligible!")
        else:
            print("  ✅ FOMO has meaningful impact")

    print("\n" + "=" * 70)
    print("Done.")


if __name__ == "__main__":
    main()
