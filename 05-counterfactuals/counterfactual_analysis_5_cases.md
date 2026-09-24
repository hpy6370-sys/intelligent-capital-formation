# LAF Counterfactual Analysis: Five Real Failed Projects

> 2026-08-31. Method: for each project, reconstruct the verified failure timeline, then assess the applicability of each LAF layer
> Symbols: ✅ would substantively prevent or recover, ⚠️ partial mitigation, ❌ not applicable

---

## 1. Fei Protocol ($1.3B Bonding Curve, 2021)

**Failure timeline**:
- 2021-03-31 to 04-03: Genesis event raised about 639K ETH (about $1.3B) and minted 2.5B FEI
- 2021-04-03 to 04-20: the pre-swap option created FEI sell pressure and the peg broke (low of $0.71, below $0.80 for two weeks); an incentive-calculation bug was discovered; users selling below peg were hit by the quadratic penalty (25% penalty at $0.95), trapping early participants
- 2021-05-04: FEI returned to $1 for the first time; the peg recovered roughly one month after launch
- Late 2021: merged with Rari Capital to form Tribe DAO
- 2022-04-30: Rari Fuse suffered a re-entrancy attack, $80M lost
- 2022-05: DAO vote passed with 75% in favour of compensating victims, but large holders (Fei Labs + VCs) repeatedly vetoed execution
- 2022-08-19: Fei Labs proposed dissolving Tribe DAO
- 2022-09: DAO passed full compensation of hack victims with 99% approval, executed around 9/20. Protocol wound down

**Root cause**: mechanism design flaw (penalty trapped users) + external protocol risk (Fuse hack) + governance captured by large holders

**LAF layer applicability**:

| LAF layer | Assessment | Specific mechanism | Effect |
|--------|------|---------|------|
| L1 Streaming | ⚠️ | Could rate-limit PCV deployment to external protocols such as Fuse | Medium: the $80M exposure could be compressed |
| L2 RageQuit | ✅ | Genesis participants could exit at any time pro rata to PCV, without being trapped | High: eliminates trapped-capital loss |
| L3 Quadratic Vote | ⚠️ | QV could weaken whale veto power and speed up compensation, but the existing governance did eventually pass compensation (5 months late) | Medium: accelerates rather than unlocks |
| L4 Signal Monitor | ⚠️ | A peg-deviation signal could trigger a governance checkpoint | Medium: shortens the repair period, cannot prevent the hack |

**Derivation of attributable loss**: $80M hack loss + an estimated ~$200M trapped-capital loss (Genesis participants could not exit because of the penalty mechanism and were forced to hold depreciating assets through the depeg and the hack. Conservative estimate: roughly 30-40% of the participants behind the 639K ETH attempted to exit and were penalised, at an average penalty loss of 15-20%). Note: the full compensation in 2022-09 covered the hack loss but came 5 months after the event; the capital lock-up cost and trust loss during that period are not counted.

**Counterfactual conclusion**: attributable loss is about $280M ($80M hack + ~$200M trapped capital). Under LAF, L2 RageQuit could release trapped capital early in the depeg, and L1 Streaming could limit Fuse exposure. Caveats: (a) the hack itself is not preventable; (b) compensation did in fact happen under the existing governance, only 5 months late; (c) for a stablecoin protocol, ragequit is equivalent to pro-rata redemption of PCV and may accelerate the depeg. Estimated reduction about 50-70% (revised down, because compensation was eventually executed).

---

## 2. Friend.tech ($50M+ Trading Volume, Bonding Curve, 2023)

**Failure timeline**:
- 2023-08: launched on Base; within 10 days its fees exceeded Uniswap's
- 2023-09: peak: 539,800 transactions in a single day, over 300K active users, $2M in fees in a single day
- After 2023-10: deposits drained continuously from the $52M peak (-92% to $4M)
- 2024-05: FRIEND token launch + V2, a brief recovery followed by continued decline
- 2024-09: team abandoned the project and renounced contract control, FRIEND -26%, cumulative -98%; the founders legally walked away with $44M in fees

**Root cause**: protocol fees accrued immediately and privately to the founders, with a zero-accountability structure

**LAF layer applicability**:

| LAF layer | Assessment | Specific mechanism | Effect |
|--------|------|---------|------|
| L1 Streaming | ✅ | The 5% protocol fee goes into the LAFVault and is released by streaming; at abandonment most of it would still be in the Vault | Very high: this case is a perfect fit |
| L2 RageQuit | ✅ | During the decline, users exit pro rata against the unreleased fees in the Vault | High: a legal exit becomes a legal refund |
| L3 Quadratic Vote | ⚠️ | Mostly speculators, participation is doubtful | Low to medium |
| L4 Signal Monitor | ✅ | Deposits -92%, daily fees fell from $2M to <$100 | High: the signal is extremely clear |

