# Failure Coding Codebook (Proposed)

**Status:** protocol proposal; no dataset rows have been coded with these rules.
**Scope:** observable outcomes in on-chain capital formation projects and
fundraising campaigns represented in `dataset_82_projects.md`.

This codebook turns the six failure modes named in Proposal v3 into proposed,
repeatable decision rules. It does not establish that a particular project
failed, that a failure was caused by its fundraising mechanism, or that the
accountability-gap hypothesis is supported. Those are empirical conclusions
that require evidence and analysis after record normalization.

## 1. Unit of analysis and eligibility

The current inventory mixes records that answer different questions. Keep the
source rows, but add stable identifiers and a `record_type` before counting or
coding outcomes.

| `record_type` | Definition | Failure coding |
|---|---|---|
| `project` | A continuing organization, protocol, or product | Code only when the failure is attributable to this entity and its outcome is observable |
| `campaign` | A distinct token sale, auction, or other capital-raising event | Eligible for campaign-level outcomes; link it to its project where one exists |
| `platform` | Infrastructure that hosts or enables campaigns | Code the platform's own outcome separately; do not treat its hosted campaigns as platform failures |
| `governance_event` | A vote, proposal execution, or other event within a project | Context/evidence for a project or campaign code, not an independent failed project |
| `proposal` | A design or announced plan without an implemented campaign | Exclude from project-failure denominators; retain for adoption/implementation analysis |
| `aggregate` | A grouped set of unnamed or unresolved attempts | Do not code as one project; split into identifiable entities or exclude from entity-level rates |
| `other/uncertain` | A record that cannot yet be assigned to the types above | Resolve during normalization; exclude from entity-level denominators until reviewed |

One entity may have multiple campaigns, and a campaign may use more than one
mechanism. Record the `entity_id`, `campaign_id` (when applicable), source row
IDs, and all applicable mechanism labels. Do not count a duplicate category row
as a second independent entity. A hybrid campaign can carry multiple mechanism
labels without being duplicated in the campaign denominator.

## 2. Proposed coding fields

Keep current status, campaign outcome, failure mode, and causal interpretation
as separate fields. At minimum, record:

| Field | Suggested values or contents |
|---|---|
| `record_id`, `entity_id`, `campaign_id` | Stable identifiers; campaign ID may be blank for a project-only record |
| `record_type` | One of the types above, including `other/uncertain` when unresolved |
| `mechanism` | One or more of ICO, RDA, bonding curve, DAICO/rICO, LBP, other, or unknown |
| `campaign_outcome` | Completed, cancelled, failed-to-launch, refunded, unresolved, or not-applicable |
| `project_status_at_cutoff` | Active, inactive, shut-down, acquired/rebranded, or unknown; record the cutoff date |
| `failure_mode_primary`, `failure_mode_secondary` | A mode below, `mixed`, `none-observed`, or `unknown`; allow multiple supported secondary labels |
| `failure_start_date`, `failure_end_date` | Best-supported dates or ranges; use unknown when not established |
| `evidence_summary`, `source_url`, `source_date` | Concise factual claim, direct source, and publication/event date |
| `evidence_type` | On-chain record, court/regulator, project statement, independent reporting, or secondary database |
| `confidence` | High, medium, low, or unresolved, with a short reason |
| `coder`, `reviewer`, `decision_note` | Audit trail for the initial code, review, and adjudication |

Use `unknown` when evidence is missing or conflicting. Use `none-observed` only
when the record was reviewed and no qualifying failure was found within the
stated observation window. Do not convert a dead token, price decline, inactive
website, or weak raise into a failure-mode label by itself.

## 3. Proposed operational definitions

These are initial coding rules for a pilot. They should be reviewed against
real cases before the full dataset is coded.

| Failure mode | Code when the evidence supports… | Do not code from this alone… |
|---|---|---|
| **Exit scam** | An abrupt, intentional diversion or extraction of project/campaign funds by insiders, accompanied by credible evidence of deceptive intent or deliberate abandonment to prevent recovery. Record allegations separately from findings. | A project shutdown, insolvency, treasury spend, or token collapse without evidence of intentional deception or diversion. |
| **Soft rug** | A team or controlling insiders materially withdraw support, liquidity, promised delivery, or treasury resources in a way that harms participants, with evidence of conduct or sustained non-performance but insufficient evidence to meet the stronger intent threshold for exit scam. | A delayed roadmap, pivot, ordinary team departure, or price decline without material conduct and participant impact. |
| **Governance failure** | A governance process materially fails to make or implement a decision needed to protect the project or participants, or is persistently captured/deadlocked so that a documented risk cannot be addressed. Record the specific decision, process, and impact. | Token-weighted voting, low turnout, disagreement, or a controversial decision without evidence of consequential process failure. |
| **Liquidity trap** | Participants are materially unable to exit or redeem because of a market, contract, or design constraint, or exit causes a documented loss materially beyond ordinary market-price risk. Identify whether the constraint is contractual, market-depth, or operational. | A falling token price, ordinary slippage, or a one-way purchase design unless the constraint and resulting harm are documented. |
| **Slow death** | A sustained decline in core operations, product use, development, or community activity over a stated observation period, ending in abandonment or functional failure without a single dominant acute event. Require at least two dated observations that establish a trajectory; state the chosen observation window. | A temporary quiet period, market downturn, or a single stale website snapshot. |
| **Regulatory shutdown** | A regulator, court, or legally required compliance action materially halts, unwinds, or prevents a fundraising campaign or project operation. Record jurisdiction, action, and whether the action was final, alleged, or settled. | General regulatory uncertainty, a routine inquiry, voluntary pivot, or a legal issue that did not materially affect operations. |

More than one mode may be present. Assign a primary mode only when evidence
supports a dominant proximate failure; otherwise use `mixed` or `unknown` and
explain the ambiguity. Do not use the mode itself as proof that the fundraising
mechanism caused the outcome. Code observable intermediary involvement,
jurisdiction, and accountability features separately for RQ3/RQ4 and causal
analysis.

## 4. Evidence and review workflow

1. Resolve each inventory row to an entity, campaign, or non-eligible record;
   preserve its original row ID and source link.
2. For each eligible project/campaign, define the observation cutoff and
   capture dated, attributable evidence. Prefer primary on-chain records,
   court/regulator materials, and contemporaneous project statements; use
   independent reporting to corroborate context.
3. Code the observed outcome and evidence before assigning a failure mode.
   Keep factual description distinct from the coder's interpretation.
4. Have a second reviewer check every proposed failure label and a sample of
   `none-observed` records. Resolve disagreements in a decision log and retain
   the original codes for auditability.
5. Report the eligible denominator, exclusions by record type, unknown share,
   confidence mix, and number of multi-label cases with every prevalence table.
   Do not imply that a low-confidence or unresolved label is a confirmed case.

The pilot should test these definitions on a small, diverse set that includes
an alleged exit scam, an inactive project, a governance event, a low-liquidity
token, and a regulatory case. Revise ambiguous rules before coding the full
inventory. The DAICO category is especially sparse: the inventory identifies
only four completed raises (including variants), so report raw counts and
uncertainty rather than treating them as stable population rates.

## 5. Interpretation boundary

This codebook supports consistent description; it does not solve selection
bias, missing-data bias, survivorship bias, or causal attribution. An
association between mechanism and outcome needs a defined sample, comparable
observation windows, and a treatment of confounders. Report the empirical
failure distribution separately from the design team's counterfactual claims
about how LAF might have changed an outcome.
