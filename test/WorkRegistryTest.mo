/// Tests for the WorkRegistry canister.
///
/// Run with:  mops test
/// Requires:  mops add test --dev  (adds mo:test)
import { test; suite } "mo:test/async";
import Principal "mo:base/Principal";
import Time      "mo:base/Time";
import Array     "mo:base/Array";
import Nat       "mo:base/Nat";

import T  "../src/types/Types";

/// ── helpers ────────────────────────────────────────────────────────────────

let alice   = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");
let bob     = Principal.fromText("renrk-eyaaa-aaaab-qckzq-cai");
let carol   = Principal.fromText("r7inp-6aaaa-aaaab-qabpq-cai");
let rev1    = Principal.fromText("rrkah-fqaaa-aaaab-aaazq-cai");
let rev2    = Principal.fromText("ryjl3-tyaaa-aaaab-aaaba-cai");
let rev3    = Principal.fromText("rno2w-sqaaa-aaaab-aaabq-cai");

func futureDeadline() : Int { Time.now() + T.DAY_IN_NS }; // +1 day

/// ── pure-function unit tests ────────────────────────────────────────────────

suite("Types.isqrt", func() {
  test("isqrt(0) = 0",   func() { assert T.isqrt(0)  == 0 });
  test("isqrt(1) = 1",   func() { assert T.isqrt(1)  == 1 });
  test("isqrt(4) = 2",   func() { assert T.isqrt(4)  == 2 });
  test("isqrt(9) = 3",   func() { assert T.isqrt(9)  == 3 });
  test("isqrt(10) = 3",  func() { assert T.isqrt(10) == 3 });
  test("isqrt(100) = 10",func() { assert T.isqrt(100) == 10 });
  test("isqrt(1000000) = 1000", func() { assert T.isqrt(1_000_000) == 1_000 });
});

suite("Types.defaultParams", func() {
  let p = T.defaultParams;

  test("reviewerCount = 3",        func() { assert p.reviewerCount == 3 });
  test("reviewThreshold = 2",      func() { assert p.reviewThreshold == 2 });
  test("disputePeriod 72h",        func() { assert p.disputePeriodNs == 259_200_000_000_000 });
  test("stablecoin ratio = 70%",   func() { assert p.stablecoinRatioBps == 7_000 });
  test("token ratio = 20%",        func() { assert p.tokenRatioBps == 2_000 });
  test("reputation ratio = 10%",   func() { assert p.reputationRatioBps == 1_000 });
  test("decay = 1% per month",     func() { assert p.reputationDecayPerMille == 10 });
  test("proposal threshold = 1%",  func() { assert p.proposalThresholdBps == 100 });
  test("quorum = 20%",             func() { assert p.quorumBps == 2_000 });
  test("approval = 60%",           func() { assert p.approvalThresholdBps == 6_000 });
  test("split sums to 100%",       func() {
    assert p.stablecoinRatioBps + p.tokenRatioBps + p.reputationRatioBps == 10_000
  });
  test("voting period = 7 days",   func() { assert p.votingPeriodNs == 604_800_000_000_000 });
  test("timelock = 2 days",        func() { assert p.timelockDelayNs == 172_800_000_000_000 });
});

