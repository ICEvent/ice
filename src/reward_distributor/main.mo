/// RewardDistributor canister
/// The value-distribution layer of the ICE network (spec §1-B).
///
/// Reward formula (spec §1-B-2):
///   effectiveReward = base × (qualityMult/100) × (difficultyMult/100)
///                         × (timelinessMult/100) × (collaborationMult/100)
///
/// Split (spec §1-B-1, §5):
///   70 % → stablecoin (instant payout)
///   20 % → incentive token (linear vesting, cliff 90 d, full 365 d)
///   10 % → reputation points (via Reputation canister)
///
/// Long-term incentives (spec §1-B-3):
///   - Linear token vesting with configurable cliff / duration
///   - Quarterly contribution dividend pool
///   - Slashing for malicious behaviour delegated to Reputation canister
import HashMap   "mo:base/HashMap";
import Iter      "mo:base/Iter";
import Array     "mo:base/Array";
import Buffer    "mo:base/Buffer";
import Principal "mo:base/Principal";
import Time      "mo:base/Time";
import Nat       "mo:base/Nat";
import Int       "mo:base/Int";
import Hash      "mo:base/Hash";
import Text      "mo:base/Text";
import Result    "mo:base/Result";

import T "../types/Types";

actor RewardDistributor {

  // ─── Types ─────────────────────────────────────────────────────────────

  type VestingSchedule = T.VestingSchedule;
  type VestingId       = T.VestingId;
  type RewardBreakdown = T.RewardBreakdown;
  type Error           = T.Error;

  // ─── Stable state ───────────────────────────────────────────────────────

  stable var stableVesting       : [(VestingId, VestingSchedule)] = [];
  stable var stableDistributed   : [(T.WorkId,  RewardBreakdown)] = [];
  stable var nextVestingId       : VestingId = 0;
  stable var stableParams        : T.SystemParameters = T.defaultParams;
  stable var stableAdmin         : Principal = Principal.fromText("aaaaa-aa");
  stable var reputationCanister  : Principal = Principal.fromText("aaaaa-aa");
  stable var stableWorkRegistry  : Principal = Principal.fromText("aaaaa-aa");
  /// Total stablecoin held in reserve (e8s). In production integrate with ICRC-1 ledger.
  stable var stablecoinReserve   : Nat = 0;
  /// Total incentive tokens minted (e8s).
  stable var tokenReserve        : Nat = 0;
  /// Quarterly dividend pool accumulator
  stable var dividendPool        : Nat = 0;

  // ─── Runtime state ──────────────────────────────────────────────────────

  var vestingMap : HashMap.HashMap<VestingId, VestingSchedule> =
    HashMap.fromIter(stableVesting.vals(), stableVesting.size(), Nat.equal, Hash.hash);

  var distributedMap : HashMap.HashMap<T.WorkId, RewardBreakdown> =
    HashMap.fromIter(stableDistributed.vals(), stableDistributed.size(), Nat.equal, Hash.hash);

  // ─── Upgrade hooks ──────────────────────────────────────────────────────

  system func preupgrade() {
    stableVesting     := Iter.toArray(vestingMap.entries());
    stableDistributed := Iter.toArray(distributedMap.entries());
  };

  system func postupgrade() {
    vestingMap     := HashMap.fromIter(stableVesting.vals(),     stableVesting.size(),     Nat.equal, Hash.hash);
    distributedMap := HashMap.fromIter(stableDistributed.vals(), stableDistributed.size(), Nat.equal, Hash.hash);
    stableVesting     := [];
    stableDistributed := [];
  };

  // ─── Helpers ────────────────────────────────────────────────────────────

  func isAdmin(caller : Principal) : Bool {
    Principal.equal(caller, stableAdmin)
  };

  func isAuthorised(caller : Principal) : Bool {
    isAdmin(caller) or Principal.equal(caller, stableWorkRegistry)
  };

  /// Compute effective reward from base budget and four multipliers (all ×100).
  func effectiveReward(base : Nat, qM : Nat, dM : Nat, tM : Nat, cM : Nat) : Nat {
    // Apply multipliers sequentially (all scaled ×100 so divide by 100 each time)
    let step1 = (base  * qM) / 100;
    let step2 = (step1 * dM) / 100;
    let step3 = (step2 * tM) / 100;
    (step3 * cM) / 100
  };

  /// Timeliness multiplier: 1.2× if submitted ≥ 1 day early, 1.0× on time,
  /// 0.8× if delivered after deadline (still allowed via dispute resolution).
  func timelinessMultiplier(deliveredAt : ?Int, deadline : Int) : Nat {
    switch (deliveredAt) {
      case null 100; // not yet delivered – default
      case (?d) {
        let diff = deadline - d;
        if (diff >= 86_400_000_000_000) 120      // ≥1 day early → 1.2×
        else if (diff >= 0)             100      // on time → 1.0×
        else                            80       // late → 0.8×
      };
    }
  };

  /// Collaboration multiplier: 1.1× for cross-team work (reviewers ≥ 2 teams).
  /// Simplified heuristic: if ≥3 reviewers from different principals → 110.
  func collaborationMultiplier(reviewers : [Principal]) : Nat {
    if (reviewers.size() >= 3) 110 else 100
  };

  // ─── Admin API ──────────────────────────────────────────────────────────

  public shared(msg) func setAdmin(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller) and not Principal.equal(stableAdmin, Principal.fromText("aaaaa-aa"))) {
      return #err(#Unauthorized("Only admin"))
    };
    stableAdmin := p;
    #ok(())
  };

  public shared(msg) func setReputationCanister(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    reputationCanister := p;
    #ok(())
  };

  public shared(msg) func setWorkRegistry(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    stableWorkRegistry := p;
    #ok(())
  };

  public shared(msg) func updateParams(params : T.SystemParameters) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin or governance"));
    stableParams := params;
    #ok(())
  };

  /// Fund the stablecoin reserve (in production: handled by ICRC-1 token transfer)
  public shared(msg) func depositStablecoin(amount : Nat) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    stablecoinReserve += amount;
    #ok(())
  };

  // ─── Core reward API ────────────────────────────────────────────────────

  /// Calculate reward breakdown for a completed work unit without distributing.
  public query func calculateReward(work : T.WorkUnit) : async Result.Result<RewardBreakdown, Error> {
    switch (work.contributor) {
      case null return #err(#InvalidInput("Work has no contributor"));
      case (?contributor) {
        let qMult = switch (work.reviews.size()) {
          case 0 100;
          case _ {
            let total = Array.foldLeft<T.ReviewResult, Nat>(work.reviews, 0, func(a, r) { a + r.score });
            total / work.reviews.size() // average quality score (1-100) used directly as multiplier
          };
        };
        let dMult = work.difficulty * 10;         // difficulty 1-10 → 10-100 (×100 scale)
        let tMult = timelinessMultiplier(work.deliveredAt, work.deadline);
        let cMult = collaborationMultiplier(work.reviewers);

        let effective = effectiveReward(work.budget, qMult, dMult, tMult, cMult);
        let stable    = (effective * stableParams.stablecoinRatioBps)   / 10_000;
        let token     = (effective * stableParams.tokenRatioBps)         / 10_000;
        let rep       = (effective * stableParams.reputationRatioBps)    / 10_000;

        #ok({
          workId                  = work.id;
          contributor             = contributor;
          baseAmount              = work.budget;
          stablecoinAmount        = stable;
          tokenAmount             = token;
          reputationAmount        = rep;
          qualityMultiplier       = qMult;
          difficultyMultiplier    = dMult;
          timelinessMultiplier    = tMult;
          collaborationMultiplier = cMult;
          calculatedAt            = Time.now();
        })
      };
    }
  };

  /// Calculate AND distribute reward for a completed work unit.
  /// Called by WorkRegistry._onWorkCompleted (inter-canister).
  public shared(msg) func calculateAndDistribute(work : T.WorkUnit) : async Result.Result<RewardBreakdown, Error> {
    if (not isAuthorised(msg.caller)) return #err(#Unauthorized("Only WorkRegistry may trigger distribution"));
    // Idempotency guard
    switch (distributedMap.get(work.id)) {
      case (?existing) return #ok(existing);
      case null {};
    };
    switch (work.contributor) {
      case null return #err(#InvalidInput("No contributor"));
      case (?contributor) {
        let qMult = switch (work.reviews.size()) {
          case 0 100;
          case _ {
            let total = Array.foldLeft<T.ReviewResult, Nat>(work.reviews, 0, func(a, r) { a + r.score });
            total / work.reviews.size()
          };
        };
        let dMult     = work.difficulty * 10;
        let tMult     = timelinessMultiplier(work.deliveredAt, work.deadline);
        let cMult     = collaborationMultiplier(work.reviewers);
        let effective = effectiveReward(work.budget, qMult, dMult, tMult, cMult);
        let stable    = (effective * stableParams.stablecoinRatioBps)  / 10_000;
        let token     = (effective * stableParams.tokenRatioBps)        / 10_000;
        let rep       = (effective * stableParams.reputationRatioBps)   / 10_000;

        // Stablecoin: immediate payout
        if (stablecoinReserve < stable) {
          return #err(#InsufficientFunds("Insufficient stablecoin reserve"))
        };
        stablecoinReserve -= stable;
        // 5 % of stablecoin payout feeds the quarterly dividend pool
        dividendPool += stable / 20;

        // Token: create vesting schedule
        let vestingId = nextVestingId;
        nextVestingId += 1;
        let now = Time.now();
        let schedule : VestingSchedule = {
          id              = vestingId;
          beneficiary     = contributor;
          totalAmount     = token;
          releasedAmount  = 0;
          startTime       = now;
          cliffDuration   = stableParams.cliffDurationNs;
          vestingDuration = stableParams.vestingDurationNs;
          lastReleaseTime = now;
        };
        vestingMap.put(vestingId, schedule);
        tokenReserve += token;

        // Reputation: delegate to Reputation canister
        if (not Principal.equal(reputationCanister, Principal.fromText("aaaaa-aa"))) {
          let repActor = actor(Principal.toText(reputationCanister)) : actor {
            award : (Principal, Nat) -> async Result.Result<(), T.Error>
          };
          ignore await repActor.award(contributor, rep);
        };

        let breakdown : RewardBreakdown = {
          workId                  = work.id;
          contributor             = contributor;
          baseAmount              = work.budget;
          stablecoinAmount        = stable;
          tokenAmount             = token;
          reputationAmount        = rep;
          qualityMultiplier       = qMult;
          difficultyMultiplier    = dMult;
          timelinessMultiplier    = tMult;
          collaborationMultiplier = cMult;
          calculatedAt            = now;
        };
        distributedMap.put(work.id, breakdown);
        #ok(breakdown)
      };
    }
  };

  // ─── Vesting / claiming ─────────────────────────────────────────────────

  /// Calculate how many tokens are currently releasable from a schedule.
  func releasable(s : VestingSchedule) : Nat {
    let now = Time.now();
    let elapsed = now - s.startTime;
    if (elapsed < s.cliffDuration) return 0;           // before cliff
    let vested =
      if (elapsed >= s.vestingDuration) s.totalAmount   // fully vested
      else (s.totalAmount * Int.abs(elapsed)) / Int.abs(s.vestingDuration);
    if (vested > s.releasedAmount) vested - s.releasedAmount else 0
  };

  /// Claim vested tokens from a specific schedule. Caller must be the beneficiary.
  public shared(msg) func claimVested(vestingId : VestingId) : async Result.Result<Nat, Error> {
    switch (vestingMap.get(vestingId)) {
      case null return #err(#NotFound("Vesting schedule " # Nat.toText(vestingId) # " not found"));
      case (?s) {
        if (not Principal.equal(s.beneficiary, msg.caller)) {
          return #err(#Unauthorized("Only beneficiary may claim"))
        };
        let amount = releasable(s);
        if (amount == 0) return #ok(0);
        if (tokenReserve < amount) return #err(#InsufficientFunds("Token reserve depleted"));
        tokenReserve -= amount;
        vestingMap.put(vestingId, { s with releasedAmount = s.releasedAmount + amount; lastReleaseTime = Time.now() });
        #ok(amount)
      };
    }
  };

  // ─── Query API ──────────────────────────────────────────────────────────

  public query func getVestingSchedule(id : VestingId) : async ?VestingSchedule {
    vestingMap.get(id)
  };

  public query func getRewardBreakdown(workId : T.WorkId) : async ?RewardBreakdown {
    distributedMap.get(workId)
  };

  public query func getReleasable(vestingId : VestingId) : async Nat {
    switch (vestingMap.get(vestingId)) {
      case null 0;
      case (?s) releasable(s);
    }
  };

  public query func getReserves() : async { stablecoin : Nat; token : Nat; dividendPool : Nat } {
    { stablecoin = stablecoinReserve; token = tokenReserve; dividendPool = dividendPool }
  };

  public query func getParams() : async T.SystemParameters { stableParams };
}
