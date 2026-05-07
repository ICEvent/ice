/// Tests for Reputation canister logic.
///
/// Run with: mops test
/// Requires: mops add test --dev
import { test; suite } "mo:test/async";
import Principal "mo:base/Principal";
import Time      "mo:base/Time";
import Nat       "mo:base/Nat";
import Int       "mo:base/Int";

import T "../src/types/Types";

/// ── helpers ────────────────────────────────────────────────────────────────

let alice = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
let bob   = Principal.fromText("renrk-eyaaa-aaaab-qckzq-cai");

/// ── pure unit tests ────────────────────────────────────────────────────────

suite("Reputation decay formula", func() {

  /// Simulate one month of 1 % decay
  func applyDecay(score : Nat, ratePerMille : Nat) : Nat {
    let decayAmt = (score * ratePerMille) / 1_000;
    if (score > decayAmt) score - decayAmt else 0
  };

  let p = T.defaultParams;

  test("1% decay on 1000 score → 990", func() {
    assert applyDecay(1_000, p.reputationDecayPerMille) == 990
  });

  test("1% decay on 0 score → 0", func() {
    assert applyDecay(0, p.reputationDecayPerMille) == 0
  });

  test("score never goes negative", func() {
    assert applyDecay(1, p.reputationDecayPerMille) == 0
  });

  test("12 months decay reduces score to ~88.6% of original", func() {
    var score = 1_000;
    for (_ in [1,2,3,4,5,6,7,8,9,10,11,12].vals()) {
      score := applyDecay(score, p.reputationDecayPerMille);
    };
    // 1000 × 0.99^12 ≈ 886
    assert score >= 880 and score <= 895;
  });
});

suite("Reputation slashing", func() {

  func applySlash(score : Nat, penaltyBps : Nat) : { newScore : Nat; slashed : Nat } {
    let penalty  = (score * penaltyBps) / 10_000;
    let newScore = if (score > penalty) score - penalty else 0;
    { newScore; slashed = score - newScore }
  };

  let p = T.defaultParams;  // slashingPenaltyBps = 2000 (20%)

  test("20% slash on 1000 → 800 remaining", func() {
    let r = applySlash(1_000, p.slashingPenaltyBps);
    assert r.newScore == 800;
    assert r.slashed  == 200;
  });

  test("slash on 0 → 0 remaining, 0 slashed", func() {
    let r = applySlash(0, p.slashingPenaltyBps);
    assert r.newScore == 0 and r.slashed == 0;
  });

  test("100% slash penalty → score goes to 0", func() {
    let r = applySlash(500, 10_000);
    assert r.newScore == 0;
  });
});

suite("Progressive voting rights (anti-Sybil)", func() {

  func votingRightBps(accountAgeNs : Int, minAgeNs : Int) : Nat {
    if (accountAgeNs >= minAgeNs) return 10_000;
    Nat.max(0, (Int.abs(accountAgeNs) * 10_000) / Int.abs(minAgeNs))
  };

  let minAge = T.defaultParams.minAccountAgeNs; // 7 days

  test("brand-new account: 0 bps rights", func() {
    assert votingRightBps(0, minAge) == 0
  });

  test("half-way through: ~5000 bps rights", func() {
    let half = minAge / 2;
    let bps  = votingRightBps(half, minAge);
    assert bps >= 4_900 and bps <= 5_100;
  });

  test("exactly at minimum age: 10000 bps (full rights)", func() {
    assert votingRightBps(minAge, minAge) == 10_000
  });

  test("account older than minimum: still 10000 bps", func() {
    assert votingRightBps(minAge * 2, minAge) == 10_000
  });
});

suite("Governance proposal threshold", func() {

  func meetsThreshold(score : Nat, total : Nat, thresholdBps : Nat) : Bool {
    if (total == 0) return false;
    (score * 10_000) / total >= thresholdBps
  };

  let p = T.defaultParams; // proposalThresholdBps = 100 (1%)

  test("1% of total → meets threshold", func() {
    assert meetsThreshold(100, 10_000, p.proposalThresholdBps)
  });

  test("0.5% of total → does not meet threshold", func() {
    assert not meetsThreshold(50, 10_000, p.proposalThresholdBps)
  });

  test("exactly 1% → meets threshold", func() {
    assert meetsThreshold(1, 100, p.proposalThresholdBps)
  });

  test("total = 0 → never meets threshold", func() {
    assert not meetsThreshold(999, 0, p.proposalThresholdBps)
  });
});

suite("Governance quorum and approval", func() {

  func proposalPasses(forVotes : Nat, totalVotes : Nat, totalWeight : Nat,
                      quorumBps : Nat, approvalBps : Nat) : Bool {
    let quorumMet = if (totalWeight == 0) false
      else (totalVotes * 10_000) / totalWeight >= quorumBps;
    let approved  = if (totalVotes == 0) false
      else (forVotes * 10_000) / totalVotes >= approvalBps;
    quorumMet and approved
  };

  let p = T.defaultParams; // quorum 20%, approval 60%

  test("20% participation + 60% FOR → passes", func() {
    // total weight = 1000, 200 voted (20%), 120 for (60%)
    assert proposalPasses(120, 200, 1_000, p.quorumBps, p.approvalThresholdBps)
  });

  test("19% participation → fails (quorum not met)", func() {
    assert not proposalPasses(114, 190, 1_000, p.quorumBps, p.approvalThresholdBps)
  });

  test("20% participation + 59% FOR → fails (approval not met)", func() {
    assert not proposalPasses(118, 200, 1_000, p.quorumBps, p.approvalThresholdBps)
  });

  test("100% participation + 100% FOR → passes", func() {
    assert proposalPasses(1_000, 1_000, 1_000, p.quorumBps, p.approvalThresholdBps)
  });

  test("zero participation → always fails", func() {
    assert not proposalPasses(0, 0, 1_000, p.quorumBps, p.approvalThresholdBps)
  });
});

suite("Quadratic voting weight", func() {

  let SCALE : Nat = 1_000; // mirrors QUADRATIC_WEIGHT_SCALE from Governance canister

  func weight(score : Nat, rightBps : Nat) : Nat {
    (T.isqrt(score) * SCALE * rightBps) / 10_000
  };

  test("0 rep score → 0 weight", func() {
    assert weight(0, 10_000) == 0
  });

  test("100 rep, full rights → isqrt(100)*1000 = 10000", func() {
    assert weight(100, 10_000) == 10_000
  });

  test("100 rep, 50% rights → 5000", func() {
    assert weight(100, 5_000) == 5_000
  });

  test("400 rep score doubles weight vs 100 rep (not 4×)", func() {
    let w100 = weight(100, 10_000);  // = 10000
    let w400 = weight(400, 10_000);  // = 20000
    // quadratic: w400 = 2 × w100 (not 4×)
    assert w400 == w100 * 2
  });
});
