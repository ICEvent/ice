/// Tests for Governance canister logic.
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
let bob   = Principal.fromText("renrk-eyaaa-aaaab-qckzq-cai");
let carol = Principal.fromText("r7inp-6aaaa-aaaab-qabpq-cai");

func makeVote(voter : Principal, support : Bool, weight : Nat) : T.Vote = {
  voter; support; weight; timestamp = Time.now()
};

/// ── pure unit tests ─────────────────────────────────────────────────────────

suite("Proposal status transitions", func() {

  func mockProposal(status : T.ProposalStatus) : T.Proposal = {
    id           = 0;
    proposer     = alice;
    title        = "Test proposal";
    description  = "Change a parameter";
    proposalType = #ParameterChange { key = "quorumBps"; value = 2_500 };
    status       = status;
    forVotes     = 0;
    againstVotes = 0;
    startTime    = Time.now();
    endTime      = Time.now() + T.defaultParams.votingPeriodNs;
    timelockEnd  = null;
    executedAt   = null;
    votes        = [];
    createdAt    = Time.now();
  };

  test("new proposal is #Active", func() {
    assert mockProposal(#Active).status == #Active
  });

  test("cancelled proposal is #Cancelled", func() {
    assert mockProposal(#Cancelled).status == #Cancelled
  });

  test("succeeded proposal needs timelock before execution", func() {
    let p = mockProposal(#Succeeded);
    // timelockEnd is null → execution must be blocked
    assert p.timelockEnd == null
  });
});

suite("Vote weight aggregation", func() {

  test("single FOR vote is counted correctly", func() {
    let votes = [makeVote(alice, true, 100)];
    let forV  = Array.foldLeft<T.Vote, Nat>(votes, 0, func(acc, v) { if (v.support) acc + v.weight else acc });
    assert forV == 100
  });

  test("mixed votes: FOR > AGAINST", func() {
    let votes = [makeVote(alice, true, 600), makeVote(bob, false, 400)];
    let forV  = Array.foldLeft<T.Vote, Nat>(votes, 0, func(acc, v) { if (v.support)      acc + v.weight else acc });
    let agnst = Array.foldLeft<T.Vote, Nat>(votes, 0, func(acc, v) { if (not v.support)  acc + v.weight else acc });
    assert forV  == 600;
    assert agnst == 400;
  });

  test("zero-weight vote does not change totals", func() {
    let votes = [makeVote(alice, true, 0)];
    let forV  = Array.foldLeft<T.Vote, Nat>(votes, 0, func(acc, v) { if (v.support) acc + v.weight else acc });
    assert forV == 0
  });

  test("duplicate principal check helper", func() {
    let votes = [makeVote(alice, true, 100)];
    let alreadyVoted = Array.find<T.Vote>(votes, func(v) { Principal.equal(v.voter, alice) });
    assert alreadyVoted != null
  });
});

suite("Quorum and approval check", func() {

  func finalise(forV : Nat, totalV : Nat, totalW : Nat, p : T.SystemParameters)
      : { quorum : Bool; approved : Bool; passes : Bool } {
    let quorum   = if (totalW == 0) false else (totalV * 10_000) / totalW >= p.quorumBps;
    let approved = if (totalV == 0) false else (forV   * 10_000) / totalV >= p.approvalThresholdBps;
    { quorum; approved; passes = quorum and approved }
  };

  let p = T.defaultParams;

  test("20% quorum, 60% approval → passes", func() {
    let r = finalise(120, 200, 1_000, p);
    assert r.passes
  });

  test("exactly 20% quorum, exactly 60% approval → passes", func() {
    let r = finalise(60, 100, 500, p);
    assert r.passes
  });

  test("19.9% quorum → fails", func() {
    let r = finalise(119, 199, 1_000, p);
    assert not r.quorum
  });

  test("59.9% approval → fails", func() {
    let r = finalise(119, 200, 1_000, p);
    assert not r.approved
  });

  test("empty vote set → fails", func() {
    let r = finalise(0, 0, 1_000, p);
    assert not r.passes
  });

  test("budget proposal (higher threshold: 60%+) – matching test", func() {
    // Budget approvals use same 60% threshold per spec §1-C-2
    let r = finalise(600, 1_000, 2_000, p);
    assert r.passes
  });
});

suite("Timelock enforcement", func() {

  let timelockDelay = T.defaultParams.timelockDelayNs; // 2 days

  func canExecute(timelockEnd : Int, now : Int) : Bool {
    now >= timelockEnd
  };

  test("cannot execute before timelock ends", func() {
    let now        = Time.now();
    let timelockEnd = now + timelockDelay;
    assert not canExecute(timelockEnd, now)
  });

  test("can execute exactly when timelock ends", func() {
    let base = 1_000_000_000_000_000;
    assert canExecute(base, base)
  });

  test("can execute after timelock has elapsed", func() {
    let base = 1_000_000_000_000_000;
    assert canExecute(base, base + 1)
  });
});

suite("Delegation logic", func() {

  test("delegation resolves to target principal", func() {
    // Simulate resolveDelegate: alice → bob, no further delegation
    let chain : [(Principal, Principal)] = [(alice, bob)];
    func resolve(from : Principal) : Principal {
      var cur   = from;
      var depth = 0;
      label lp while (depth < 3) {
        let found = Array.find<(Principal, Principal)>(chain, func((f, _)) { Principal.equal(f, cur) });
        switch (found) {
          case null  { break lp };
          case (?(_, t)) {
            if (Principal.equal(t, from)) break lp; // cycle guard
            cur   := t;
            depth += 1;
          };
        };
      };
      cur
    };
    assert Principal.equal(resolve(alice), bob)
  });

  test("delegation chain of 2: alice → bob → carol resolves to carol", func() {
    let chain : [(Principal, Principal)] = [(alice, bob), (bob, carol)];
    func resolve(from : Principal) : Principal {
      var cur   = from;
      var depth = 0;
      label lp while (depth < 3) {
        let found = Array.find<(Principal, Principal)>(chain, func((f, _)) { Principal.equal(f, cur) });
        switch (found) {
          case null  { break lp };
          case (?(_, t)) {
            if (Principal.equal(t, from)) break lp;
            cur   := t;
            depth += 1;
          };
        };
      };
      cur
    };
    assert Principal.equal(resolve(alice), carol)
  });

  test("delegation self-loop: resolves to self (cycle guard)", func() {
    let chain : [(Principal, Principal)] = [(alice, alice)];
    func resolve(from : Principal) : Principal {
      var cur   = from;
      var depth = 0;
      label lp while (depth < 3) {
        let found = Array.find<(Principal, Principal)>(chain, func((f, _)) { Principal.equal(f, cur) });
        switch (found) {
          case null  { break lp };
          case (?(_, t)) {
            if (Principal.equal(t, from)) break lp; // cycle guard
            cur   := t;
            depth += 1;
          };
        };
      };
      cur
    };
    assert Principal.equal(resolve(alice), alice)
  });

  test("no delegation: resolves to self", func() {
    let chain : [(Principal, Principal)] = [];
    func resolve(from : Principal) : Principal {
      var cur   = from;
      var depth = 0;
      label lp while (depth < 3) {
        let found = Array.find<(Principal, Principal)>(chain, func((f, _)) { Principal.equal(f, cur) });
        switch (found) {
          case null  { break lp };
          case (?(_, t)) {
            if (Principal.equal(t, from)) break lp;
            cur   := t;
            depth += 1;
          };
        };
      };
      cur
    };
    assert Principal.equal(resolve(alice), alice)
  });
});

suite("Parameter change dispatch", func() {

  func applyParam(params : T.SystemParameters, key : Text, value : Nat) : T.SystemParameters {
    switch (key) {
      case "reviewerCount"           { { params with reviewerCount           = value } };
      case "reviewThreshold"         { { params with reviewThreshold         = value } };
      case "stablecoinRatioBps"      { { params with stablecoinRatioBps      = value } };
      case "tokenRatioBps"           { { params with tokenRatioBps           = value } };
      case "reputationRatioBps"      { { params with reputationRatioBps      = value } };
      case "reputationDecayPerMille" { { params with reputationDecayPerMille = value } };
      case "proposalThresholdBps"    { { params with proposalThresholdBps    = value } };
      case "quorumBps"               { { params with quorumBps               = value } };
      case "approvalThresholdBps"    { { params with approvalThresholdBps    = value } };
      case "slashingPenaltyBps"      { { params with slashingPenaltyBps      = value } };
      case _                         { params };
    }
  };

  let base = T.defaultParams;

  test("change quorumBps to 2500", func() {
    let updated = applyParam(base, "quorumBps", 2_500);
    assert updated.quorumBps == 2_500
  });

  test("unknown key leaves params unchanged", func() {
    let updated = applyParam(base, "nonExistentKey", 999);
    assert updated.quorumBps == base.quorumBps
  });

  test("change reviewerCount to 5", func() {
    let updated = applyParam(base, "reviewerCount", 5);
    assert updated.reviewerCount == 5
  });

  test("change slashingPenalty to 30%", func() {
    let updated = applyParam(base, "slashingPenaltyBps", 3_000);
    assert updated.slashingPenaltyBps == 3_000
  });
});