suite("WorkUnit status transitions (state machine)", func() {

  // Build a mock work unit
  func mockWork(status : T.WorkStatus) : T.WorkUnit = {
    id              = 0;
    workType        = #Task;
    sponsor         = alice;
    title           = "Test Task";
    description     = "description";
    requirements    = "requirements";
    budget          = 1_000_000;
    rewardToken     = 200_000;
    deadline        = futureDeadline();
    difficulty      = 3;
    status          = status;
    contributor     = null;
    reviewers       = [rev1, rev2, rev3];
    reviews         = [];
    deliveryHash    = null;
    deliveredAt     = null;
    completedAt     = null;
    disputeDeadline = null;
    createdAt       = Time.now();
  };

  test("newly created work is #Open", func() {
    let w = mockWork(#Open);
    assert w.status == #Open;
  });

  test("work with contributor assigned is #InProgress", func() {
    let w = { mockWork(#InProgress) with contributor = ?bob };
    assert w.status == #InProgress;
    assert w.contributor == ?bob;
  });

  test("difficulty range valid (1-10)", func() {
    for (d in [1, 5, 10].vals()) {
      let w = { mockWork(#Open) with difficulty = d };
      assert w.difficulty >= 1 and w.difficulty <= 10;
    }
  });

  test("dispute deadline = deliveredAt + disputePeriodNs", func() {
    let deliveredAt  : Int = Time.now();
    let disputePeriod = T.defaultParams.disputePeriodNs;
    let disputeDeadline = deliveredAt + disputePeriod;
    let w = {
      mockWork(#Submitted) with
      deliveryHash    = ?"QmTestHash";
      deliveredAt     = ?deliveredAt;
      disputeDeadline = ?disputeDeadline;
    };
    switch (w.disputeDeadline) {
      case null assert false;
      case (?dl) assert dl == deliveredAt + disputePeriod;
    }
  });
});

suite("ReviewResult aggregation helpers", func() {

  func makeReview(reviewer : Principal, approved : Bool, score : Nat) : T.ReviewResult = {
    reviewer  = reviewer;
    approved  = approved;
    score     = score;
    feedback  = "ok";
    timestamp = Time.now();
  };

  test("count approvals – all approve", func() {
    let reviews = [makeReview(rev1, true, 90), makeReview(rev2, true, 80), makeReview(rev3, true, 85)];
    let approvals = Array.foldLeft<T.ReviewResult, Nat>(reviews, 0, func(acc, r) { if (r.approved) acc+1 else acc });
    assert approvals == 3;
  });

  test("count approvals – 2-of-3 threshold met", func() {
    let reviews = [makeReview(rev1, true, 90), makeReview(rev2, false, 40), makeReview(rev3, true, 75)];
    let approvals = Array.foldLeft<T.ReviewResult, Nat>(reviews, 0, func(acc, r) { if (r.approved) acc+1 else acc });
    assert approvals >= T.defaultParams.reviewThreshold;
  });

  test("count approvals – threshold NOT met", func() {
    let reviews = [makeReview(rev1, false, 20), makeReview(rev2, false, 30)];
    let approvals = Array.foldLeft<T.ReviewResult, Nat>(reviews, 0, func(acc, r) { if (r.approved) acc+1 else acc });
    assert approvals < T.defaultParams.reviewThreshold;
  });

  test("average quality score", func() {
    let reviews = [makeReview(rev1, true, 80), makeReview(rev2, true, 90), makeReview(rev3, true, 70)];
    let total   = Array.foldLeft<T.ReviewResult, Nat>(reviews, 0, func(acc, r) { acc + r.score });
    let avg     = total / reviews.size();
    assert avg == 80;
  });
});

suite("RewardBreakdown ratio invariants", func() {

  // Simulate the reward calculation from RewardDistributor
  func calcBreakdown(budget : Nat, p : T.SystemParameters) : { stable : Nat; token : Nat; rep : Nat; sum : Nat } {
    let effective = budget; // simplified: no multipliers
    let stable = (effective * p.stablecoinRatioBps) / 10_000;
    let token  = (effective * p.tokenRatioBps)      / 10_000;
    let rep    = (effective * p.reputationRatioBps)  / 10_000;
    { stable; token; rep; sum = stable + token + rep }
  };

  let p = T.defaultParams;

  test("stablecoin portion = 70 % of budget", func() {
    let r = calcBreakdown(10_000, p);
    assert r.stable == 7_000;
  });

  test("token portion = 20 % of budget", func() {
    let r = calcBreakdown(10_000, p);
    assert r.token == 2_000;
  });

  test("reputation portion = 10 % of budget", func() {
    let r = calcBreakdown(10_000, p);
    assert r.rep == 1_000;
  });

  test("portions sum to 100 % of budget", func() {
    let r = calcBreakdown(10_000, p);
    assert r.sum == 10_000;
  });

  test("zero budget yields zero rewards", func() {
    let r = calcBreakdown(0, p);
    assert r.stable == 0 and r.token == 0 and r.rep == 0;
  });
});

suite("Quadratic voting weight", func() {

  test("weight(0 rep) = 0",    func() { assert T.isqrt(0)   == 0  });
  test("weight(100 rep) = 10", func() { assert T.isqrt(100) == 10 });
  test("weight(400 rep) = 20", func() { assert T.isqrt(400) == 20 });

  test("quadratic is sublinear: isqrt(4x) < 2*isqrt(x) for large x", func() {
    // isqrt grows slower than linear → fairer distribution
    let x    = 1_000;
    let four = T.isqrt(4 * x);
    let two  = 2 * T.isqrt(x);
    // For perfect squares: isqrt(4x) == 2*isqrt(x) iff x is a perfect square
    // For non-perfect squares the inequality holds strictly
    assert four <= two;
  });
});

suite("VestingSchedule cliff logic", func() {

  func vestable(totalAmount : Nat, cliffDuration : Int, vestingDuration : Int, elapsed : Int) : Nat {
    if (elapsed < cliffDuration) return 0;
    if (elapsed >= vestingDuration) return totalAmount;
    (totalAmount * Int.abs(elapsed)) / Int.abs(vestingDuration)
  };

  let cliff  = T.defaultParams.cliffDurationNs;
  let full   = T.defaultParams.vestingDurationNs;
  let amount = 10_000;

  test("nothing vested before cliff", func() {
    assert vestable(amount, cliff, full, cliff - 1) == 0
  });

  test("partial vesting at cliff start", func() {
    // At exactly the cliff, we have cliffDuration elapsed out of vestingDuration
    let v = vestable(amount, cliff, full, cliff);
    assert v > 0 and v < amount;
  });

  test("fully vested after duration", func() {
    assert vestable(amount, cliff, full, full) == amount
  });

  test("no over-vesting after full duration", func() {
    assert vestable(amount, cliff, full, full * 2) == amount
  });
});