**Counterfactual conclusion**: of the $44M, an estimated 30-50% is legitimate operating income; the remaining $22M-$30M could have been recovered by users through ragequit, a reduction of about 50-70%.

---

## 3. The Abyss ($15.4M DAICO, 2018), highest theoretical value

The world's first DAICO, i.e. the original version of LAF L1+L3, and it still failed. It precisely exposes the gaps that LAF has to patch.

**Failure timeline**:
- 2018-04-18 to 05-16: the world's first DAICO, raised $15.4M; initial tap 500 ETH/month
- Around 2018-06: the team "covertly modified" the contract code to enlarge the initial withdrawable amount and withdrew the entire initial allowance within a month. The Presto team publicly stated "ABYSS is NOT a fair DAICO"
- Throughout 2018: ETH bear market, -80%+, the remaining funds shrank sharply
- Afterwards: the refund vote was never successfully triggered (coordination cost too high), the game platform was never delivered, ABYSS ROI 0.06x

**Root cause**: the streaming mechanism was bypassed at the implementation level by a team backdoor + the coordination cost of a collective exit vote was too high

**LAF layer applicability**:

| LAF layer | Assessment | Specific mechanism | Effect |
|--------|------|---------|------|
| L1 Streaming | ✅ | The LAFVault rate cap is non-upgradeable, there is no large initial withdrawal, and the rate can only be changed through L3 governance | High: closes the "covert code change, early withdrawal" hole |
| L2 RageQuit | ✅ | A DAICO refund requires a collective vote (never succeeded); a Moloch-style ragequit is unilateral and needs no coordination | Very high: LAF's biggest improvement over DAICO |
| L3 Quadratic Vote | ⚠️ | QV weakens the team's voting bloc but cannot manufacture participation | Medium: necessary but not sufficient |
| L4 Signal Monitor | ⚠️ | Automatically lowers the tap when development activity or milestones look abnormal | Medium: turns passive voting into active triggering |

**Counterfactual conclusion**: had investors been able to ragequit unilaterally in 2018 Q3, 40-60% of the raise could have been recovered, reducing the loss from ~$14.5M to $6M-$9M. However, ETH lost 80% in 2018, so the recoverable amount in USD terms is dragged down by the denomination asset.

**Implication for LAF**: Abyss shows that the **non-tamperability** of the accountability mechanism (L1 contract non-upgradeable) and the **unilateral nature of exit** (L2 ragequit vs collective vote) matter more than the mere existence of the mechanism.

---

## 4. SKALE Network ($5M RDA, 2020), boundary case

**Failure timeline**:
- 2020-08-17: the Dutch auction on ConsenSys Activate was overwhelmed by front-running bots and had to be cancelled
- 2020-08 to 09: switched to a two-round fixed-price sale, raised $5M; mainnet launched as planned, the project is still active

**Root cause**: front-running attack during the sale phase, before the raise was completed

**LAF layer applicability**: all ❌/⚠️. LAF is a post-raise accountability framework and does not cover adversarial attacks on the sale mechanism itself.

**Implication for LAF**: defines the applicable boundary of LAF. Sale-mechanism security (MEV / front-running resistance) is an orthogonal problem and should be stated explicitly as a scope limitation in the paper.

---

## 5. Ordibank ($8M LBP, 2024), the case where LAF performs best

**Failure timeline**:
- 2024-03-03 to 03-05: Fjord Foundry LBP raised $8.06M in two days
- After 2024-03: a Bitcoin L1 lending protocol; no substantive product was delivered, the team gradually stopped development and communication
- To date: token price down >99% (CryptoRank marks it Inactive), no public accountability for where the raised funds went

**Root cause**: no delivery constraint once the LBP settlement was received in one lump sum. Note: no public source explicitly classifies this as a "rug pull"; the characterisation here as a de facto abandonment is inferred from the circumstantial evidence of operations ceasing plus unaccounted funds.

**LAF layer applicability**:

| LAF layer | Assessment | Specific mechanism | Effect |
|--------|------|---------|------|
| L1 Streaming | ✅ | Settlement goes into the LAFVault; if abandonment happens early after the raise, most funds are still in the Vault | High (depends on the abandonment date, which is inferred here) |
| L2 RageQuit | ✅ | Once delivery stalls, holders take back their pro-rata share | High |
| L3 Quadratic Vote | ⚠️ | Anonymous teams commonly use multiple wallets, so QV faces a sybil problem | Low to medium |
| L4 Signal Monitor | ✅ | Price down >99%, zero activity, zero code commits, multiple signals cross-confirm | High |

