/// Types.mo
/// Shared type definitions for the ICE Collaboration Network.
/// All canisters import from this module to guarantee type compatibility
/// across inter-canister calls.
module {

  // ─────────────────────────────────────────────────────────────────────────
  // Primitive aliases
  // ─────────────────────────────────────────────────────────────────────────

  /// Unique identifier for a work unit (Task / Project / Event / Service / Data)
  public type WorkId = Nat;

  /// Unique identifier for a governance proposal
  public type ProposalId = Nat;

  /// Unique identifier for a vesting schedule
  public type VestingId = Nat;

  /// Unique identifier for a treasury withdrawal request
  public type WithdrawalId = Nat;

  // ─────────────────────────────────────────────────────────────────────────
  // Work layer
  // ─────────────────────────────────────────────────────────────────────────

  /// Supported work-unit categories (see spec §1-A-1)
  public type WorkType = {
    #Task;        // Discrete deliverable with deadline & budget
    #Project;     // Multi-task milestone-based work
    #Event;       // Online/offline event organisation & execution
    #Service;     // Skill-based services (design, dev, translation …)
    #DataContent; // Data annotation, knowledge docs, shared content
  };

  /// Lifecycle states of a work unit
  public type WorkStatus = {
    #Open;        // Accepting contributor applications
    #InProgress;  // Assigned, contributor working
    #Submitted;   // Delivery hash submitted, awaiting review
    #InDispute;   // Dispute raised during dispute window
    #Completed;   // Accepted by reviewers, reward distributed
    #Cancelled;   // Sponsor cancelled before completion
    #Expired;     // Deadline elapsed without submission
  };

  /// A single reviewer's assessment of a submitted work unit
  public type ReviewResult = {
    reviewer  : Principal;
    approved  : Bool;
    score     : Nat;    // 1-100 quality score
    feedback  : Text;
    timestamp : Int;    // nanoseconds since Unix epoch
  };

  /// Core work-unit record stored in WorkRegistry
  public type WorkUnit = {
    id              : WorkId;
    workType        : WorkType;
    sponsor         : Principal;
    title           : Text;
    description     : Text;
    requirements    : Text;
    budget          : Nat;        // stablecoin amount (e8s)
    rewardToken     : Nat;        // incentive-token amount (e8s)
    deadline        : Int;        // nanosecond timestamp
    difficulty      : Nat;        // 1-10 difficulty rating set by sponsor
    status          : WorkStatus;
    contributor     : ?Principal;
    reviewers       : [Principal];
    reviews         : [ReviewResult];
    deliveryHash    : ?Text;      // IPFS / Arweave CID
    deliveredAt     : ?Int;
    completedAt     : ?Int;
    disputeDeadline : ?Int;       // deliveredAt + disputePeriod
    createdAt       : Int;
  };

  // ─────────────────────────────────────────────────────────────────────────
  // Reward layer
  // ─────────────────────────────────────────────────────────────────────────

  /// Breakdown of a calculated reward (spec §1-B-2)
  /// reward = base × qualityCoeff × difficultyCoeff × timelinessCoeff × collaborationCoeff
  /// Split: 70 % stablecoin / 20 % token / 10 % reputation points
  public type RewardBreakdown = {
    workId                  : WorkId;
    contributor             : Principal;
    baseAmount              : Nat;  // stablecoin budget used as base
    stablecoinAmount        : Nat;  // 70 % of effective reward
    tokenAmount             : Nat;  // 20 % of effective reward (vested)
    reputationAmount        : Nat;  // 10 % expressed as reputation points
    qualityMultiplier       : Nat;  // × 100 (e.g. 110 = 1.10)
    difficultyMultiplier    : Nat;  // × 100
    timelinessMultiplier    : Nat;  // × 100
    collaborationMultiplier : Nat;  // × 100
    calculatedAt            : Int;
  };

  /// Linear vesting schedule for incentive tokens (spec §1-B-3)
  public type VestingSchedule = {
    id              : VestingId;
    beneficiary     : Principal;
    totalAmount     : Nat;    // tokens granted
    releasedAmount  : Nat;    // tokens already claimed
    startTime       : Int;
    cliffDuration   : Int;    // nanoseconds (tokens locked until cliff)
    vestingDuration : Int;    // nanoseconds for full linear vesting
    lastReleaseTime : Int;
  };

  // ─────────────────────────────────────────────────────────────────────────
  // Governance layer
  // ─────────────────────────────────────────────────────────────────────────

  /// What a proposal intends to change (spec §1-C-1)
  public type ProposalType = {
    #BudgetApproval    : { projectId : Nat;    amount      : Nat  };
    #ParameterChange   : { key       : Text;   value       : Nat  };
    #ProtocolUpgrade   : { description : Text };
    #ArbitrationRule   : { ruleKey   : Text;   ruleValue   : Text };
    #TreasuryWithdrawal: { to        : Principal; amount   : Nat  };
  };

  /// Proposal lifecycle states
  public type ProposalStatus = {
    #Active;    // Voting open
    #Succeeded; // Quorum + approval met, waiting for timelock
    #Defeated;  // Vote failed
    #Executed;  // Timelock elapsed, actions performed
    #Cancelled; // Proposer withdrew before end
    #Expired;   // Voting window closed without quorum
  };

  /// A single cast vote (weight is quadratic: √reputation)
  public type Vote = {
    voter     : Principal;
    support   : Bool;
    weight    : Nat;    // √reputation, scaled ×1000 to preserve precision
    timestamp : Int;
  };

  /// Full proposal record stored in Governance
  public type Proposal = {
    id           : ProposalId;
    proposer     : Principal;
    title        : Text;
    description  : Text;
    proposalType : ProposalType;
    status       : ProposalStatus;
    forVotes     : Nat;
    againstVotes : Nat;
    startTime    : Int;
    endTime      : Int;     // startTime + votingPeriod
    timelockEnd  : ?Int;    // set when Succeeded
    executedAt   : ?Int;
    votes        : [Vote];
    createdAt    : Int;
  };

  // ─────────────────────────────────────────────────────────────────────────
  // Treasury
  // ─────────────────────────────────────────────────────────────────────────

  /// Status of a treasury withdrawal request
  public type WithdrawalStatus = {
    #Pending;   // Awaiting approvals
    #Approved;  // Approval threshold met, ready to execute
    #Executed;  // Funds transferred
    #Rejected;  // Rejected by governance
  };

  /// A multi-sig (or governance-gated) withdrawal request
  public type WithdrawalRequest = {
    id        : WithdrawalId;
    to        : Principal;
    amount    : Nat;
    reason    : Text;
    status    : WithdrawalStatus;
    approvals : [Principal];
    createdAt : Int;
    executedAt: ?Int;
  };

  // ─────────────────────────────────────────────────────────────────────────
  // System parameters (tunable by governance)
  // ─────────────────────────────────────────────────────────────────────────

  /// All protocol-level knobs; defaults match the spec §5 initial values
  public type SystemParameters = {
    reviewerCount           : Nat;  // required reviewers (default 3)
    reviewThreshold         : Nat;  // approvals needed   (default 2)
    disputePeriodNs         : Int;  // nanoseconds        (default 72 h)
    stablecoinRatioBps      : Nat;  // basis pts of 10000 (default 7000)
    tokenRatioBps           : Nat;  // basis pts          (default 2000)
    reputationRatioBps      : Nat;  // basis pts          (default 1000)
    reputationDecayPerMille : Nat;  // per month ‰        (default 10 = 1%)
    proposalThresholdBps    : Nat;  // % of total rep     (default 100 = 1%)
    quorumBps               : Nat;  // % of total rep     (default 2000 = 20%)
    approvalThresholdBps    : Nat;  // % of cast votes    (default 6000 = 60%)
    votingPeriodNs          : Int;  // nanoseconds        (default 7 days)
    timelockDelayNs         : Int;  // nanoseconds        (default 2 days)
    delegationCapBps        : Nat;  // max delegated % of total  (default 500 = 5%)
    cliffDurationNs         : Int;  // token vesting cliff       (default 90 days)
    vestingDurationNs       : Int;  // full vesting length       (default 365 days)
    slashingPenaltyBps      : Nat;  // reputation slash %  (default 2000 = 20%)
    minAccountAgeNs         : Int;  // anti-Sybil gate     (default 7 days)
  };

  // ─────────────────────────────────────────────────────────────────────────
  // Error taxonomy
  // ─────────────────────────────────────────────────────────────────────────

  public type Error = {
    #NotFound              : Text;
    #Unauthorized          : Text;
    #InvalidState          : Text;
    #InvalidInput          : Text;
    #InsufficientFunds     : Text;
    #InsufficientReputation: Text;
    #AlreadyExists         : Text;
    #DisputePeriodActive   : Text;
    #DeadlineExceeded      : Text;
    #TimelockActive        : Text;
    #QuorumNotMet          : Text;
  };

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Default system parameters (spec §5)
  public let defaultParams : SystemParameters = {
    reviewerCount           = 3;
    reviewThreshold         = 2;
    disputePeriodNs         = 259_200_000_000_000;   // 72 h in ns
    stablecoinRatioBps      = 7_000;
    tokenRatioBps           = 2_000;
    reputationRatioBps      = 1_000;
    reputationDecayPerMille = 10;
    proposalThresholdBps    = 100;
    quorumBps               = 2_000;
    approvalThresholdBps    = 6_000;
    votingPeriodNs          = 604_800_000_000_000;   // 7 days in ns
    timelockDelayNs         = 172_800_000_000_000;   // 2 days in ns
    delegationCapBps        = 500;
    cliffDurationNs         = 7_776_000_000_000_000; // 90 days in ns
    vestingDurationNs       = 31_536_000_000_000_000;// 365 days in ns
    slashingPenaltyBps      = 2_000;
    minAccountAgeNs         = 604_800_000_000_000;   // 7 days in ns
  };

  /// Integer square-root (floor), used for quadratic vote weights.
  /// Returns ⌊√n⌋.
  public func isqrt(n : Nat) : Nat {
    if (n == 0) return 0;
    var x = n;
    var y = (x + 1) / 2;
    while (y < x) {
      x := y;
      y := (x + n / x) / 2;
    };
    x
  };

  // ─── Time constants (nanoseconds) ────────────────────────────────────────

  /// One day expressed in nanoseconds
  public let DAY_IN_NS : Int = 86_400_000_000_000;

  /// Thirty days expressed in nanoseconds (used for monthly decay)
  public let MONTH_IN_NS : Int = 2_592_000_000_000_000;
}
