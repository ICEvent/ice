# ICE Collaboration Network

> 构建一个让任何人都能贡献价值、被公平奖励、并共同治理规则的协作网络  
> A trustless, incentive-aligned, community-governed work platform built on the **Internet Computer (ICP)** using **Motoko**.

---

## Architecture Overview

The system is built from five independent **canisters** that together implement the three-layer flywheel described in the spec:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Work Layer          │  Reward Layer          │  Governance Layer    │
│  (value production)  │  (value distribution)  │  (rule governance)   │
│                      │                        │                      │
│  work_registry       │  reward_distributor    │  governance          │
│  (Tasks/Projects/    │  (formula, vesting,    │  (proposals,         │
│   Events/Services/   │   splits)              │   quadratic vote,    │
│   DataContent)       │                        │   timelock)          │
│                      │  reputation            │                      │
│                      │  (soulbound scores)    │  treasury            │
│                      │                        │  (multi-sig → DAO)   │
└──────────────────────────────────────────────────────────────────────┘
```

### Canister Responsibilities

| Canister | Source | Role |
|---|---|---|
| `work_registry` | `src/work_registry/main.mo` | Post/accept/deliver/review work units; manages the full lifecycle |
| `reputation` | `src/reputation/main.mo` | Soulbound reputation scores; monthly decay; anti-Sybil age gate |
| `reward_distributor` | `src/reward_distributor/main.mo` | Multi-factor reward formula; 70/20/10 split; linear token vesting |
| `governance` | `src/governance/main.mo` | Proposals; quadratic voting; dual-chamber; timelock execution |
| `treasury` | `src/treasury/main.mo` | Multi-sig fund management transitioning to full DAO control |

Shared types are defined in `src/types/Types.mo` and imported by all canisters.

---

## Key Mechanisms

### 1. Work Layer (spec §1-A)

**Work Unit types**: `#Task`, `#Project`, `#Event`, `#Service`, `#DataContent`

**Lifecycle**:
```
createWork → applyForWork → assignContributor → submitDelivery
           → reviewWork (N-of-M) → [disputeWork → resolveDispute] → completeWork
```

- Delivery hash (IPFS / Arweave CID) is stored on-chain
- Multi-reviewer acceptance: **2-of-3** by default (configurable)
- **72-hour dispute window** after submission
- Sponsor can raise a dispute; admin / oracle resolves it

### 2. Reward Layer (spec §1-B)

**Formula** (§1-B-2):

```
effectiveReward = base × qualityCoeff × difficultyCoeff × timelinessCoeff × collaborationCoeff
```

| Coefficient | Range | Source |
|---|---|---|
| quality | 1–100 (average reviewer score) | Reviewer assessment |
| difficulty | 10–100 (difficulty × 10) | Sponsor-set 1-10 scale |
| timeliness | 80 / 100 / 120 | Delivery timing vs deadline |
| collaboration | 100 / 110 | ≥3 reviewers → 1.1× |

**Split** (§1-B-1, §5):

| Asset | Ratio | Settlement |
|---|---|---|
| Stablecoin | **70 %** | Immediate payout |
| Incentive Token | **20 %** | Linear vesting (cliff 90 d, full 365 d) |
| Reputation Points | **10 %** | Minted as soulbound score |

### 3. Reputation (spec §1-B-1, §1-C-2)

- **Soulbound** – non-transferable, bound to `Principal`
- **Monthly decay**: 1 % by default (`reputationDecayPerMille = 10`)
- **Slashing**: 20 % penalty for malicious behaviour
- **Anti-Sybil**: accounts gain full governance rights only after 7 days (`minAccountAgeNs`)
- **Progressive rights**: `votingRightBps` scales linearly from 0 to 10 000 over the minimum age period

### 4. Governance (spec §1-C)

**Proposal threshold**: ≥ 1 % of total reputation (`proposalThresholdBps = 100`)

**Voting**:
- **Quadratic weight**: `weight = isqrt(reputationScore) × votingRightBps / 10 000`
- Quorum: ≥ 20 % of total quadratic weight (`quorumBps = 2 000`)
- Approval: ≥ 60 % of cast votes (`approvalThresholdBps = 6 000`)

**Dual-chamber** (protocol upgrades require both):
- Reputation chamber – weighted by `isqrt(reputation)`
- Token chamber – weighted by staked incentive tokens

**Safety mechanisms**:
- 7-day voting period → 2-day timelock before execution
- Delegation chain (max depth 3) with cycle detection
- Governance propagates parameter changes to all canisters

### 5. Treasury (spec §4)

- Phase 1 (MVP): **N-of-M multi-sig** (configurable threshold, default 2-of-N)
- Phase 2: governance canister becomes sole authority via `governanceExecute`

