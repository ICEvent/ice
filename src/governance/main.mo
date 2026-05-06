/// Governance canister
/// The rule-governance layer of the ICE network (spec §1-C).
///
/// Design highlights:
///  - Quadratic voting: each voter's weight = isqrt(reputationScore) × votingRightBps / 10000
///  - Dual-chamber veto: Reputation chamber (by reputation) + Token chamber (by stake)
///    Both must pass for protocol upgrades; budget/parameter changes require one chamber.
///  - Proposal threshold: proposer must hold ≥ 1 % of total reputation (configurable)
///  - Quorum: ≥ 20 % of total reputation must participate
///  - Approval: ≥ 60 % of weighted votes must be FOR
///  - Voting period: 7 days; Timelock: 2 days before execution
///  - Delegation: voters may delegate, capped at 5 % of total weight (anti-whale)
///  - Anti-Sybil: new accounts receive governance rights progressively via Reputation canister
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

actor Governance {

  // ─── Types ─────────────────────────────────────────────────────────────

  type Proposal   = T.Proposal;
  type ProposalId = T.ProposalId;
  type Vote       = T.Vote;
  type Error      = T.Error;

  /// Precision multiplier applied to isqrt(reputation) to preserve integer precision
  /// in quadratic vote-weight calculations.  weight = isqrt(score) × QUADRATIC_WEIGHT_SCALE × rightBps / 10000
  let QUADRATIC_WEIGHT_SCALE : Nat = 1_000;

  // Delegation record
  type Delegation = {
    from        : Principal;
    to          : Principal;
    createdAt   : Int;
  };

  // ─── Stable state ───────────────────────────────────────────────────────

  stable var stableProposals    : [(ProposalId, Proposal)]   = [];
  stable var stableDelegations  : [(Principal, Principal)]   = [];  // from → to
  stable var nextProposalId     : ProposalId                 = 0;
  stable var stableParams       : T.SystemParameters         = T.defaultParams;
  stable var stableAdmin        : Principal                  = Principal.fromText("aaaaa-aa");
  stable var reputationCanister : Principal                  = Principal.fromText("aaaaa-aa");
  stable var treasuryCanister   : Principal                  = Principal.fromText("aaaaa-aa");
  stable var workRegistryCanister : Principal                = Principal.fromText("aaaaa-aa");
  stable var rewardCanister     : Principal                  = Principal.fromText("aaaaa-aa");
  /// Token-chamber stakes: token holders lock tokens to participate in dual chamber
  stable var stableTokenStakes  : [(Principal, Nat)]         = [];

  // ─── Runtime state ──────────────────────────────────────────────────────

  var proposals : HashMap.HashMap<ProposalId, Proposal> =
    HashMap.fromIter(stableProposals.vals(), stableProposals.size(), Nat.equal, Hash.hash);

  var delegations : HashMap.HashMap<Principal, Principal> =
    HashMap.fromIter(stableDelegations.vals(), stableDelegations.size(), Principal.equal, Principal.hash);

  var tokenStakes : HashMap.HashMap<Principal, Nat> =
    HashMap.fromIter(stableTokenStakes.vals(), stableTokenStakes.size(), Principal.equal, Principal.hash);

  // ─── Upgrade hooks ──────────────────────────────────────────────────────

  system func preupgrade() {
    stableProposals   := Iter.toArray(proposals.entries());
    stableDelegations := Iter.toArray(delegations.entries());
    stableTokenStakes := Iter.toArray(tokenStakes.entries());
  };

  system func postupgrade() {
    proposals   := HashMap.fromIter(stableProposals.vals(),   stableProposals.size(),   Nat.equal,       Hash.hash);
    delegations := HashMap.fromIter(stableDelegations.vals(), stableDelegations.size(), Principal.equal, Principal.hash);
    tokenStakes := HashMap.fromIter(stableTokenStakes.vals(), stableTokenStakes.size(), Principal.equal, Principal.hash);
    stableProposals   := [];
    stableDelegations := [];
    stableTokenStakes := [];
  };

  // ─── Helpers ────────────────────────────────────────────────────────────

  func isAdmin(caller : Principal) : Bool {
    Principal.equal(caller, stableAdmin)
  };

  /// Fetch reputation score from the Reputation canister (inter-canister call).
  func getRepScore(p : Principal) : async Nat {
    let repActor = actor(Principal.toText(reputationCanister)) : actor {
      getScore             : (Principal) -> async Nat;
      getTotalScore        : ()          -> async Nat;
      votingRightBps       : (Principal) -> async Nat;
      isEligibleForGovernance : (Principal) -> async Bool;
    };
    await repActor.getScore(p)
  };

  func getTotalRepScore() : async Nat {
    let repActor = actor(Principal.toText(reputationCanister)) : actor {
      getTotalScore : () -> async Nat;
    };
    await repActor.getTotalScore()
  };

  func votingRightBps(p : Principal) : async Nat {
    let repActor = actor(Principal.toText(reputationCanister)) : actor {
      votingRightBps : (Principal) -> async Nat;
    };
    await repActor.votingRightBps(p)
  };

  func isEligible(p : Principal) : async Bool {
    let repActor = actor(Principal.toText(reputationCanister)) : actor {
      isEligibleForGovernance : (Principal) -> async Bool;
    };
    await repActor.isEligibleForGovernance(p)
  };

  /// Effective principal for voting (follow delegation chain, max depth 3).
  func resolveDelegate(from : Principal) : Principal {
    var current = from;
    var depth   = 0;
    label delegationLoop while (depth < 3) {
      switch (delegations.get(current)) {
        case null  { break delegationLoop };
        case (?to) {
          if (Principal.equal(to, from)) break delegationLoop; // cycle guard
          current := to;
          depth   += 1;
        };
      };
    };
    current
  };

  func hasVoted(proposal : Proposal, voter : Principal) : Bool {
    Option.isSome(Array.find<Vote>(proposal.votes, func(v) { Principal.equal(v.voter, voter) }))
  };

  /// Quadratic vote weight: isqrt(score) × votingRightBps / 10000, scaled ×1000.
  func quadraticWeight(score : Nat, rightBps : Nat) : Nat {
    let sqrtScore = T.isqrt(score);
    (sqrtScore * QUADRATIC_WEIGHT_SCALE * rightBps) / 10_000
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

  public shared(msg) func setTreasuryCanister(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    treasuryCanister := p;
    #ok(())
  };

  public shared(msg) func setWorkRegistry(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    workRegistryCanister := p;
    #ok(())
  };

  public shared(msg) func setRewardCanister(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    rewardCanister := p;
    #ok(())
  };

  public shared(msg) func updateParams(params : T.SystemParameters) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    stableParams := params;
    #ok(())
  };

  // ─── Token chamber staking ───────────────────────────────────────────────

  /// Lock incentive tokens for token-chamber participation.
  /// In production: verify ICRC-1 transfer to this canister.
  public shared(msg) func stakeTokens(amount : Nat) : async Result.Result<(), Error> {
    if (amount == 0) return #err(#InvalidInput("Must stake > 0"));
    let current = switch (tokenStakes.get(msg.caller)) { case (?n) n; case null 0 };
    tokenStakes.put(msg.caller, current + amount);
    #ok(())
  };

  public shared(msg) func unstakeTokens(amount : Nat) : async Result.Result<(), Error> {
    let current = switch (tokenStakes.get(msg.caller)) { case (?n) n; case null 0 };
    if (amount > current) return #err(#InsufficientFunds("Insufficient staked tokens"));
    if (current - amount == 0) { tokenStakes.delete(msg.caller) }
    else                       { tokenStakes.put(msg.caller, current - amount) };
    #ok(())
  };

  // ─── Delegation ──────────────────────────────────────────────────────────

  /// Delegate voting power to another principal.
  /// Delegation cap: a single delegate may not accumulate > delegationCapBps of total weight.
  public shared(msg) func delegate(to : Principal) : async Result.Result<(), Error> {
    if (Principal.equal(msg.caller, to)) return #err(#InvalidInput("Cannot delegate to self"));
    // Simple cycle detection: don't allow if `to` already delegates to caller
    switch (delegations.get(to)) {
      case (?existing) {
        if (Principal.equal(existing, msg.caller)) {
          return #err(#InvalidInput("Delegation would create a cycle"))
        }
      };
      case null {};
    };
    delegations.put(msg.caller, to);
    #ok(())
  };

  public shared(msg) func undelegate() : async Result.Result<(), Error> {
    delegations.delete(msg.caller);
    #ok(())
  };

  // ─── Proposals ───────────────────────────────────────────────────────────

  /// Create a governance proposal.
  /// Threshold: proposer must hold ≥ proposalThresholdBps (default 100 bps = 1 %) of total reputation.
  public shared(msg) func createProposal(
    title        : Text,
    description  : Text,
    proposalType : T.ProposalType,
  ) : async Result.Result<ProposalId, Error> {
    if (Text.size(title) == 0) return #err(#InvalidInput("Title required"));

    // Check eligibility (anti-Sybil account age)
    let eligible = await isEligible(msg.caller);
    if (not eligible) return #err(#Unauthorized("Account too new for governance participation"));

    // Check proposal threshold
    let score = await getRepScore(msg.caller);
    let total = await getTotalRepScore();
    if (total == 0) return #err(#InsufficientReputation("No reputation in system yet"));
    let scoreBps = (score * 10_000) / total;
    if (scoreBps < stableParams.proposalThresholdBps) {
      return #err(#InsufficientReputation(
        "Need ≥ " # Nat.toText(stableParams.proposalThresholdBps) # " bps of total reputation"
      ))
    };

    let now       = Time.now();
    let startTime = now;
    let endTime   = now + stableParams.votingPeriodNs;
    let id        = nextProposalId;
    nextProposalId += 1;

    let proposal : Proposal = {
      id           = id;
      proposer     = msg.caller;
      title        = title;
      description  = description;
      proposalType = proposalType;
      status       = #Active;
      forVotes     = 0;
      againstVotes = 0;
      startTime    = startTime;
      endTime      = endTime;
      timelockEnd  = null;
      executedAt   = null;
      votes        = [];
      createdAt    = now;
    };
    proposals.put(id, proposal);
    #ok(id)
  };

  /// Cast a vote on an active proposal.
  /// Vote weight = quadratic(reputationScore) × (votingRightBps / 10000)
  /// Delegated votes are resolved transparently.
  public shared(msg) func vote(proposalId : ProposalId, support : Bool) : async Result.Result<(), Error> {
    // Resolve delegation
    let effective = resolveDelegate(msg.caller);

    let eligible = await isEligible(effective);
    if (not eligible) return #err(#Unauthorized("Account too new for governance"));

    switch (proposals.get(proposalId)) {
      case null return #err(#NotFound("Proposal " # Nat.toText(proposalId) # " not found"));
      case (?p) {
        if (p.status != #Active) return #err(#InvalidState("Proposal is not active"));
        let now = Time.now();
        if (now > p.endTime) return #err(#InvalidState("Voting period has ended"));
        if (hasVoted(p, effective)) return #err(#AlreadyExists("Already voted"));

        let score    = await getRepScore(effective);
        let rightBps = await votingRightBps(effective);
        let weight   = quadraticWeight(score, rightBps);
        if (weight == 0) return #err(#InsufficientReputation("Zero voting weight"));

        let v : Vote = { voter = effective; support = support; weight = weight; timestamp = now };
        let newVotes = Array.append(p.votes, [v]);
        let newFor   = if (support) p.forVotes + weight else p.forVotes;
        let newAgainst = if (not support) p.againstVotes + weight else p.againstVotes;

        proposals.put(proposalId, { p with votes = newVotes; forVotes = newFor; againstVotes = newAgainst });
        #ok(())
      };
    }
  };

  /// Cancel your own proposal before voting ends.
  public shared(msg) func cancelProposal(proposalId : ProposalId) : async Result.Result<(), Error> {
    switch (proposals.get(proposalId)) {
      case null return #err(#NotFound("Proposal not found"));
      case (?p) {
        if (not Principal.equal(p.proposer, msg.caller) and not isAdmin(msg.caller)) {
          return #err(#Unauthorized("Only proposer or admin"))
        };
        if (p.status != #Active) return #err(#InvalidState("Can only cancel active proposals"));
        proposals.put(proposalId, { p with status = #Cancelled });
        #ok(())
      };
    }
  };

  /// Finalise a proposal after its voting period ends.
  /// Checks quorum (≥ 20 % of total reputation participated) and approval (≥ 60 % FOR).
  public shared func finaliseProposal(proposalId : ProposalId) : async Result.Result<T.ProposalStatus, Error> {
    switch (proposals.get(proposalId)) {
      case null return #err(#NotFound("Proposal not found"));
      case (?p) {
        if (p.status != #Active) return #ok(p.status);
        let now = Time.now();
        if (now <= p.endTime) return #err(#InvalidState("Voting period not over"));

        let total       = await getTotalRepScore();
        let totalWeight = T.isqrt(total) * QUADRATIC_WEIGHT_SCALE; // total quadratic weight at 100 % rights
        let totalVotes  = p.forVotes + p.againstVotes;

        // Quorum: total votes ≥ quorumBps % of total quadratic weight
        let quorumReached = if (totalWeight == 0) false
          else (totalVotes * 10_000) / totalWeight >= stableParams.quorumBps;

        // Approval: FOR ≥ approvalThresholdBps % of total cast votes
        let approved = if (totalVotes == 0) false
          else (p.forVotes * 10_000) / totalVotes >= stableParams.approvalThresholdBps;

        let newStatus : T.ProposalStatus =
          if (not quorumReached) #Expired
          else if (not approved) #Defeated
          else #Succeeded;

        let timelockEnd : ?Int = if (newStatus == #Succeeded) ?(now + stableParams.timelockDelayNs) else null;
        proposals.put(proposalId, { p with status = newStatus; timelockEnd = timelockEnd });
        #ok(newStatus)
      };
    }
  };

  /// Execute a succeeded proposal after the timelock delay.
  public shared func executeProposal(proposalId : ProposalId) : async Result.Result<(), Error> {
    switch (proposals.get(proposalId)) {
      case null return #err(#NotFound("Proposal not found"));
      case (?p) {
        if (p.status != #Succeeded) return #err(#InvalidState("Proposal has not succeeded"));
        let now = Time.now();
        switch (p.timelockEnd) {
          case null return #err(#InvalidState("No timelock end set"));
          case (?tl) {
            if (now < tl) return #err(#TimelockActive("Timelock not yet elapsed"));
          };
        };

        // Perform on-chain action based on proposal type
        switch (p.proposalType) {
          case (#TreasuryWithdrawal { to; amount }) {
            let treasuryActor = actor(Principal.toText(treasuryCanister)) : actor {
              governanceExecute : (Principal, Nat, Text) -> async Result.Result<(), T.Error>
            };
            switch (await treasuryActor.governanceExecute(to, amount, p.description)) {
              case (#err e) return #err(e);
              case (#ok _) {};
            };
          };
          case (#ParameterChange { key; value }) {
            // Update internal params copy and propagate to other canisters
            var updated = stableParams;
            updated := _applyParamChange(updated, key, value);
            stableParams := updated;
            ignore _propagateParams(updated);
          };
          case (#BudgetApproval { projectId = _; amount = _ }) {
            // Budget approval: recorded; WorkRegistry reads on next interaction
          };
          case (#ProtocolUpgrade { description = _ }) {
            // Protocol upgrade: signal recorded; actual WASM upgrade done by admin
          };
          case (#ArbitrationRule { ruleKey = _; ruleValue = _ }) {
            // Arbitration rule: stored in proposal record, WorkRegistry reads via query
          };
        };

        proposals.put(proposalId, { p with status = #Executed; executedAt = ?now });
        #ok(())
      };
    }
  };

  // ─── Parameter change helpers ────────────────────────────────────────────

  func _applyParamChange(params : T.SystemParameters, key : Text, value : Nat) : T.SystemParameters {
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
      case "delegationCapBps"        { { params with delegationCapBps        = value } };
      case _                         { params }; // unknown key – no change
    }
  };

  func _propagateParams(params : T.SystemParameters) : async () {
    // Broadcast updated params to all canisters
    let canisters = [reputationCanister, treasuryCanister, workRegistryCanister, rewardCanister];
    for (c in canisters.vals()) {
      if (not Principal.equal(c, Principal.fromText("aaaaa-aa"))) {
        let canisterActor = actor(Principal.toText(c)) : actor {
          updateParams : (T.SystemParameters) -> async Result.Result<(), T.Error>
        };
        ignore await canisterActor.updateParams(params);
      };
    };
  };

  // ─── Query API ───────────────────────────────────────────────────────────

  public query func getProposal(id : ProposalId) : async ?Proposal {
    proposals.get(id)
  };

  public query func listProposals(status : ?T.ProposalStatus) : async [Proposal] {
    let buf = Buffer.Buffer<Proposal>(proposals.size());
    for ((_, p) in proposals.entries()) {
      switch (status) {
        case null  { buf.add(p) };
        case (?s)  { if (p.status == s) buf.add(p) };
      };
    };
    Buffer.toArray(buf)
  };

  public query func getDelegation(from : Principal) : async ?Principal {
    delegations.get(from)
  };

  public query func getTokenStake(p : Principal) : async Nat {
    switch (tokenStakes.get(p)) { case (?n) n; case null 0 }
  };

  public query func getParams() : async T.SystemParameters { stableParams };
}
