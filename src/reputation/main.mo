/// Reputation canister
/// Manages soulbound (non-transferable) reputation scores for every Principal.
///
/// Key properties (spec §1-B-1, §1-C-2):
///  - Scores are bound to identity and cannot be transferred
///  - Monthly decay of 1 % (configurable) encourages continuous contribution
///  - Anti-Sybil: account age is tracked; voting rights released progressively
///  - Only authorised canisters (WorkRegistry, Governance) may mint/slash
import HashMap  "mo:base/HashMap";
import Iter     "mo:base/Iter";
import Array    "mo:base/Array";
import Principal "mo:base/Principal";
import Time     "mo:base/Time";
import Nat      "mo:base/Nat";
import Int      "mo:base/Int";
import Hash     "mo:base/Hash";
import Result   "mo:base/Result";
import Buffer   "mo:base/Buffer";

import T "../types/Types";

actor Reputation {

  // ─── Types ─────────────────────────────────────────────────────────────

  type Error  = T.Error;

  /// Per-account reputation record
  type ReputationRecord = {
    score         : Nat;   // current score
    totalEarned   : Nat;   // lifetime total (never decays)
    createdAt     : Int;   // account creation timestamp (ns)
    lastDecayAt   : Int;   // last time monthly decay was applied
  };

  // ─── Stable state (survives canister upgrades) ──────────────────────────

  stable var stableRecords     : [(Principal, ReputationRecord)] = [];
  stable var stableAuthorised  : [Principal]                     = [];
  stable var stableParams      : T.SystemParameters              = T.defaultParams;
  stable var stableTotalScore  : Nat                             = 0;
  stable var stableAdmin       : Principal                       = Principal.fromText("aaaaa-aa");

  // ─── Runtime state ──────────────────────────────────────────────────────

  var records : HashMap.HashMap<Principal, ReputationRecord> =
    HashMap.fromIter(stableRecords.vals(), stableRecords.size(),
                     Principal.equal, Principal.hash);

  var authorised : HashMap.HashMap<Principal, Bool> =
    HashMap.HashMap<Principal, Bool>(8, Principal.equal, Principal.hash);

  // ─── Upgrade hooks ──────────────────────────────────────────────────────

  system func preupgrade() {
    stableRecords    := Iter.toArray(records.entries());
    stableAuthorised := Array.map<(Principal, Bool), Principal>(
      Iter.toArray(authorised.entries()), func((p, _)) { p }
    );
  };

  system func postupgrade() {
    records := HashMap.fromIter(stableRecords.vals(), stableRecords.size(),
                                Principal.equal, Principal.hash);
    for (p in stableAuthorised.vals()) { authorised.put(p, true) };
    stableRecords    := [];
    stableAuthorised := [];
  };

  // ─── Helpers ────────────────────────────────────────────────────────────

  func isAdmin(caller : Principal) : Bool {
    Principal.equal(caller, stableAdmin)
  };

  func isAuthorised(caller : Principal) : Bool {
    isAdmin(caller) or (switch (authorised.get(caller)) { case (?true) true; case _ false })
  };

  func getOrCreate(p : Principal) : ReputationRecord {
    switch (records.get(p)) {
      case (?rec) rec;
      case null {
        { score = 0; totalEarned = 0; createdAt = Time.now(); lastDecayAt = Time.now() }
      };
    }
  };

  // ─── Admin API ──────────────────────────────────────────────────────────

  /// Initialise the admin (called once after deployment)
  public shared(msg) func setAdmin(newAdmin : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller) and not Principal.equal(stableAdmin, Principal.fromText("aaaaa-aa"))) {
      return #err(#Unauthorized("Only admin may set admin"))
    };
    stableAdmin := newAdmin;
    #ok(())
  };

  /// Grant or revoke minting / slashing rights to a canister
  public shared(msg) func setAuthorised(canister : Principal, allowed : Bool) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    if (allowed) { authorised.put(canister, true) }
    else         { authorised.delete(canister)    };
    #ok(())
  };

  /// Update system parameters (called by Governance after a successful vote)
  public shared(msg) func updateParams(params : T.SystemParameters) : async Result.Result<(), Error> {
    if (not isAuthorised(msg.caller)) return #err(#Unauthorized("Not authorised"));
    stableParams := params;
    #ok(())
  };

  // ─── Core API ───────────────────────────────────────────────────────────

  /// Award reputation points to a contributor.
  /// Only authorised canisters (WorkRegistry, RewardDistributor) may call this.
  public shared(msg) func award(recipient : Principal, amount : Nat) : async Result.Result<(), Error> {
    if (not isAuthorised(msg.caller)) return #err(#Unauthorized("Not authorised to award reputation"));
    let rec = getOrCreate(recipient);
    let updated : ReputationRecord = {
      score       = rec.score + amount;
      totalEarned = rec.totalEarned + amount;
      createdAt   = rec.createdAt;
      lastDecayAt = rec.lastDecayAt;
    };
    records.put(recipient, updated);
    stableTotalScore += amount;
    #ok(())
  };

  /// Slash reputation for malicious or low-quality behaviour (spec §1-B-3).
  /// Penalty is `slashingPenaltyBps` of current score (default 20 %).
  public shared(msg) func slash(offender : Principal, reason : Text) : async Result.Result<Nat, Error> {
    if (not isAuthorised(msg.caller)) return #err(#Unauthorized("Not authorised to slash"));
    switch (records.get(offender)) {
      case null { #err(#NotFound("Principal has no reputation record")) };
      case (?rec) {
        let penalty = (rec.score * stableParams.slashingPenaltyBps) / 10_000;
        let newScore = if (rec.score > penalty) rec.score - penalty else 0;
        let slashed  = rec.score - newScore;
        records.put(offender, {
          score       = newScore;
          totalEarned = rec.totalEarned;
          createdAt   = rec.createdAt;
          lastDecayAt = rec.lastDecayAt;
        });
        stableTotalScore := if (stableTotalScore > slashed) stableTotalScore - slashed else 0;
        #ok(slashed)
      };
    }
  };

  /// Apply monthly decay to a specific account (1 % by default, spec §5).
  /// Returns the amount decayed.
  public shared(msg) func applyDecay(target : Principal) : async Result.Result<Nat, Error> {
    if (not isAuthorised(msg.caller)) return #err(#Unauthorized("Not authorised"));
    let now = Time.now();
    switch (records.get(target)) {
      case null { #err(#NotFound("No record")) };
      case (?rec) {
        let monthNs : Int = 2_592_000_000_000_000; // 30 days in ns
        if (now - rec.lastDecayAt < monthNs) {
          return #ok(0) // not yet due
        };
        let decayAmt = (rec.score * stableParams.reputationDecayPerMille) / 1_000;
        let newScore = if (rec.score > decayAmt) rec.score - decayAmt else 0;
        let decayed  = rec.score - newScore;
        records.put(target, {
          score       = newScore;
          totalEarned = rec.totalEarned;
          createdAt   = rec.createdAt;
          lastDecayAt = now;
        });
        stableTotalScore := if (stableTotalScore > decayed) stableTotalScore - decayed else 0;
        #ok(decayed)
      };
    }
  };

  // ─── Query API ──────────────────────────────────────────────────────────

  /// Current reputation score for a Principal
  public query func getScore(p : Principal) : async Nat {
    switch (records.get(p)) { case (?r) r.score; case null 0 }
  };

  /// Full reputation record
  public query func getRecord(p : Principal) : async ?ReputationRecord {
    records.get(p)
  };

  /// Total reputation in the system (used for governance thresholds)
  public query func getTotalScore() : async Nat { stableTotalScore };

  /// Returns true when the account is old enough to participate in governance.
  /// Anti-Sybil: new accounts must wait `minAccountAgeNs` (default 7 days).
  public query func isEligibleForGovernance(p : Principal) : async Bool {
    let now = Time.now();
    switch (records.get(p)) {
      case null  false;
      case (?r)  (now - r.createdAt) >= stableParams.minAccountAgeNs;
    }
  };

  /// Progressive voting-right fraction for new accounts (0–10_000 bps).
  /// Full rights after `minAccountAgeNs`.
  public query func votingRightBps(p : Principal) : async Nat {
    let now = Time.now();
    switch (records.get(p)) {
      case null 0;
      case (?r) {
        let age = now - r.createdAt;
        if (age >= stableParams.minAccountAgeNs) 10_000
        else Nat.max(0, (Int.abs(age) * 10_000) / Int.abs(stableParams.minAccountAgeNs))
      };
    }
  };

  /// Current system parameters
  public query func getParams() : async T.SystemParameters { stableParams };
}
