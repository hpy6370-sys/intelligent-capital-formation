# Research evidence for v2 coding (failure modes and flagged rows)

Research date and access date for every source: **2026-10-17**. Only pages that were actually opened are cited. Pages that returned HTTP 403 are listed at the end and were **not** used as evidence. Codes follow `03-dataset/FAILURE-CODING-CODEBOOK.md`: outcome first, then a mode only when its threshold is met. Allegations, price collapse and enforcement without a halt never set a mode on their own.

## A. The 10 failed eligible campaigns that v1 left `unknown`

| Row | Project | v2 outcome | v2 failure mode | Conf. | One-line evidence |
|---|---|---|---|---|---|
| R06 | Sirin Labs (ICO) | dead_inactive | slow_death | Low | 2019-04: Finney sales "not what we expected"; 15 of 60 staff cut. 2026-10-17: company site returns HTTP 526. Window 2018-2026; no acute event found |
| R08 | Bankera (ICO) | dead_inactive (bank never launched; payouts halted 2022) | soft_rug | Medium | No EU banking licence ever obtained. BNK payouts halted 2022. Leaked records show EUR 45M+ moved via a Vanuatu bank into loans to founder firms. FCIS suspicion notices 2026-09 are pre-trial, so the exit scam is alleged, not found |
| R21 | Raiden Network (RDA) | dead_inactive | slow_death | Medium | Mainnet May 2020. Commits thin to 2022-06 and 2022-10; last commit 2023-10-10 "Disable nightly CI runs"; none since. No shutdown notice |
| R26 | Metronome (RDA) | **rebranded_or_merged** (was dead) | not_failed | Medium | Operating in 2026 as MetronomeDAO / Metronome Synth (msUSD/msETH). A 2026 post-mortem discloses a $15.7M synth shortfall with $34M of treasury defences staged |
| R33 | Fei Protocol (BC) | dead_inactive | other | Medium | $80M Fuse exploit (2022-04); four repayment votes (yes / reversed / rejected / 99% yes, 2022-09); Tribe DAO dissolved with FEI redeemed 1:1 for DAI. Secondary: governance_failure. Not liquidity_trap at the end |
| R45 | BIOPset (BC) | dead_inactive (row, unsourced) | unknown | Low | No dated public source found |
| R51 | ICOVO (DAICO) | dead_inactive (row, unsourced) | unknown | Low | No dated public source found (incl. Swiss-registry searches) |
| R74 | ParagonsDAO (LBP) | **active_diminished** (was dead) | not_failed | Low | Undated listing: DAO "transitioned to treasury stewardship"; play-to-earn model "did not sustain"; NFTs divested; analytics product sunset |
| R75 | APY Finance (LBP) | dead_inactive (row, unsourced) | unknown | Low | No dated public source found. Unverified lead: its Medium account may have posted as "CortexDAO" (2023-03); page 403 |
| R79 | Ordibank (LBP) | dead_inactive (row, unsourced) | unknown | Low | Price ~$0.0000545 vs $0.0812 sale price; no evidence of team exit, liquidity pull or legal action. The "rug pull" label in the row is unsupported |

### Sources (URL, publication date, access 2026-10-17)

- **R06 Sirin Labs**
  - Crowdfund Insider, "As Founder Plagued by Lawsuits, 'Blockchain Phone' Maker Sirin Labs Lays Off Staff". https://www.crowdfundinsider.com/?p=146545 (2019-04-18)
  - Company website https://www.sirinlabs.com returned HTTP 526 (observed 2026-10-17)
- **R08 Bankera**
  - OCCRP/15min investigation. https://www.occrp.org/en/investigation/co-founders-of-a-lithuanian-crypto-coin-scooped-up-luxury-property-while-investors-were-left-in-the-lurch (2025-04-28)
  - OCCRP, "Lithuanian Authorities Target Founders of Failed Cryptobank". https://www.occrp.org/en/news/lithuanian-authorities-target-founders-of-failed-cryptobank (2026-09-15)
- **R21 Raiden**
  - GitHub develop-branch commit history. https://github.com/raiden-network/raiden/commits/develop (commits 2022-06-16, 2022-10-20, 2023-10-10)
  - Repository README. https://github.com/raiden-network/raiden (undated; "work in progress"; Alderaan mainnet May 2020; not archived)
