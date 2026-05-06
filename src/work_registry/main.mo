/// WorkRegistry canister
/// The value-production layer of the ICE network (spec §1-A).
///
/// Lifecycle:
///   createWork → applyForWork → assignContributor → submitDelivery
///   → reviewWork (N-of-M) → [disputeWork → resolveDispute] → completeWork
///
/// On completion the canister calls:
///   - RewardDistributor.calculate + distribute
///   - Reputation.award (for contributor and reviewers)
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
import Option    "mo:base/Option";

import T "../types/Types";

actor WorkRegistry {

  // ─── Types ─────────────────────────────────────────────────────────────

  type WorkUnit = T.WorkUnit;
  type WorkId   = T.WorkId;
  type Error    = T.Error;

  // ─── Stable state ───────────────────────────────────────────────────────

  stable var stableWorks       : [(WorkId, WorkUnit)] = [];
  stable var stableApplicants  : [(WorkId, [Principal])] = [];
  stable var nextWorkId        : WorkId = 0;
  stable var stableParams      : T.SystemParameters = T.defaultParams;
  stable var stableAdmin       : Principal = Principal.fromText("aaaaa-aa");
  stable var reputationCanister: Principal = Principal.fromText("aaaaa-aa");
  stable var rewardCanister    : Principal = Principal.fromText("aaaaa-aa");

  // ─── Runtime state ──────────────────────────────────────────────────────

  var works : HashMap.HashMap<WorkId, WorkUnit> =
    HashMap.fromIter(stableWorks.vals(), stableWorks.size(), Nat.equal, Hash.hash);

  var applicants : HashMap.HashMap<WorkId, Buffer.Buffer<Principal>> =
    HashMap.HashMap<WorkId, Buffer.Buffer<Principal>>(64, Nat.equal, Hash.hash);

  // ─── Upgrade hooks ──────────────────────────────────────────────────────

  system func preupgrade() {
    stableWorks := Iter.toArray(works.entries());
    let appBuf = Buffer.Buffer<(WorkId, [Principal])>(applicants.size());
    for ((id, buf) in applicants.entries()) {
      appBuf.add((id, Buffer.toArray(buf)));
    };
    stableApplicants := Buffer.toArray(appBuf);
  };

  system func postupgrade() {
    works := HashMap.fromIter(stableWorks.vals(), stableWorks.size(), Nat.equal, Hash.hash);
    for ((id, arr) in stableApplicants.vals()) {
      let buf = Buffer.Buffer<Principal>(arr.size());
      for (p in arr.vals()) { buf.add(p) };
      applicants.put(id, buf);
    };
    stableWorks      := [];
    stableApplicants := [];
  };

  // ─── Admin / configuration ──────────────────────────────────────────────

  func isAdmin(caller : Principal) : Bool {
    Principal.equal(caller, stableAdmin)
  };

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

  public shared(msg) func setRewardCanister(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    rewardCanister := p;
    #ok(())
  };

  public shared(msg) func updateParams(params : T.SystemParameters) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin or governance"));
    stableParams := params;
    #ok(())
  };

  // ─── Internal helpers ───────────────────────────────────────────────────

  func findWork(id : WorkId) : Result.Result<WorkUnit, Error> {
    switch (works.get(id)) {
      case null  #err(#NotFound("Work unit " # Nat.toText(id) # " not found"));
      case (?w)  #ok(w);
    }
  };

  func requireStatus(w : WorkUnit, expected : T.WorkStatus) : Result.Result<(), Error> {
    if (w.status == expected) #ok(())
    else #err(#InvalidState("Expected status " # debug_show(expected) # " but got " # debug_show(w.status)))
  };

  func countApprovals(reviews : [T.ReviewResult]) : Nat {
    Array.foldLeft<T.ReviewResult, Nat>(reviews, 0, func(acc, r) {
      if (r.approved) acc + 1 else acc
    })
  };

  func averageQuality(reviews : [T.ReviewResult]) : Nat {
    if (reviews.size() == 0) return 100;
    let total = Array.foldLeft<T.ReviewResult, Nat>(reviews, 0, func(acc, r) { acc + r.score });
    total / reviews.size()
  };

  func hasReviewed(reviews : [T.ReviewResult], reviewer : Principal) : Bool {
    Array.find<T.ReviewResult>(reviews, func(r) { Principal.equal(r.reviewer, reviewer) }) != null
  };

  // ─── Sponsor API ────────────────────────────────────────────────────────

  /// Post a new work unit. Caller becomes the sponsor.
  public shared(msg) func createWork(
    workType    : T.WorkType,
    title       : Text,
    description : Text,
    requirements: Text,
    budget      : Nat,         // stablecoin (e8s)
    rewardToken : Nat,         // token amount
    deadline    : Int,         // nanosecond timestamp
    difficulty  : Nat,         // 1-10
    reviewers   : [Principal], // pre-selected reviewers (optional, may be empty)
  ) : async Result.Result<WorkId, Error> {
    let now = Time.now();
    if (deadline <= now) return #err(#InvalidInput("Deadline must be in the future"));
    if (difficulty < 1 or difficulty > 10) return #err(#InvalidInput("Difficulty must be 1-10"));
    if (Text.size(title) == 0) return #err(#InvalidInput("Title cannot be empty"));

    let id = nextWorkId;
    nextWorkId += 1;

    let work : WorkUnit = {
      id              = id;
      workType        = workType;
      sponsor         = msg.caller;
      title           = title;
      description     = description;
      requirements    = requirements;
      budget          = budget;
      rewardToken     = rewardToken;
      deadline        = deadline;
      difficulty      = difficulty;
      status          = #Open;
      contributor     = null;
      reviewers       = reviewers;
      reviews         = [];
      deliveryHash    = null;
      deliveredAt     = null;
      completedAt     = null;
      disputeDeadline = null;
      createdAt       = now;
    };
    works.put(id, work);
    applicants.put(id, Buffer.Buffer<Principal>(8));
    #ok(id)
  };

  /// Sponsor cancels a work unit (only while Open or InProgress without submission)
  public shared(msg) func cancelWork(workId : WorkId) : async Result.Result<(), Error> {
    switch (findWork(workId)) {
      case (#err e) #err(e);
      case (#ok w) {
        if (not Principal.equal(w.sponsor, msg.caller)) return #err(#Unauthorized("Only sponsor"));
        if (w.status != #Open and w.status != #InProgress) {
          return #err(#InvalidState("Cannot cancel work in status " # debug_show(w.status)))
        };
        works.put(workId, { w with status = #Cancelled });
        #ok(())
      };
    }
  };

  // ─── Contributor API ────────────────────────────────────────────────────

  /// A contributor signals interest in a work unit
  public shared(msg) func applyForWork(workId : WorkId) : async Result.Result<(), Error> {
    switch (findWork(workId)) {
      case (#err e) #err(e);
      case (#ok w) {
        switch (requireStatus(w, #Open)) {
          case (#err e) return #err(e);
          case (#ok _) {};
        };
        if (Principal.equal(w.sponsor, msg.caller)) {
          return #err(#Unauthorized("Sponsor cannot apply to own work"))
        };
        let buf = switch (applicants.get(workId)) {
          case (?b) b;
          case null {
            let b = Buffer.Buffer<Principal>(8);
            applicants.put(workId, b);
            b
          };
        };
        // Idempotent – skip if already applied
        let already = Buffer.contains<Principal>(buf, msg.caller, Principal.equal);
        if (not already) { buf.add(msg.caller) };
        #ok(())
      };
    }
  };

  /// Sponsor assigns the work to one of the applicants
  public shared(msg) func assignContributor(workId : WorkId, contributor : Principal) : async Result.Result<(), Error> {
    switch (findWork(workId)) {
      case (#err e) #err(e);
      case (#ok w) {
        if (not Principal.equal(w.sponsor, msg.caller)) return #err(#Unauthorized("Only sponsor"));
        switch (requireStatus(w, #Open)) {
          case (#err e) return #err(e);
          case (#ok _) {};
        };
        works.put(workId, { w with status = #InProgress; contributor = ?contributor });
        #ok(())
      };
    }
  };

  /// Contributor submits delivery with an on-chain content hash (IPFS/Arweave CID)
  public shared(msg) func submitDelivery(workId : WorkId, deliveryHash : Text) : async Result.Result<(), Error> {
    switch (findWork(workId)) {
      case (#err e) #err(e);
      case (#ok w) {
        switch (requireStatus(w, #InProgress)) {
          case (#err e) return #err(e);
          case (#ok _) {};
        };
        switch (w.contributor) {
          case null return #err(#InvalidState("No contributor assigned"));
          case (?c) {
            if (not Principal.equal(c, msg.caller)) return #err(#Unauthorized("Only assigned contributor"));
          };
        };
        if (Text.size(deliveryHash) == 0) return #err(#InvalidInput("Delivery hash cannot be empty"));
        let now = Time.now();
        if (now > w.deadline) return #err(#DeadlineExceeded("Submission deadline passed"));
        let disputeDeadline = now + stableParams.disputePeriodNs;
        works.put(workId, {
          w with
          status          = #Submitted;
          deliveryHash    = ?deliveryHash;
          deliveredAt     = ?now;
          disputeDeadline = ?disputeDeadline;
        });
        #ok(())
      };
    }
  };

  // ─── Reviewer API ───────────────────────────────────────────────────────

  /// A reviewer submits their assessment. Triggers completion when threshold is met.
  public shared(msg) func reviewWork(
    workId   : WorkId,
    approved : Bool,
    score    : Nat,   // 1-100
    feedback : Text,
  ) : async Result.Result<(), Error> {
    switch (findWork(workId)) {
      case (#err e) #err(e);
      case (#ok w) {
        if (w.status != #Submitted and w.status != #InDispute) {
          return #err(#InvalidState("Work is not under review"))
        };
        // Verify caller is one of the assigned reviewers
        let isReviewer = Array.find<Principal>(w.reviewers, func(r) { Principal.equal(r, msg.caller) });
        if (Option.isNull(isReviewer)) return #err(#Unauthorized("Not a designated reviewer"));
        if (hasReviewed(w.reviews, msg.caller)) return #err(#AlreadyExists("Already reviewed"));
        if (score < 1 or score > 100) return #err(#InvalidInput("Score must be 1-100"));

        let review : T.ReviewResult = {
          reviewer  = msg.caller;
          approved  = approved;
          score     = score;
          feedback  = feedback;
          timestamp = Time.now();
        };
        let newReviews = Array.append(w.reviews, [review]);
        let approvals  = countApprovals(newReviews);

        // Check if threshold met
        if (approvals >= stableParams.reviewThreshold) {
          // Trigger completion asynchronously
          let updatedWork = { w with reviews = newReviews; status = #Completed; completedAt = ?Time.now() };
          works.put(workId, updatedWork);
          ignore _onWorkCompleted(updatedWork);
        } else {
          works.put(workId, { w with reviews = newReviews });
        };
        #ok(())
      };
    }
  };

  // ─── Dispute API ────────────────────────────────────────────────────────

  /// Raise a dispute during the 72-hour dispute window (spec §1-A-3)
  public shared(msg) func disputeWork(workId : WorkId) : async Result.Result<(), Error> {
    switch (findWork(workId)) {
      case (#err e) #err(e);
      case (#ok w) {
        switch (requireStatus(w, #Submitted)) {
          case (#err e) return #err(e);
          case (#ok _) {};
        };
        let now = Time.now();
        switch (w.disputeDeadline) {
          case null return #err(#InvalidState("No dispute deadline set"));
          case (?dl) {
            if (now > dl) return #err(#DeadlineExceeded("Dispute window has closed"));
          };
        };
        // Sponsor or any reviewer may raise a dispute
        let isSponsor   = Principal.equal(w.sponsor, msg.caller);
        let isReviewer  = Option.isSome(Array.find<Principal>(w.reviewers, func(r) { Principal.equal(r, msg.caller) }));
        if (not isSponsor and not isReviewer) return #err(#Unauthorized("Only sponsor or reviewer can dispute"));
        works.put(workId, { w with status = #InDispute });
        #ok(())
      };
    }
  };

  /// Resolve a dispute. Admin / governance oracle marks final outcome.
  public shared(msg) func resolveDispute(workId : WorkId, approveDelivery : Bool) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin / governance oracle"));
    switch (findWork(workId)) {
      case (#err e) #err(e);
      case (#ok w) {
        switch (requireStatus(w, #InDispute)) {
          case (#err e) return #err(e);
          case (#ok _) {};
        };
        if (approveDelivery) {
          let completedWork = { w with status = #Completed; completedAt = ?Time.now() };
          works.put(workId, completedWork);
          ignore _onWorkCompleted(completedWork);
        } else {
          works.put(workId, { w with status = #Cancelled });
        };
        #ok(())
      };
    }
  };

  /// Mark expired work units (called by a scheduler or any caller)
  public shared func expireWork(workId : WorkId) : async Result.Result<(), Error> {
    switch (findWork(workId)) {
      case (#err e) #err(e);
      case (#ok w) {
        if (w.status != #Open and w.status != #InProgress) {
          return #err(#InvalidState("Only Open or InProgress work can expire"))
        };
        if (Time.now() <= w.deadline) return #err(#InvalidState("Deadline not yet reached"));
        works.put(workId, { w with status = #Expired });
        #ok(())
      };
    }
  };

  // ─── Completion hook (inter-canister calls) ─────────────────────────────

  /// Called internally when work reaches Completed status.
  /// Triggers reward distribution and reputation award.
  func _onWorkCompleted(w : WorkUnit) : async () {
    // --- Award reputation to contributor ---
    switch (w.contributor) {
      case null {};
      case (?c) {
        let qualityScore = averageQuality(w.reviews);
        let repAward     = (qualityScore * w.difficulty * 10); // proportional to quality × difficulty
        let repActor = actor(Principal.toText(reputationCanister)) : actor {
          award : (Principal, Nat) -> async Result.Result<(), T.Error>
        };
        ignore await repActor.award(c, repAward);

        // --- Award smaller reputation to each reviewer ---
        let reviewerAward = 10; // flat reviewer incentive
        for (r in w.reviewers.vals()) {
          ignore await repActor.award(r, reviewerAward);
        };

        // --- Trigger reward distribution ---
        if (not Principal.equal(rewardCanister, Principal.fromText("aaaaa-aa"))) {
          let rwdActor = actor(Principal.toText(rewardCanister)) : actor {
            calculateAndDistribute : (T.WorkUnit) -> async Result.Result<T.RewardBreakdown, T.Error>
          };
          ignore await rwdActor.calculateAndDistribute(w);
        };
      };
    };
  };

  // ─── Query API ──────────────────────────────────────────────────────────

  public query func getWork(workId : WorkId) : async ?WorkUnit {
    works.get(workId)
  };

  public query func listWorks(status : ?T.WorkStatus) : async [WorkUnit] {
    let buf = Buffer.Buffer<WorkUnit>(works.size());
    for ((_, w) in works.entries()) {
      switch (status) {
        case null        { buf.add(w) };
        case (?s)        { if (w.status == s) buf.add(w) };
      };
    };
    Buffer.toArray(buf)
  };

  public query func getApplicants(workId : WorkId) : async [Principal] {
    switch (applicants.get(workId)) {
      case null  [];
      case (?buf) Buffer.toArray(buf);
    }
  };

  public query func workCount() : async Nat { works.size() };

  public query func getParams() : async T.SystemParameters { stableParams };
}
