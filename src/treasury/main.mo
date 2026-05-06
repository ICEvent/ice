/// Treasury canister
/// Holds and disburses community funds under multi-sig control,
/// transitioning to full DAO governance as the system matures (spec §4, §1-C).
///
/// Phase-1 (MVP): multi-sig (N-of-M admin set)
/// Phase-2: governance canister becomes the sole authority
import HashMap   "mo:base/HashMap";
import Iter      "mo:base/Iter";
import Array     "mo:base/Array";
import Buffer    "mo:base/Buffer";
import Principal "mo:base/Principal";
import Time      "mo:base/Time";
import Nat       "mo:base/Nat";
import Hash      "mo:base/Hash";
import Text      "mo:base/Text";
import Result    "mo:base/Result";
import Option    "mo:base/Option";

import T "../types/Types";

actor Treasury {

  // ─── Types ─────────────────────────────────────────────────────────────

  type WithdrawalRequest = T.WithdrawalRequest;
  type WithdrawalId      = T.WithdrawalId;
  type Error             = T.Error;

  // ─── Stable state ───────────────────────────────────────────────────────

  stable var stableWithdrawals   : [(WithdrawalId, WithdrawalRequest)] = [];
  stable var nextWithdrawalId    : WithdrawalId = 0;
  stable var stableBalance       : Nat = 0;      // ICP e8s held in reserve
  stable var stableAdmins        : [Principal]  = [];
  stable var stableMultisigThreshold : Nat = 2;  // default 2-of-N
  stable var stableGovernance    : Principal = Principal.fromText("aaaaa-aa");

  // ─── Runtime state ──────────────────────────────────────────────────────

  var withdrawals : HashMap.HashMap<WithdrawalId, WithdrawalRequest> =
    HashMap.fromIter(stableWithdrawals.vals(), stableWithdrawals.size(), Nat.equal, Hash.hash);

  var adminSet : HashMap.HashMap<Principal, Bool> =
    HashMap.HashMap<Principal, Bool>(16, Principal.equal, Principal.hash);

  // ─── Upgrade hooks ──────────────────────────────────────────────────────

  system func preupgrade() {
    stableWithdrawals := Iter.toArray(withdrawals.entries());
    stableAdmins      := Array.map<(Principal, Bool), Principal>(
      Iter.toArray(adminSet.entries()), func((p, _)) { p }
    );
  };

  system func postupgrade() {
    withdrawals := HashMap.fromIter(stableWithdrawals.vals(), stableWithdrawals.size(), Nat.equal, Hash.hash);
    for (p in stableAdmins.vals()) { adminSet.put(p, true) };
    stableWithdrawals := [];
    stableAdmins      := [];
  };

  // ─── Admin helpers ───────────────────────────────────────────────────────

  func isAdmin(caller : Principal) : Bool {
    switch (adminSet.get(caller)) { case (?true) true; case _ false }
  };

  func isGovernance(caller : Principal) : Bool {
    Principal.equal(caller, stableGovernance)
  };

  func isAuthorised(caller : Principal) : Bool {
    isAdmin(caller) or isGovernance(caller)
  };

  // ─── Bootstrap / admin API ──────────────────────────────────────────────

  /// Add a multi-sig admin. First call may be made by anyone if no admins yet.
  public shared(msg) func addAdmin(p : Principal) : async Result.Result<(), Error> {
    if (adminSet.size() > 0 and not isAdmin(msg.caller) and not isGovernance(msg.caller)) {
      return #err(#Unauthorized("Only existing admin or governance"))
    };
    adminSet.put(p, true);
    #ok(())
  };

  public shared(msg) func removeAdmin(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller) and not isGovernance(msg.caller)) {
      return #err(#Unauthorized("Only admin or governance"))
    };
    if (adminSet.size() <= stableMultisigThreshold) {
      return #err(#InvalidState("Cannot remove admin: would drop below threshold"))
    };
    adminSet.delete(p);
    #ok(())
  };

  public shared(msg) func setMultisigThreshold(n : Nat) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller) and not isGovernance(msg.caller)) {
      return #err(#Unauthorized("Only admin or governance"))
    };
    if (n == 0 or n > adminSet.size()) {
      return #err(#InvalidInput("Threshold must be between 1 and admin count"))
    };
    stableMultisigThreshold := n;
    #ok(())
  };

  public shared(msg) func setGovernance(p : Principal) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin"));
    stableGovernance := p;
    #ok(())
  };

  /// Deposit ICP into the treasury (in production: called after ICP ledger transfer)
  public shared(msg) func deposit(amount : Nat) : async Result.Result<(), Error> {
    // In production, verify an actual ICRC-1/ICP ledger transfer to this canister's account.
    // For MVP, any caller may register a deposit (trust-based stage 1).
    if (not isAuthorised(msg.caller)) return #err(#Unauthorized("Only admin or governance"));
    stableBalance += amount;
    #ok(())
  };

  // ─── Withdrawal workflow ────────────────────────────────────────────────

  /// Propose a treasury withdrawal. Admins or governance oracle may propose.
  public shared(msg) func proposeWithdrawal(to : Principal, amount : Nat, reason : Text) : async Result.Result<WithdrawalId, Error> {
    if (not isAuthorised(msg.caller)) return #err(#Unauthorized("Only admin or governance"));
    if (amount == 0) return #err(#InvalidInput("Amount must be > 0"));
    if (amount > stableBalance) return #err(#InsufficientFunds("Insufficient treasury balance"));

    let id = nextWithdrawalId;
    nextWithdrawalId += 1;
    let req : WithdrawalRequest = {
      id         = id;
      to         = to;
      amount     = amount;
      reason     = reason;
      status     = #Pending;
      approvals  = [msg.caller]; // proposer auto-approves
      createdAt  = Time.now();
      executedAt = null;
    };
    withdrawals.put(id, req);
    #ok(id)
  };

  /// Approve a pending withdrawal. Each admin may approve once.
  public shared(msg) func approveWithdrawal(withdrawalId : WithdrawalId) : async Result.Result<(), Error> {
    if (not isAdmin(msg.caller)) return #err(#Unauthorized("Only admin may approve"));
    switch (withdrawals.get(withdrawalId)) {
      case null return #err(#NotFound("Withdrawal " # Nat.toText(withdrawalId) # " not found"));
      case (?req) {
        if (req.status != #Pending) return #err(#InvalidState("Not pending"));
        // Idempotent
        if (Option.isSome(Array.find<Principal>(req.approvals, func(p) { Principal.equal(p, msg.caller) }))) {
          return #ok(())
        };
        let newApprovals = Array.append(req.approvals, [msg.caller]);
        if (newApprovals.size() >= stableMultisigThreshold) {
          withdrawals.put(withdrawalId, { req with approvals = newApprovals; status = #Approved });
        } else {
          withdrawals.put(withdrawalId, { req with approvals = newApprovals });
        };
        #ok(())
      };
    }
  };

  /// Execute an approved withdrawal. Sends funds to the recipient.
  /// In production: invokes ICP / ICRC-1 ledger transfer.
  public shared(msg) func executeWithdrawal(withdrawalId : WithdrawalId) : async Result.Result<(), Error> {
    if (not isAuthorised(msg.caller)) return #err(#Unauthorized("Not authorised"));
    switch (withdrawals.get(withdrawalId)) {
      case null return #err(#NotFound("Withdrawal not found"));
      case (?req) {
        if (req.status != #Approved) return #err(#InvalidState("Withdrawal is not approved"));
        if (req.amount > stableBalance) return #err(#InsufficientFunds("Balance changed since proposal"));
        stableBalance -= req.amount;
        withdrawals.put(withdrawalId, { req with status = #Executed; executedAt = ?Time.now() });
        // TODO production: await ICP_ledger.transfer({ to = req.to; amount = req.amount; ... })
        #ok(())
      };
    }
  };

  /// Governance-gated direct execution (bypasses multi-sig, used after DAO vote)
  public shared(msg) func governanceExecute(to : Principal, amount : Nat, reason : Text) : async Result.Result<(), Error> {
    if (not isGovernance(msg.caller)) return #err(#Unauthorized("Only governance canister"));
    if (amount > stableBalance) return #err(#InsufficientFunds("Insufficient balance"));
    stableBalance -= amount;
    let id = nextWithdrawalId;
    nextWithdrawalId += 1;
    withdrawals.put(id, {
      id         = id;
      to         = to;
      amount     = amount;
      reason     = reason;
      status     = #Executed;
      approvals  = [msg.caller];
      createdAt  = Time.now();
      executedAt = ?Time.now();
    });
    #ok(())
  };

  // ─── Query API ──────────────────────────────────────────────────────────

  public query func getBalance() : async Nat { stableBalance };

  public query func getWithdrawal(id : WithdrawalId) : async ?WithdrawalRequest {
    withdrawals.get(id)
  };

  public query func listWithdrawals(status : ?T.WithdrawalStatus) : async [WithdrawalRequest] {
    let buf = Buffer.Buffer<WithdrawalRequest>(withdrawals.size());
    for ((_, req) in withdrawals.entries()) {
      switch (status) {
        case null    { buf.add(req) };
        case (?s)    { if (req.status == s) buf.add(req) };
      };
    };
    Buffer.toArray(buf)
  };

  public query func getAdmins() : async [Principal] {
    Array.map<(Principal, Bool), Principal>(
      Iter.toArray(adminSet.entries()), func((p, _)) { p }
    )
  };

  public query func getThreshold() : async Nat { stableMultisigThreshold };
}