- **R26 Metronome**
  - The Defiant, "Metronome discloses $15.7 million synth shortfall, blames oracle lag in swap module". https://thedefiant.io/news/defi/metronome-discloses-usd15-7-million-synth-shortfall-blames-oracle-lag-in-swap-module (page undated; (c) 2026)
- **R33 Fei**
  - Decrypt, "Tribe DAO votes to repay Rari Capital hack victims again". https://decrypt.co/110102/tribe-dao-votes-repay-rari-capital-hack-victims-again (2022-09-19)
  - The Defiant, "Fei Community Up In Arms Over Dissolution Plan" (subhead: team cites technical challenges and future regulations). https://www.thedefiant.io/fei-shutdown-uproar (page undated; only headline and subhead loaded)
- **R74 ParagonsDAO**
  - Alchemy dapp listing. https://dapps.alchemy.com/dapps/paragons-dao (undated)
- **R79 Ordibank**
  - CoinCodex sale page. https://coincodex.com/ieo/ordibank/ (undated; sale 2024-02-21 to 2024-03-11)
- **R45, R51, R75:** no usable source.
  - https://apy.finance returned no content.
  - Searches for "BIOPset" and "ICOVO AG" returned only unrelated results.

## B. Flagged status, amount and source items

| Row | Item | Resolution | Conf. | Source (pub. date) |
|---|---|---|---|---|
| R02 TON | Primary SEC/court source | SDNY preliminary injunction 2020-03-24 barred delivery of Grams. Final judgment: $1,224,000,000 disgorgement and $18.5M penalty. **regulatory_shutdown confirmed** | High | SEC press release 2020-146 https://www.sec.gov/news/press-release/2020-146 (2020-06-26) |
| R14 OmiseGO | Status "Active (wound down)" | **dead_inactive (Low); mode unknown.** Binance delisted OMG 2024-06-17; its criteria include team commitment and development. KuCoin delisted 2025-11-19 under Special Treatment Rules, warning of possible "cessation of on-chain activities like block generation". No official wind-down notice found; evidence is market-side only | Low | The Block https://www.theblock.co/post/298063/binance-to-delist-waves-omg-and-xem-on-june-17-sparking-price-plunges (2024-06-03); KuCoin https://www.kucoin.com/en-au/announcement/kr-st-kucoin-will-delist-omg-network-omg (2025-11-18) |
| R47 BitClout | Status "Dead (rebranded DeSo, marginal)"; fraud charges | **active_diminished (DeSo), not_failed (Low).** SEC complaint (2024-07-30) alleged >$257M raised and >$7M misused. SDNY criminal complaint withdrawn 2025-02 (without prejudice). SEC case dismissed **with prejudice** 2026-03-14. No adjudicated fraud, so exit_scam is not codable. Continuation rests on the founder's statement that the team will support DeSo "indefinitely" | Low | SEC 2024-91 https://www.sec.gov/newsroom/press-releases/2024-91 (2024-07-30); The Block https://www.theblock.co/post/393611/sec-dismisses-civil-fraud-case-against-bitclout-deso-founder-nader-al-naji-with-prejudice (2026-03-14) |
| R49 The Abyss | Status "Barely Active" | Kept **active_diminished, not_failed**; confidence lowered to Low. ABYSS still trades (market cap ~$0.85M, ~$36K/24h, ~99.7% on one exchange), now described as "Abyss.Finance"; no shutdown notice. Token trading is not proof of project activity. The 05-counterfactuals "team backdoor" claim is still unsourced | Low | CoinGecko https://www.coingecko.com/en/coins/abyss (live page, observed 2026-10-17) |
| R23 Mina | Was it an auction? | **No.** 75M MINA at a fixed $0.25 = $18.75M, queue allocation, $500 cap. Mechanism contradicted, so excluded from RDA | High | Mina Foundation https://minaprotocol.com/blog/mina-foundation-broadens-token-sale-capacity-and-launches-new-grant (2021-04-09); https://minaprotocol.com/blog/mina-concludes-18-75m-community-token-sale-with-the-highest-number-of-purchasers-in-coinlist-history-to-date (2021-05-05) |
| R22 Casper | Was it an auction? / $33M | **No.** Four fixed-price CoinList options (2021-03-23 to 04-07): $12M @ $0.015, $8M @ $0.02, $12M @ $0.03, $1.5M @ $0.015 = **$33.5M**. No round described as an auction; total across 8 rounds $74.8M. The CoinList post cited by the row covers Option 4 only | Medium | ICO Drops https://icodrops.com/casperlabs (undated); CoinList blog https://blog.coinlist.co/announcing-caspers-community-members-token-sale-on-coinlist/ (undated) |
| R58 LUKSO | $18M vs ~10,000 ETH | **Reconciled.** ~10,000 ETH over an 8-month rICO (2020 to early 2021). $18M is the value near the close; at mid-2020 ETH prices it would be far lower. Kept $18M with a valuation-date note | Medium | LUKSO docs https://docs.lukso.network/faq/lukso/project-origins/ (undated); The Defiant headline https://thedefiant.io/ethereum-og-raises-18m-with-first-reversible-ico (undated; headline only) |
| R79 Ordibank | $8M vs "99M x $0.19" | **Resolved.** Fjord Foundry sale 2024-03-03 to 03-05: 99.21M ORBK at $0.0812 = ~$8.06M. All stages (incl. Ape Terminal, Gate) ~$9.1M. The row's $8M is right and its "$0.19" is wrong. CoinCodex calls the Fjord stage an IDO; the row says LBP (verify) | Medium | CoinCodex https://coincodex.com/ieo/ordibank/ (undated) |
| R39 Ocean | $39.19M vs notes | Total includes a 5th round (Cypher Capital, $5M, 2022-05-23) that the notes omit | Medium | ICO Drops https://icodrops.com/oceanprotocol/ (undated) |