---

## Default Parameters (spec §5)

| Parameter | Value |
|---|---|
| Reviewer count | 3 |
| Review threshold | 2-of-3 |
| Dispute period | 72 hours |
| Reward split | 70 % stablecoin / 20 % token / 10 % reputation |
| Reputation decay | 1 % per month |
| Token cliff | 90 days |
| Token vesting | 365 days |
| Proposal threshold | ≥ 1 % of total reputation |
| Quorum | ≥ 20 % participation |
| Approval | ≥ 60 % FOR votes |
| Voting period | 7 days |
| Timelock | 2 days |
| Delegation cap | 5 % of total weight |
| Min account age | 7 days |
| Slashing penalty | 20 % of reputation |

All parameters are **on-chain governance-tunable** via `#ParameterChange` proposals.

---

## Project Structure

```
ice/
├── dfx.json                    # DFX project configuration
├── mops.toml                   # Motoko package manager (mops) config
├── README.md
│
├── src/
│   ├── types/
│   │   └── Types.mo            # Shared types, defaultParams, isqrt helper
│   ├── work_registry/
│   │   └── main.mo             # Work unit lifecycle canister
│   ├── reputation/
│   │   └── main.mo             # Soulbound reputation canister
│   ├── reward_distributor/
│   │   └── main.mo             # Reward calculation + distribution canister
│   ├── governance/
│   │   └── main.mo             # Governance + voting + timelock canister
│   └── treasury/
│       └── main.mo             # Community treasury canister
│
└── test/
    ├── WorkRegistryTest.mo     # Tests: work lifecycle, review, dispute logic
    ├── ReputationTest.mo       # Tests: decay, slash, anti-Sybil, governance thresholds
    ├── RewardDistributorTest.mo # Tests: reward formula, split, vesting schedule
    └── GovernanceTest.mo       # Tests: proposals, voting, quorum, timelock, delegation
```

---

## Getting Started

### Prerequisites

- [DFX SDK](https://internetcomputer.org/docs/current/developer-docs/setup/install/) ≥ 0.20.0  
- [mops](https://mops.one/docs/install) (Motoko package manager)

### Install

```bash
# Install dfx
sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)"

# Install mops
npm i -g ic-mops

# Install Motoko dependencies
mops install
mops add test --dev   # test library for mops test
```

### Local Development

```bash
# Start a local ICP replica
dfx start --background

# Deploy all canisters
dfx deploy

# Wire canisters together (replace IDs with actual deployed IDs)
REPUTATION=$(dfx canister id reputation)
WORK=$(dfx canister id work_registry)
REWARD=$(dfx canister id reward_distributor)
GOVERNANCE=$(dfx canister id governance)
TREASURY=$(dfx canister id treasury)

dfx canister call work_registry setReputationCanister  "(principal \"$REPUTATION\")"
dfx canister call work_registry setRewardCanister      "(principal \"$REWARD\")"
dfx canister call reward_distributor setReputationCanister "(principal \"$REPUTATION\")"
dfx canister call reward_distributor setWorkRegistry   "(principal \"$WORK\")"
dfx canister call governance setReputationCanister     "(principal \"$REPUTATION\")"
dfx canister call governance setTreasuryCanister       "(principal \"$TREASURY\")"
dfx canister call treasury   setGovernance             "(principal \"$GOVERNANCE\")"
```

### Running Tests

```bash
mops test
```

Tests cover all pure-function logic across all four test files in `test/`.

### Mainnet Deployment

```bash
dfx deploy --network ic
```

---

## MVP Roadmap (90-day plan, spec §4)

| Phase | Deliverables | Status |
|---|---|---|
| **Stage 1 – Collaboration & Settlement** | Task publishing, contribution, delivery, review, stablecoin settlement | ✅ Implemented |
| **Stage 2 – Reputation & Incentives** | Soulbound reputation; quarterly token distribution with vesting | ✅ Implemented |
| **Stage 3 – Community Governance** | Proposal system, quadratic voting, timelock, treasury DAO | ✅ Implemented |

---

## Security Considerations

| Concern | Mitigation |
|---|---|
| Sybil attacks | Account age gate (`minAccountAgeNs`); progressive voting rights |
| Whale dominance | Quadratic voting (`isqrt(score)`); delegation cap (5 %) |
| Governance capture | Timelock (2 days); voting cooldown; dual-chamber for upgrades |
| Malicious contributors | 72-hour dispute period; reputation slashing |
| Upgrade safety | All state in `stable var`; `preupgrade`/`postupgrade` hooks |
| Low-quality gaming | Anti-pattern detection via quality score weighting |

---

## License

MIT
