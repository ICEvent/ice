/// Tests for RewardDistributor canister logic.
///
/// Run with: mops test
/// Requires: mops add test --dev
import { test; suite } "mo:test/async";
import Principal "mo:base/Principal";
import Time      "mo:base/Time";
import Nat       "mo:base/Nat";
import Int       "mo:base/Int";
import Array     "mo:base/Array";

import T "../src/types/Types";

/// ── helpers ────────────────────────────────────────────────────────────────

let alice = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
let rev1  = Principal.fromText("rrkah-fqaaa-aaaab-aaazq-cai");
let rev2  = Principal.fromText("ryjl3-tyaaa-aaaab-aaaba-cai");
let rev3  = Principal.fromText("rno2w-sqaaa-aaaab-aaabq-cai");

func makeReview(reviewer : Principal; approved : Bool; score : Nat) : T.ReviewResult = {
  reviewer; approved; score; feedback = "ok"; timestamp = Time.now()
};

/// Pure simulation of effectiveReward from RewardDistributor
func effectiveReward(base : Nat; qM : Nat; dM : Nat; tM : Nat; cM : Nat) : Nat {
  let s1 = (base  * qM) / 100;
  let s2 = (s1    * dM) / 100;
  let s3 = (s2    * tM) / 100;
  (s3 * cM) / 100
};

func timelinessMultiplier(deliveredAt : ?Int; deadline : Int) : Nat {
  switch (deliveredAt) {
    case null 100;
    case (?d) {
      let diff = deadline - d;
      if (diff >= 86_400_000_000_000) 120
      else if (diff >= 0)             100
      else                            80
    };
  }
};

func collaborationMultiplier(reviewers : [Principal]) : Nat {
  if (reviewers.size() >= 3) 110 else 100
};

/// ── tests ──────────────────────────────────────────────────────────────────

suite("effectiveReward multipliers", func() {

  test("all 100× multipliers → reward equals base", func() {
    assert effectiveReward(10_000, 100, 100, 100, 100) == 10_000
  });

  test("quality multiplier 80 → 80% of base", func() {
    assert effectiveReward(10_000, 80, 100, 100, 100) == 8_000
  });

  test("difficulty 5 → dMult = 50 → reward 50% of base", func() {
    // difficulty 5 → dMult = 5*10 = 50
    assert effectiveReward(10_000, 100, 50, 100, 100) == 5_000
  });

  test("difficulty 10 → dMult = 100 → no change", func() {
    assert effectiveReward(10_000, 100, 100, 100, 100) == 10_000
  });

  test("difficulty 1 → dMult = 10 → 10% of base", func() {
    assert effectiveReward(10_000, 100, 10, 100, 100) == 1_000
  });

  test("early delivery bonus: 1.2× timeliness", func() {
    // timelinessMult = 120 means 120% of base
    assert effectiveReward(10_000, 100, 100, 120, 100) == 12_000
  });

  test("late delivery penalty: 0.8× timeliness", func() {
    assert effectiveReward(10_000, 100, 100, 80, 100) == 8_000
  });

  test("collaboration bonus: 1.1× with 3+ reviewers", func() {
    assert effectiveReward(10_000, 100, 100, 100, 110) == 11_000
  });

  test("stacked multipliers compound correctly", func() {
    // quality=80, difficulty=100, timeliness=120, collaboration=110
    // 10000 → 8000 → 8000 → 9600 → 10560
    assert effectiveReward(10_000, 80, 100, 120, 110) == 10_560
  });

  test("zero base → zero reward regardless of multipliers", func() {
    assert effectiveReward(0, 200, 200, 200, 200) == 0
  });
});

suite("Timeliness multiplier", func() {

  let deadline : Int = 1_000_000_000_000_000; // arbitrary fixed point

  test("delivered 2 days early → 1.2× (120)", func() {
    let deliveredAt = deadline - 2 * 86_400_000_000_000; // 2 days before
    assert timelinessMultiplier(?deliveredAt, deadline) == 120
  });

  test("delivered exactly 1 day early → 1.2×", func() {
    let deliveredAt = deadline - 86_400_000_000_000;
    assert timelinessMultiplier(?deliveredAt, deadline) == 120
  });

  test("delivered 1 second before deadline → 1.0× (100)", func() {
    let deliveredAt = deadline - 1_000_000_000; // 1 second before
    assert timelinessMultiplier(?deliveredAt, deadline) == 100
  });

  test("delivered exactly on deadline → 1.0× (100)", func() {
    assert timelinessMultiplier(?deadline, deadline) == 100
  });

  test("delivered 1 second after deadline → 0.8× (80)", func() {
    let deliveredAt = deadline + 1_000_000_000;
    assert timelinessMultiplier(?deliveredAt, deadline) == 80
  });

  test("no delivery yet → 1.0× (100)", func() {
    assert timelinessMultiplier(null, deadline) == 100
  });
});

suite("Collaboration multiplier", func() {

  test("3 reviewers → 1.1× (110)", func() {
    assert collaborationMultiplier([rev1, rev2, rev3]) == 110
  });

  test("2 reviewers → 1.0× (100)", func() {
    assert collaborationMultiplier([rev1, rev2]) == 100
  });

  test("1 reviewer → 1.0× (100)", func() {
    assert collaborationMultiplier([rev1]) == 100
  });

  test("0 reviewers → 1.0× (100)", func() {
    assert collaborationMultiplier([]) == 100
  });
});

suite("Reward split invariants", func() {

  func split(effective : Nat; p : T.SystemParameters) : { s : Nat; t : Nat; r : Nat } = {
    s = (effective * p.stablecoinRatioBps) / 10_000;
    t = (effective * p.tokenRatioBps)      / 10_000;
    r = (effective * p.reputationRatioBps) / 10_000;
  };

  let p = T.defaultParams;

  test("split of 10000 e8s: 7000 + 2000 + 1000", func() {
    let r = split(10_000, p);
    assert r.s == 7_000 and r.t == 2_000 and r.r == 1_000
  });

  test("split sums match total reward (no rounding loss for round amounts)", func() {
    let r = split(10_000, p);
    assert r.s + r.t + r.r == 10_000
  });

  test("split of 0 → all 0", func() {
    let r = split(0, p);
    assert r.s == 0 and r.t == 0 and r.r == 0
  });
});

suite("Vesting schedule releasable calculation", func() {

  let totalAmount     : Nat = 10_000;
  let cliffDuration   : Int = T.defaultParams.cliffDurationNs;   // 90 days
  let vestingDuration : Int = T.defaultParams.vestingDurationNs;  // 365 days

  func releasable(elapsed : Int) : Nat {
    if (elapsed < cliffDuration) return 0;
    if (elapsed >= vestingDuration) return totalAmount;
    (totalAmount * Int.abs(elapsed)) / Int.abs(vestingDuration)
  };

  test("before cliff (1 day elapsed): 0 releasable", func() {
    assert releasable(86_400_000_000_000) == 0
  });

  test("before cliff (89 days): 0 releasable", func() {
    assert releasable(89 * 86_400_000_000_000) == 0
  });

  test("at cliff (90 days): > 0 releasable", func() {
    assert releasable(cliffDuration) > 0
  });

  test("at half vesting duration (~182 days): ~50% releasable", func() {
    let v = releasable(vestingDuration / 2);
    assert v >= 4_800 and v <= 5_200
  });

  test("at full vesting: 100% releasable", func() {
    assert releasable(vestingDuration) == totalAmount
  });

  test("beyond full vesting: capped at totalAmount", func() {
    assert releasable(vestingDuration * 2) == totalAmount
  });
});