## C. New failure-mode distribution (59 eligible campaigns)

- **Outcomes:** 47 surviving, 12 failed, 0 unknown (20% failed). In v1: 44 / 13 / 2.
- **Failed by mechanism:** ICO 5/18, RDA 2/10, BC 2/5, DAICO 1/5, LBP 2/21.
- **Modes among the 12 failed:**
  - slow_death 3: HDAC Low, Sirin Low, Raiden Medium.
  - other 2: SpankChain Low, Fei Medium.
  - regulatory_shutdown 1: TON High.
  - soft_rug 1: Bankera Medium.
  - **unknown 5 (42%; v1 77%):** OmiseGO, BIOPset, ICOVO, APY, Ordibank.
  - exit_scam, governance_failure and liquidity_trap: 0 primary codes.
- **Outside the denominator:** Friend.tech (platform) = soft_rug (Low).

## D. Could not resolve

- **No dated public source on the outcome:** R45 BIOPset, R51 ICOVO, R75 APY Finance (unverified "CortexDAO" lead). Their "Dead" status stays an unsourced row assertion.
- **R14 OmiseGO:** no project-side or official wind-down statement, so the mode stays unknown.
- **R79 Ordibank:** no evidence of operations ceasing beyond price collapse and a stale market. Whether the Fjord sale was an LBP or a fixed-price IDO is unverified.
- **Weak or undated evidence:** R74 ParagonsDAO (undated listing; a reviewer could argue failed/slow_death); R47 BitClout continuation (founder's own statement); R26 Metronome (Defiant page undated, 2026).
- **R49 The Abyss:** whether the platform (as opposed to the token) operates is unverified.
- **Not re-researched in this pass:** R03 HDAC slow_death (Low) and R32 SpankChain other (Low) stand on row text only.

## E. Pages that returned 403/blocked (not used as evidence)

- thenextweb.com (Sirin layoffs)
- blockworks.co (Fei repayment)
- axios.com (Fei wind-down)
- defillama.com (Metronome governance)
- support.bitfinex.com (Abyss delisting 2020-12-15)
- businesswire.com and fintechfutures.com (Ordibank press release saying "raised over $8 million")
- medium.com/@ethdapp (APY.Finance)
- docs.paragonsdao.com (redirected to an empty GitBook page)