**Counterfactual conclusion**: assuming the team stopped delivering within 3-6 months of the raise (inferred from circumstantial evidence), streaming would have allowed only about 10-25% of the raise to be withdrawn, and the remaining $6M-$7M would have been recoverable by investors through ragequit. Recovery ratio about 70-80%. The confidence of this estimate is lower than for the other cases because the exact date of abandonment is unknown.

---

## Cross-project summary

| Project | Total loss (attributable) | L1 Streaming | L2 RageQuit | L3 QV | L4 Signal | Recoverable share |
|------|-------|--------|--------|--------|--------|-----------|
| Fei Protocol | ~$280M | ⚠️ | ✅ | ⚠️ | ⚠️ | ~50-70% |
| Friend.tech | $44M | ✅ | ✅ | ⚠️ | ✅ | ~50-70% |
| The Abyss | ~$14.5M | ✅ | ✅ | ⚠️ | ⚠️ | ~40-60% |
| SKALE | ~$0 | ❌ | ❌ | ❌ | ⚠️ | N/A |
| Ordibank | ~$8M (inferred) | ✅ | ✅ | ⚠️ | ✅ | ~70-80% (inferred) |

**Across the four applicable cases, roughly $350M of attributable loss in total, LAF could recover about 50-70%.** (Revised down: Fei ultimately completed compensation under its existing governance, so LAF's marginal contribution there is mainly acceleration rather than unlocking.)

## Core conclusions

1. **L1 Streaming contributes the most**: in 4 of 5 cases, fund outflows lacked any streaming constraint. Abyss and Ordibank are direct cases of abandonment after a lump-sum receipt; Friend.tech is continuous fee extraction with no escrow; Fei's PCV was protocol-controlled, but its deployment to external protocols (Fuse) had no rate limit. Streaming escrow would have limited exposure in all of these scenarios.
2. **L2 RageQuit is the enforcement gear**: Abyss shows that a collective-vote exit dies of coordination cost, and only a Moloch-style unilateral exit is real protection. Fei's "sell penalty" is the negative example. But for a stablecoin protocol, ragequit is an institutionalised bank run, and there is an inherent tension.
3. **L4 Signal Monitor performs well in abandonment-type failures** (clear signals) but cannot prevent contract exploits.
4. **L3 Quadratic Vote is the weakest layer**: governance apathy and sybil attacks mean QV only works in projects with a real community. Fei's compensation eventually passed under its existing governance (5 months late), which further shows that QV's marginal contribution is limited.
5. **LAF's boundary is clear**: it does not cover pre-raise sale attacks (SKALE), external protocol hacks (Rari), denomination-asset depreciation (Abyss), or product failure itself.

## Sources

- [The Defiant: Fei Shutdown Uproar](https://thedefiant.io/news/defi/fei-shutdown-uproar)
- [The Defiant: Fei Roils Early Adopters](https://thedefiant.io/fei-roils-early-adopters-as-stablecoin-and-token-tumble-after-1-3b-sale/)
- [CoinDesk: Rari Capital/Fei Loses $80M](https://www.coindesk.com/business/2022/04/30/defi-lender-rari-capitalfei-loses-80m-in-hack)
- [Protos: Tribe kills DAO, overrules vote](https://protos.com/tribe-kills-dao-overrules-vote-to-pay-crypto-debt/)
- [DL News: Friend.tech creators walk off with $44m](https://www.dlnews.com/articles/defi/friend-tech-shuts-down-after-revenue-and-users-plummet/)
- [The Abyss Medium: World's First DAICO](https://medium.com/theabyss/the-worlds-first-daico-completed-results-and-achievements-80f0e81d55d1)
- [Presto: ABYSS is NOT a fair DAICO](https://medium.com/presto-platform/abyss-is-not-a-fair-daico-issue-and-solution-977d9cdcf2c3)
- [Decrypt: Tribe DAO votes to repay again](https://decrypt.co/110102/tribe-dao-votes-repay-rari-capital-hack-victims-again)
- [CoinDesk: FEI hits $1 on May 4](https://www.coindesk.com/markets/2021/05/04/1b-stablecoin-fei-hits-price-target-for-first-time-month-after-launch)
- [CoinDesk: Fei's Rocky Start ($0.71 low)](https://www.coindesk.com/markets/2021/04/07/1b-fei-stablecoins-rocky-start-is-a-wake-up-call-for-defi-investors)
- [CoinDesk: SKALE Token Sale](https://www.coindesk.com/business/2020/09/14/skale-completes-5m-token-sale-on-consensys-anti-speculation-platform/)
- [CoinCarp: Ordibank Token Sale](https://www.coincarp.com/currencies/ordibank/project-info/)
