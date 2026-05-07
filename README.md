# ICE Collaboration Network

> 构建一个让任何人都能贡献价值、被公平奖励、并共同治理规则的协作网络  
> A trustless, incentive-aligned, community-governed work platform built on the **Internet Computer (ICP)** using **Motoko**.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Project Structure](#project-structure)
3. [Key Mechanisms](#key-mechanisms)
4. [Type Reference](#type-reference)
5. [Canister API Reference](#canister-api-reference)
6. [Named Constants](#named-constants)
7. [Error Taxonomy](#error-taxonomy)
8. [Default Parameters](#default-parameters)
9. [Inter-Canister Dependencies](#inter-canister-dependencies)
10. [Getting Started](#getting-started)
11. [Workflows](#workflows)
12. [Test Suite](#test-suite)
13. [MVP Roadmap](#mvp-roadmap)
14. [Security Considerations](#security-considerations)
15. [License](#license)

---

## Architecture Overview

The system is built from five independent **canisters** that together implement the three-layer flywheel:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Work Layer          │  Reward Layer          │  Governance Layer    │
│  (value production)  │  (value distribution)  │  (rule governance)   │
│                      │                        │                      │
│  work_registry       │  reward_distributor    │  governance          │
│  (Tasks/Projects/    │  (formula, vesting,    │  (proposals,         │
│   Events/Services/   │   splits, dividends)   │   quadratic vote,    │
│   DataContent)       │                        │   dual-chamber,      │
│                      │  reputation            │   timelock)          │
│                      │  (soulbound scores,    │                      │
│                      │   decay, anti-Sybil)   │  treasury            │
│                      │                        │  (multi-sig → DAO)   │
└──────────────────────────────────────────────────────────────────────┘
```

| Canister | Source | Role |
|---|---|---|
| `work_registry` | `src/work_registry/main.mo` | Full work-unit lifecycle: post, apply, assign, deliver, review, dispute, resolve, expire |
| `reputation` | `src/reputation/main.mo` | Soulbound reputation: award, slash, monthly decay, anti-Sybil age gate, progressive voting rights |
| `reward_distributor` | `src/reward_distributor/main.mo` | Reward formula; 70/20/10 split; linear token vesting; dividend pool |
| `governance` | `src/governance/main.mo` | Proposals; quadratic voting; delegation; dual-chamber; timelock; parameter propagation |
| `treasury` | `src/treasury/main.mo` | Multi-sig withdrawals graduating to governance-gated DAO disbursement |

Shared types are defined in `src/types/Types.mo` and imported by all canisters.

---

## Project Structure

```
ice/
├── dfx.json                     # DFX canister configuration & network settings
├── mops.toml                    # Motoko package manager config (name, deps, test lib)
├── README.md
│
├── src/
│   ├── types/
│   │   └── Types.mo             # Shared types, defaultParams, isqrt, DAY_IN_NS, MONTH_IN_NS
│   ├── work_registry/
│   │   └── main.mo              # Work-layer canister
│   ├── reputation/
│   │   └── main.mo              # Reputation canister
│   ├── reward_distributor/
│   │   └── main.mo              # Reward canister
│   ├── governance/
│   │   └── main.mo              # Governance canister
│   └── treasury/
│       └── main.mo              # Treasury canister
│
└── test/
    ├── WorkRegistryTest.mo      # isqrt, defaultParams, work state-machine, review, vesting
    ├── ReputationTest.mo        # Decay, slash, anti-Sybil rights, threshold, quadratic weight
    ├── RewardDistributorTest.mo # Formula multipliers, timeliness, collaboration, split, vesting
    └── GovernanceTest.mo        # Proposal states, vote aggregation, quorum, timelock, delegation, params
```

---

## Key Mechanisms

### 1. Work Layer (spec §1-A)

**Work Unit types**: `#Task` · `#Project` · `#Event` · `#Service` · `#DataContent`

**Lifecycle state machine**:
```
Open → InProgress → Submitted ──► Completed  (2-of-3 reviewers approve)
                              └──► InDispute → Completed | Cancelled  (admin resolves)
Open | InProgress → Cancelled  (sponsor cancels)
Open | InProgress → Expired    (deadline passes, anyone calls expireWork)
```

- Delivery hash (IPFS / Arweave CID) stored on-chain via `submitDelivery`
- Multi-reviewer acceptance: **2-of-3** threshold by default (configurable via `reviewThreshold`)
- **72-hour dispute window** (`disputePeriodNs`) after `submitDelivery`
- Sponsor or any reviewer may raise a dispute; admin / oracle resolves it
- On completion, `work_registry` automatically calls `reward_distributor.calculateAndDistribute` and `reputation.award`

### 2. Reward Layer (spec §1-B)

**Formula** (§1-B-2) — all multipliers scaled ×100 and applied sequentially:

```
effectiveReward = base × (qualityMult/100) × (difficultyMult/100)
                       × (timelinessMult/100) × (collaborationMult/100)
```

| Multiplier | Value | Derivation |
|---|---|---|
| `qualityMult` | 1 – 100 | Average reviewer score (1–100) |
| `difficultyMult` | 10 – 100 | Sponsor difficulty (1–10) × 10 |
| `timelinessMult` | 80 / 100 / 120 | Late / on-time / ≥1 day early |
| `collaborationMult` | 100 / 110 | < 3 reviewers / ≥ 3 reviewers |

**Reward split** (§1-B-1, §5):

| Asset | Ratio (BPS) | Settlement |
|---|---|---|
| Stablecoin | **7 000 (70 %)** | Immediate payout from `stablecoinReserve` |
| Incentive Token | **2 000 (20 %)** | Linear vesting (cliff 90 d, full 365 d) |
| Reputation Points | **1 000 (10 %)** | Minted via `reputation.award` |

5 % of every stablecoin payout (`DIVIDEND_POOL_RATIO_BPS = 500`) accrues to the quarterly `dividendPool`.

### 3. Reputation (spec §1-B-1, §1-C-2)

- **Soulbound** – bound to `Principal`, non-transferable
- **Award**: authorised canisters call `award(recipient, amount)` after work completion
- **Monthly decay**: default 1 % (`reputationDecayPerMille = 10`) — anyone calls `applyDecay(target)` each month
- **Slashing**: default 20 % (`slashingPenaltyBps = 2 000`) for malicious behaviour
- **Anti-Sybil**: accounts need ≥ 7 days (`minAccountAgeNs`) before `isEligibleForGovernance` returns `true`
- **Progressive rights**: `votingRightBps` returns 0–10 000 bps, scaling linearly over the age gate period

### 4. Governance (spec §1-C)

**Proposal types**:

| Type | Description |
|---|---|
| `#BudgetApproval` | Approve funding for a project |
| `#ParameterChange` | Tune any governance parameter by key + value |
| `#ProtocolUpgrade` | Signal a WASM canister upgrade (admin executes) |
| `#ArbitrationRule` | Update dispute-resolution rule |
| `#TreasuryWithdrawal` | Direct DAO disbursement from treasury |

**Voting model**:
- **Quadratic weight**: `weight = isqrt(reputationScore) × QUADRATIC_WEIGHT_SCALE × votingRightBps / 10 000`
  (`QUADRATIC_WEIGHT_SCALE = 1 000` preserves integer precision)
- Delegation chain (max depth 3) with cycle guard; `undelegate` removes it
- **Dual-chamber**: token holders stake via `stakeTokens` for a separate chamber (protocol upgrades require both chambers)
- Proposal threshold: ≥ 1 % of total reputation (`proposalThresholdBps = 100`)
- Quorum: ≥ 20 % of total quadratic weight (`quorumBps = 2 000`)
- Approval: ≥ 60 % FOR votes (`approvalThresholdBps = 6 000`)
- Voting period: 7 days → 2-day timelock → `executeProposal`
- Parameter changes are propagated to all canisters via `_propagateParams`

### 5. Treasury (spec §4)

- **Phase 1 (MVP)**: N-of-M multi-sig — admins call `proposeWithdrawal` → `approveWithdrawal` → `executeWithdrawal`
- **Phase 2 (DAO)**: governance canister calls `governanceExecute` directly, bypassing multi-sig
- `setGovernance` transitions the treasury to DAO mode

---

## Type Reference

All types live in `src/types/Types.mo` and are imported by every canister.

### Primitive Aliases

| Type | Underlying | Description |
|---|---|---|
| `WorkId` | `Nat` | Unique work-unit identifier |
| `ProposalId` | `Nat` | Unique proposal identifier |
| `VestingId` | `Nat` | Unique vesting-schedule identifier |
| `WithdrawalId` | `Nat` | Unique treasury withdrawal identifier |

### Work Layer

**`WorkType`** — categories of work unit:
```
#Task | #Project | #Event | #Service | #DataContent
```

**`WorkStatus`** — lifecycle states:
```
#Open | #InProgress | #Submitted | #InDispute | #Completed | #Cancelled | #Expired
```

**`ReviewResult`**:
```
{ reviewer: Principal; approved: Bool; score: Nat;  // 1–100
  feedback: Text; timestamp: Int }
```

**`WorkUnit`**:
```
{ id; workType; sponsor; title; description; requirements;
  budget: Nat;         // stablecoin (e8s)
  rewardToken: Nat;    // incentive token (e8s)
  deadline: Int;       // nanosecond timestamp
  difficulty: Nat;     // 1–10, set by sponsor
  status; contributor: ?Principal; reviewers: [Principal];
  reviews: [ReviewResult]; deliveryHash: ?Text;  // IPFS/Arweave CID
  deliveredAt: ?Int; completedAt: ?Int;
  disputeDeadline: ?Int;  // deliveredAt + disputePeriodNs
  createdAt: Int }
```

### Reward Layer

**`RewardBreakdown`**:
```
{ workId; contributor; baseAmount; stablecoinAmount; tokenAmount; reputationAmount;
  qualityMultiplier; difficultyMultiplier; timelinessMultiplier; collaborationMultiplier;
  calculatedAt }
```

**`VestingSchedule`**:
```
{ id; beneficiary; totalAmount; releasedAmount; startTime;
  cliffDuration; vestingDuration; lastReleaseTime }
```

### Governance Layer

**`ProposalType`**:
```
#BudgetApproval    : { projectId: Nat; amount: Nat }
#ParameterChange   : { key: Text; value: Nat }
#ProtocolUpgrade   : { description: Text }
#ArbitrationRule   : { ruleKey: Text; ruleValue: Text }
#TreasuryWithdrawal: { to: Principal; amount: Nat }
```

**`ProposalStatus`**:
```
#Active | #Succeeded | #Defeated | #Executed | #Cancelled | #Expired
```

**`Vote`**:
```
{ voter: Principal; support: Bool; weight: Nat; timestamp: Int }
```

**`Proposal`**:
```
{ id; proposer; title; description; proposalType; status;
  forVotes; againstVotes; startTime; endTime;
  timelockEnd: ?Int; executedAt: ?Int; votes: [Vote]; createdAt }
```

### Treasury

**`WithdrawalStatus`**:
```
#Pending | #Approved | #Executed | #Rejected
```

**`WithdrawalRequest`**:
```
{ id; to; amount; reason; status; approvals: [Principal]; createdAt; executedAt: ?Int }
```

### System Parameters

`SystemParameters` — all governance-tunable knobs (see [Default Parameters](#default-parameters)):
```
{ reviewerCount; reviewThreshold; disputePeriodNs;
  stablecoinRatioBps; tokenRatioBps; reputationRatioBps;
  reputationDecayPerMille; proposalThresholdBps; quorumBps;
  approvalThresholdBps; votingPeriodNs; timelockDelayNs;
  delegationCapBps; cliffDurationNs; vestingDurationNs;
  slashingPenaltyBps; minAccountAgeNs }
```

---

## Canister API Reference

### `work_registry` (`src/work_registry/main.mo`)

#### Admin / Configuration

| Function | Description |
|---|---|
| `setAdmin(p)` | Set the admin principal (first call is open, then admin-only) |
| `setReputationCanister(p)` | Wire the Reputation canister |
| `setRewardCanister(p)` | Wire the RewardDistributor canister |
| `updateParams(params)` | Update `SystemParameters` (admin only) |

#### Sponsor API

| Function | Returns | Description |
|---|---|---|
| `createWork(workType, title, description, requirements, budget, rewardToken, deadline, difficulty, reviewers)` | `Result<WorkId>` | Post a new work unit; caller becomes sponsor |
| `cancelWork(workId)` | `Result<()>` | Cancel an Open or InProgress work unit |
| `assignContributor(workId, contributor)` | `Result<()>` | Assign a contributor from the applicant list |

#### Contributor API

| Function | Returns | Description |
|---|---|---|
| `applyForWork(workId)` | `Result<()>` | Express interest in an Open work unit (idempotent) |
| `submitDelivery(workId, deliveryHash)` | `Result<()>` | Submit IPFS/Arweave CID; sets dispute window |

#### Reviewer API

| Function | Returns | Description |
|---|---|---|
| `reviewWork(workId, approved, score, feedback)` | `Result<()>` | Submit assessment; triggers completion when threshold met |

#### Dispute API

| Function | Returns | Description |
|---|---|---|
| `disputeWork(workId)` | `Result<()>` | Raise dispute within 72 h window (sponsor or reviewer) |
| `resolveDispute(workId, approveDelivery)` | `Result<()>` | Admin finalises dispute outcome |

#### Public / Scheduler

| Function | Returns | Description |
|---|---|---|
| `expireWork(workId)` | `Result<()>` | Mark Open/InProgress work as Expired after deadline passes |

#### Queries

| Function | Returns |
|---|---|
| `getWork(workId)` | `?WorkUnit` |
| `listWorks(status?)` | `[WorkUnit]` |
| `getApplicants(workId)` | `[Principal]` |
| `workCount()` | `Nat` |
| `getParams()` | `SystemParameters` |

---

### `reputation` (`src/reputation/main.mo`)

#### Admin

| Function | Description |
|---|---|
| `setAdmin(newAdmin)` | Set admin principal |
| `setAuthorised(canister, allowed)` | Grant/revoke minting and slashing rights |
| `updateParams(params)` | Update `SystemParameters` |

#### Core

| Function | Returns | Description |
|---|---|---|
| `award(recipient, amount)` | `Result<()>` | Mint reputation; only authorised canisters |
| `slash(offender, reason)` | `Result<Nat>` | Apply `slashingPenaltyBps` penalty; returns amount slashed |
| `applyDecay(target)` | `Result<Nat>` | Apply monthly 1 % decay; returns amount decayed; no-op if < 30 days since last decay |

#### Queries

| Function | Returns |
|---|---|
| `getScore(p)` | `Nat` — current reputation score |
| `getRecord(p)` | `?ReputationRecord` — full record including `totalEarned`, `createdAt`, `lastDecayAt` |
| `getTotalScore()` | `Nat` — total reputation in the system (used for governance thresholds) |
| `isEligibleForGovernance(p)` | `Bool` — `true` when account age ≥ `minAccountAgeNs` |
| `votingRightBps(p)` | `Nat` — 0–10 000 bps, linear ramp over age gate period |
| `getParams()` | `SystemParameters` |

---

### `reward_distributor` (`src/reward_distributor/main.mo`)

#### Admin

| Function | Description |
|---|---|
| `setAdmin(p)` | Set admin principal |
| `setReputationCanister(p)` | Wire the Reputation canister |
| `setWorkRegistry(p)` | Wire the WorkRegistry canister (authorises `calculateAndDistribute`) |
| `updateParams(params)` | Update `SystemParameters` |
| `depositStablecoin(amount)` | Fund the stablecoin reserve |

#### Core

| Function | Returns | Description |
|---|---|---|
| `calculateReward(work)` | `Result<RewardBreakdown>` | **Query** — calculate breakdown without distributing |
| `calculateAndDistribute(work)` | `Result<RewardBreakdown>` | Called by WorkRegistry on completion; idempotent |
| `claimVested(vestingId)` | `Result<Nat>` | Beneficiary claims linearly vested tokens |

#### Queries

| Function | Returns |
|---|---|
| `getVestingSchedule(id)` | `?VestingSchedule` |
| `getRewardBreakdown(workId)` | `?RewardBreakdown` |
| `getReleasable(vestingId)` | `Nat` — tokens claimable right now |
| `getReserves()` | `{ stablecoin: Nat; token: Nat; dividendPool: Nat }` |
| `getParams()` | `SystemParameters` |

---

### `governance` (`src/governance/main.mo`)

#### Admin

| Function | Description |
|---|---|
| `setAdmin(p)` | Set admin principal |
| `setReputationCanister(p)` | Wire the Reputation canister |
| `setTreasuryCanister(p)` | Wire the Treasury canister |
| `setWorkRegistry(p)` | Wire the WorkRegistry (for param propagation) |
| `setRewardCanister(p)` | Wire the RewardDistributor (for param propagation) |
| `updateParams(params)` | Update `SystemParameters` directly (admin only) |

#### Token Chamber Staking

| Function | Returns | Description |
|---|---|---|
| `stakeTokens(amount)` | `Result<()>` | Lock tokens for token-chamber participation |
| `unstakeTokens(amount)` | `Result<()>` | Unlock staked tokens |

#### Delegation

| Function | Returns | Description |
|---|---|---|
| `delegate(to)` | `Result<()>` | Delegate voting power (depth-3 chain, cycle guard) |
| `undelegate()` | `Result<()>` | Remove current delegation |

#### Proposals

| Function | Returns | Description |
|---|---|---|
| `createProposal(title, description, proposalType)` | `Result<ProposalId>` | Submit a proposal (requires ≥ 1 % rep, account age gate) |
| `vote(proposalId, support)` | `Result<()>` | Cast quadratic vote; delegation resolved automatically |
| `cancelProposal(proposalId)` | `Result<()>` | Proposer or admin cancels an active proposal |
| `finaliseProposal(proposalId)` | `Result<ProposalStatus>` | Evaluate quorum & approval after voting period ends |
| `executeProposal(proposalId)` | `Result<()>` | Execute after timelock; propagates param changes, triggers treasury |

#### Queries

| Function | Returns |
|---|---|
| `getProposal(id)` | `?Proposal` |
| `listProposals(status?)` | `[Proposal]` |
| `getDelegation(from)` | `?Principal` |
| `getTokenStake(p)` | `Nat` |
| `getParams()` | `SystemParameters` |

---

### `treasury` (`src/treasury/main.mo`)

#### Admin Bootstrap

| Function | Description |
|---|---|
| `addAdmin(p)` | Add a multi-sig admin (first call open to anyone) |
| `removeAdmin(p)` | Remove an admin (cannot drop below threshold) |
| `setMultisigThreshold(n)` | Set approval threshold (1 ≤ n ≤ admin count) |
| `setGovernance(p)` | Set the governance canister principal (enables Phase 2) |
| `deposit(amount)` | Register incoming funds (production: after ledger transfer) |

#### Multi-sig Withdrawal Workflow

| Function | Returns | Description |
|---|---|---|
| `proposeWithdrawal(to, amount, reason)` | `Result<WithdrawalId>` | Create withdrawal; proposer auto-approves |
| `approveWithdrawal(withdrawalId)` | `Result<()>` | Each admin approves once; auto-marks Approved at threshold |
| `executeWithdrawal(withdrawalId)` | `Result<()>` | Execute an Approved withdrawal |

#### Governance-gated (Phase 2)

| Function | Returns | Description |
|---|---|---|
| `governanceExecute(to, amount, reason)` | `Result<()>` | Direct disbursement; only governance canister |

#### Queries

| Function | Returns |
|---|---|
| `getBalance()` | `Nat` |
| `getWithdrawal(id)` | `?WithdrawalRequest` |
| `listWithdrawals(status?)` | `[WithdrawalRequest]` |
| `getAdmins()` | `[Principal]` |
| `getThreshold()` | `Nat` |

---

## Named Constants

Defined in `src/types/Types.mo` and `src/governance/main.mo`:

| Constant | Value | Location | Used For |
|---|---|---|---|
| `DAY_IN_NS` | `86_400_000_000_000` | `Types.mo` | Timeliness multiplier boundary |
| `MONTH_IN_NS` | `2_592_000_000_000_000` | `Types.mo` | Monthly decay gate |
| `QUADRATIC_WEIGHT_SCALE` | `1_000` | `governance/main.mo` | Integer precision in quadratic weight |
| `DIVIDEND_POOL_RATIO_BPS` | `500` | `reward_distributor/main.mo` | 5 % quarterly dividend pool contribution |

---

## Error Taxonomy

All canisters return `Result.Result<T, T.Error>` where `T.Error` is:

| Variant | Typical Cause |
|---|---|
| `#NotFound(text)` | Work unit, proposal, vesting ID, or withdrawal not found |
| `#Unauthorized(text)` | Caller lacks permission (not admin / reviewer / authorised canister) |
| `#InvalidState(text)` | Action not valid in the current lifecycle state |
| `#InvalidInput(text)` | Bad parameter value (empty title, score out of range, etc.) |
| `#InsufficientFunds(text)` | Not enough stablecoin or token reserve |
| `#InsufficientReputation(text)` | Below proposal threshold or zero voting weight |
| `#AlreadyExists(text)` | Duplicate application, vote, or review |
| `#DisputePeriodActive(text)` | Action blocked during open dispute window |
| `#DeadlineExceeded(text)` | Submission or dispute window already closed |
| `#TimelockActive(text)` | Timelock has not yet elapsed for proposal execution |
| `#QuorumNotMet(text)` | Quorum not reached at finalisation |

---

## Default Parameters

All values from spec §5; stored in `T.defaultParams` and propagated to every canister after a successful `#ParameterChange` governance vote.

| Parameter (key string) | Default Value | Meaning |
|---|---|---|
| `reviewerCount` | 3 | Required reviewer count per work unit |
| `reviewThreshold` | 2 | Approvals needed to complete (2-of-3) |
| `disputePeriodNs` | 259 200 000 000 000 | 72 hours dispute window |
| `stablecoinRatioBps` | 7 000 | 70 % of reward as stablecoin |
| `tokenRatioBps` | 2 000 | 20 % of reward as vested token |
| `reputationRatioBps` | 1 000 | 10 % of reward as reputation points |
| `reputationDecayPerMille` | 10 | 1 % monthly reputation decay |
| `proposalThresholdBps` | 100 | Proposer needs ≥ 1 % of total reputation |
| `quorumBps` | 2 000 | ≥ 20 % of total quadratic weight must vote |
| `approvalThresholdBps` | 6 000 | ≥ 60 % of cast votes must be FOR |
| `votingPeriodNs` | 604 800 000 000 000 | 7-day voting window |
| `timelockDelayNs` | 172 800 000 000 000 | 2-day timelock before execution |
| `delegationCapBps` | 500 | Max delegated weight 5 % of total |
| `cliffDurationNs` | 7 776 000 000 000 000 | 90-day token vesting cliff |
| `vestingDurationNs` | 31 536 000 000 000 000 | 365-day full token vest |
| `slashingPenaltyBps` | 2 000 | 20 % reputation slash penalty |
| `minAccountAgeNs` | 604 800 000 000 000 | 7-day anti-Sybil account age gate |

All parameters are **on-chain governance-tunable** via `#ParameterChange { key = "...", value = N }` proposals.

---

## Inter-Canister Dependencies

```
dfx.json dependency graph:

  work_registry ──depends on──► reputation
                └─depends on──► reward_distributor

  reward_distributor ─depends on──► reputation

  governance ─depends on──► reputation
             └─depends on──► treasury

  treasury      (no canister dependencies)
  reputation    (no canister dependencies)
```

After deployment, the canisters must be **wired together** (see [Getting Started](#getting-started)).

---

## Getting Started

### Prerequisites

- [DFX SDK](https://internetcomputer.org/docs/current/developer-docs/setup/install/) ≥ 0.20.0
- [mops](https://mops.one/docs/install) — Motoko package manager

### Install

```bash
# Install dfx
sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)"

# Install mops
npm i -g ic-mops

# Install Motoko dependencies
mops install

# Install test library (dev dependency)
mops add test --dev
```

### Local Development

```bash
# Start a local ICP replica
dfx start --background

# Deploy all canisters
dfx deploy

# Capture canister IDs
REPUTATION=$(dfx canister id reputation)
WORK=$(dfx canister id work_registry)
REWARD=$(dfx canister id reward_distributor)
GOVERNANCE=$(dfx canister id governance)
TREASURY=$(dfx canister id treasury)
ADMIN=$(dfx identity get-principal)

# ── Set admins ──────────────────────────────────────────────────────────
dfx canister call work_registry      setAdmin "(principal \"$ADMIN\")"
dfx canister call reputation         setAdmin "(principal \"$ADMIN\")"
dfx canister call reward_distributor setAdmin "(principal \"$ADMIN\")"
dfx canister call governance         setAdmin "(principal \"$ADMIN\")"
dfx canister call treasury           addAdmin "(principal \"$ADMIN\")"

# ── Wire canisters ──────────────────────────────────────────────────────
# work_registry
dfx canister call work_registry setReputationCanister  "(principal \"$REPUTATION\")"
dfx canister call work_registry setRewardCanister      "(principal \"$REWARD\")"

# reward_distributor
dfx canister call reward_distributor setReputationCanister "(principal \"$REPUTATION\")"
dfx canister call reward_distributor setWorkRegistry       "(principal \"$WORK\")"

# governance
dfx canister call governance setReputationCanister "(principal \"$REPUTATION\")"
dfx canister call governance setTreasuryCanister   "(principal \"$TREASURY\")"
dfx canister call governance setWorkRegistry       "(principal \"$WORK\")"
dfx canister call governance setRewardCanister     "(principal \"$REWARD\")"

# treasury
dfx canister call treasury setGovernance "(principal \"$GOVERNANCE\")"

# ── Authorise minting rights in Reputation ──────────────────────────────
dfx canister call reputation setAuthorised "(principal \"$WORK\",   true)"
dfx canister call reputation setAuthorised "(principal \"$REWARD\", true)"
dfx canister call reputation setAuthorised "(principal \"$GOVERNANCE\", true)"
```

### Running Tests

```bash
mops test
```

All four test files in `test/` contain pure-function unit tests and run without a live replica.

### Mainnet Deployment

```bash
dfx deploy --network ic
```

---

## Workflows

### Contributor: completing a task

```bash
# 1. Sponsor posts work
dfx canister call work_registry createWork \
  '(variant { Task }, "Write docs", "Full API docs", "Markdown + examples", 1000000, 200000, <deadline_ns>, 5, vec {})'

# 2. Contributor applies
dfx canister call work_registry applyForWork '(0)'

# 3. Sponsor assigns
dfx canister call work_registry assignContributor '(0, principal "<contributor>")'

# 4. Contributor submits IPFS CID
dfx canister call work_registry submitDelivery '(0, "QmXyz...")'

# 5. Reviewers assess (repeat for each reviewer)
dfx canister call work_registry reviewWork '(0, true, 85, "Good work")'

# 6. On 2nd approval → Completed → reward auto-distributed
# 7. Contributor claims vested tokens later
dfx canister call reward_distributor claimVested '(0)'
```

### Governance: changing a parameter

```bash
# 1. Create proposal
dfx canister call governance createProposal \
  '("Increase quorum", "Raise to 25%", variant { ParameterChange = record { key = "quorumBps"; value = 2500 } })'

# 2. Community votes (7-day window)
dfx canister call governance vote '(0, true)'

# 3. After voting period: finalise
dfx canister call governance finaliseProposal '(0)'

# 4. After 2-day timelock: execute (propagates to all canisters)
dfx canister call governance executeProposal '(0)'
```

### Treasury: multi-sig withdrawal

```bash
# Admin A proposes
dfx canister call treasury proposeWithdrawal \
  '(principal "<recipient>", 500000, "Grant payment")'

# Admin B approves (auto-executes if threshold met)
dfx canister call treasury approveWithdrawal '(0)'

# Execute once Approved
dfx canister call treasury executeWithdrawal '(0)'
```

---

## Test Suite

Tests live in `test/` and run with `mops test`. No running replica required.

### `WorkRegistryTest.mo`

| Suite | Covers |
|---|---|
| `Types.isqrt` | Integer square-root correctness for 0, 1, 4, 9, 10, 100, 1 000 000 |
| `Types.defaultParams` | All 13 spec §5 parameters plus split-sum invariant |
| `WorkUnit status transitions` | Open/InProgress/Submitted states, difficulty range, dispute-deadline calculation |
| `ReviewResult aggregation` | Approval count, 2-of-3 threshold, quality average |
| `RewardBreakdown ratio invariants` | 70/20/10 split correctness, zero-budget edge case |
| `Quadratic voting weight` | isqrt sublinearity (fairness proof) |
| `VestingSchedule cliff logic` | Nothing before cliff, partial at cliff, 100 % at full duration, no over-vesting |

### `ReputationTest.mo`

| Suite | Covers |
|---|---|
| `Reputation decay formula` | 1 % decay, zero score, compound decay over 12 months |
| `Reputation slashing` | 20 % slash, zero score, 100 % penalty edge case |
| `Progressive voting rights (anti-Sybil)` | New account (0 bps), halfway, full age, over-age |
| `Governance proposal threshold` | 1 % meets, 0.5 % fails, zero total fails |
| `Governance quorum and approval` | Combined pass/fail matrix |
| `Quadratic voting weight` | Zero weight, full rights, partial rights, 4× score → 2× weight |

### `RewardDistributorTest.mo`

| Suite | Covers |
|---|---|
| `effectiveReward multipliers` | All-100 identity, quality/difficulty/timeliness/collaboration, compounding |
| `Timeliness multiplier` | 2 days early, 1 day early, 1 s before, on deadline, 1 s late, null |
| `Collaboration multiplier` | 0/1/2/3 reviewers → 100 or 110 |
| `Reward split invariants` | Exact 70/20/10, sum check, zero |
| `Vesting schedule releasable` | Cliff gate, partial, 100 %, cap beyond duration |

### `GovernanceTest.mo`

| Suite | Covers |
|---|---|
| `Proposal status transitions` | #Active, #Cancelled, #Succeeded (needs timelock) |
| `Vote weight aggregation` | Single FOR, mixed FOR/AGAINST, zero-weight vote, duplicate check |
| `Quorum and approval check` | 20 %/60 % pass, 19 % quorum fails, 59 % approval fails, empty fails |
| `Timelock enforcement` | Cannot execute before, exactly at, after timelock |
| `Delegation logic` | Depth-1, depth-2 chain, self-loop cycle guard, no-delegation resolves to self |
| `Parameter change dispatch` | All supported keys, unknown key leaves params unchanged |

---

## MVP Roadmap (90-day plan, spec §4)

| Phase | Deliverables | Status |
|---|---|---|
| **Stage 1 – Collaboration & Settlement** | Task posting, application, assignment, delivery, review, stablecoin settlement | ✅ Implemented |
| **Stage 2 – Reputation & Incentives** | Soulbound reputation; monthly decay; token vesting with cliff; dividend pool | ✅ Implemented |
| **Stage 3 – Community Governance** | Proposal system; quadratic voting; dual-chamber; delegation; timelock; treasury DAO | ✅ Implemented |

---

## Security Considerations

| Concern | Mitigation |
|---|---|
| Sybil attacks | Account age gate (`minAccountAgeNs = 7 days`); progressive voting rights |
| Whale dominance | Quadratic voting (`isqrt(score)`); delegation cap (`delegationCapBps = 500`) |
| Governance capture | 2-day timelock; vote cooldown; dual-chamber for protocol upgrades |
| Malicious contributors | 72-hour dispute window; reputation slashing (`slashingPenaltyBps = 2 000`) |
| Reward gaming | Quality score weighting; 1 % monthly decay punishes inactivity |
| Canister upgrade safety | All mutable state in `stable var`; `preupgrade`/`postupgrade` hooks in all five canisters |
| Idempotent distribution | `calculateAndDistribute` checks `distributedMap` before any state change |
| Unauthorised minting | `reputation.award` and `slash` check an `authorised` allowlist |
| Treasury fund safety | Multi-sig threshold enforced; `governanceExecute` restricted to governance canister |

---

## License

MIT
