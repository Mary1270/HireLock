// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract HireLockBase {
    enum Status { OPEN, PAYMENT_CLAIMED, ACTIVE, DELIVERED, COMPLETED, DISPUTED, REOPENED, RESOLVED, CANCELLED, EXPIRED, PAYOUT_PENDING, CHALLENGED }
    enum Verdict { NONE, CLIENT_WINS, FREELANCER_WINS, SPLIT, INSUFFICIENT_EVIDENCE }

    struct Freelancer {
        string handle;
        uint256 stake;
        uint256 locked;
        uint256 compensated;
        uint64 createdAt;
        uint32 gigsBound;
        uint32 completedVerified;
        uint32 completedAuto;
        uint32 disputesLost;
        uint32 disputesSplit;
        uint32 disputesWon;
        uint32 inconclusive;
        uint32 rejectedClaims;
        uint32 lapsed;
        uint32 activeGigs;
        uint32 uniqueClients;
        bool exists;
    }

    struct FreelancerInfo {
        address owner;
        string handle;
        uint256 stake;
        uint256 locked;
        uint256 available;
        uint256 maxCover;
        uint256 score;
        uint256 lockBps;
        uint8 level;
        bool trusted;
        uint256 compensated;
        uint32 gigsBound;
        uint32 completedVerified;
        uint32 completedAuto;
        uint32 disputesLost;
        uint32 disputesSplit;
        uint32 disputesWon;
        uint32 inconclusive;
        uint32 rejectedClaims;
        uint32 lapsed;
        uint32 activeGigs;
        uint32 uniqueClients;
    }

    struct Gig {
        uint256 id;
        address freelancer;
        address client;
        string scope;
        string feeText;
        string briefUrl;
        uint256 cover;
        uint256 lock;
        uint256 deliverySecs;
        Status status;
        uint64 createdAt;
        uint64 offerExpires;
        uint64 claimedAt;
        string paymentRef;
        uint64 boundAt;
        uint8 boundBy;
        uint64 deliveryDeadline;
        uint64 deliveredAt;
        string deliveryText;
        string deliveryUrl;
        uint32 rejections;
        string rejectReason;
        uint256 deposit;
        uint64 evidenceDeadline;
        bool reopened;
        uint8 evClient;
        uint8 evFreelancer;
        Verdict verdict;
        bytes32 reasonCode;
        string reason;
        uint256 compensation;
        uint256 fee;
        uint64 resolvedAt;
        bool paymentEvidenceReviewed;
        uint256 claimDeposit;
        uint256 pendingComp;
        uint64 unlockAt;
        bool challenged;
    }

    struct Evidence {
        bool byClient;
        string text;
        string url;
        bytes32 digest;
        uint64 at;
    }

    uint256 public constant MIN_STAKE = 0.005 ether;
    uint256 public constant VERIFIED_STAKE = 0.02 ether;
    uint256 public constant PREMIUM_STAKE = 0.05 ether;
    uint256 public constant MAX_COVER_STARTER = 0.002 ether;
    uint256 public constant MAX_COVER_VERIFIED = 0.01 ether;
    uint256 public constant MAX_COVER_PREMIUM = 0.04 ether;
    uint256 public constant MIN_COVER = 0.001 ether;
    uint256 public constant DISPUTE_DEPOSIT = 0.001 ether;
    uint256 public constant LOCK_BPS_NEW = 15000;
    uint256 public constant LOCK_BPS_TRUSTED = 12000;
    uint256 public constant FEE_BPS = 500;
    uint256 public constant TRUSTED_MIN_COMPLETED = 5;
    uint256 public constant TRUSTED_MIN_VERIFIED = 3;
    uint256 public constant PAIR_CREDIT_LIMIT = 3;
    uint256 public constant EVIDENCE_REOPEN_BONUS = 2;
    uint256 public constant TIMEOUT_CAP_BPS = 2500;
    uint256 public constant CLAIM_DEPOSIT = 0.001 ether;
    uint256 public constant TRUSTED_MIN_UNIQUE = 5;
    uint256 public constant MAX_EVIDENCE_PER_SIDE = 3;
    uint256 public constant MAX_DELIVERY_HOURS = 720;

    uint256 public immutable unit;
    uint256 public immutable offerWindow;
    uint256 public immutable confirmWindow;
    uint256 public immutable reviewWindow;
    uint256 public immutable evidenceWindow;
    uint256 public immutable reopenWindow;
    uint256 public immutable arbiterTimeout;
    uint256 public immutable payoutDelay;
    uint256 public immutable trustedMinAge;
    uint256 public immutable arbiterChangeDelay;

    address public owner;
    address public arbiter;
    address public pendingArbiter;
    uint256 public arbiterChangeAt;
    uint256 public treasury;
    uint256 public burned;
    uint256 public depositsHeld;
    uint256 public totalClaimable;
    uint256 public gigCount;

    mapping(address => Freelancer) private freelancers;
    mapping(bytes32 => address) private handleOwners;
    address[] private freelancerList;
    mapping(uint256 => Gig) private gigs;
    mapping(uint256 => Evidence[]) private evidences;
    mapping(address => uint256) public claimable;
    mapping(bytes32 => uint256) public pairCounts;
    mapping(bytes32 => bool) private rejectedClaim;
    mapping(uint256 => address) public disputeArbiter;


    uint256 private lockFlag = 1;

    event FreelancerRegistered(address indexed freelancer, string handle, uint256 stake);
    event StakeChanged(address indexed freelancer, uint256 stake);
    event GigCreated(uint256 indexed id, address indexed freelancer, uint256 cover);
    event GigStatus(uint256 indexed id, Status status);
    event EvidenceAdded(uint256 indexed id, bool byClient, bytes32 digest);
    event PayoutPending(uint256 indexed id, uint256 amount, uint64 unlockAt);
    event PayoutChallenged(uint256 indexed id);
    event Resolved(uint256 indexed id, Verdict verdict, bytes32 reasonCode, uint256 compensation, bool paymentEvidenceReviewed);
    event Reopened(uint256 indexed id, uint64 evidenceDeadline);
    event Claimed(address indexed who, uint256 amount);
    event ArbiterChanged(address indexed arbiter);
    event ArbiterProposed(address indexed arbiter, uint256 effectiveAt);
    event ArbiterProposalCancelled(address indexed arbiter);

    modifier nonReentrant() {
        require(lockFlag == 1, "reentrancy");
        lockFlag = 2;
        _;
        lockFlag = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(address arbiter_, uint256 unit_) {
        require(arbiter_ != address(0), "arbiter required");
        require(unit_ >= 1 && unit_ <= 86400, "bad unit");
        owner = msg.sender;
        arbiter = arbiter_;
        unit = unit_;
        offerWindow = 72 * unit_;
        confirmWindow = 24 * unit_;
        reviewWindow = 72 * unit_;
        evidenceWindow = 48 * unit_;
        reopenWindow = 24 * unit_;
        arbiterTimeout = 168 * unit_;
        payoutDelay = 168 * unit_;
        trustedMinAge = 336 * unit_;
        arbiterChangeDelay = 168 * unit_;
        emit ArbiterChanged(arbiter_);
    }

    function proposeArbiter(address a) external onlyOwner {
        require(a != address(0), "arbiter required");
        pendingArbiter = a;
        arbiterChangeAt = block.timestamp + arbiterChangeDelay;
        emit ArbiterProposed(a, arbiterChangeAt);
    }

    function cancelArbiterChange() external onlyOwner {
        require(pendingArbiter != address(0), "nothing proposed");
        emit ArbiterProposalCancelled(pendingArbiter);
        pendingArbiter = address(0);
        arbiterChangeAt = 0;
    }

    function applyArbiterChange() external {
        require(pendingArbiter != address(0), "nothing proposed");
        require(block.timestamp >= arbiterChangeAt, "change is still locked");
        arbiter = pendingArbiter;
        pendingArbiter = address(0);
        arbiterChangeAt = 0;
        emit ArbiterChanged(arbiter);
    }

    function transferOwnership(address a) external onlyOwner {
        require(a != address(0), "zero address");
        owner = a;
    }

    function _level(uint256 stake) internal pure returns (uint8) {
        if (stake >= PREMIUM_STAKE) return 2;
        if (stake >= VERIFIED_STAKE) return 1;
        return 0;
    }

    function _maxCover(uint8 level) internal pure returns (uint256) {
        if (level == 2) return MAX_COVER_PREMIUM;
        if (level == 1) return MAX_COVER_VERIFIED;
        return MAX_COVER_STARTER;
    }

    function _completed(Freelancer storage s) internal view returns (uint256) {
        return uint256(s.completedVerified) + uint256(s.completedAuto);
    }

    function _trusted(Freelancer storage s) internal view returns (bool) {
        return _completed(s) >= TRUSTED_MIN_COMPLETED && s.completedVerified >= TRUSTED_MIN_VERIFIED
            && s.uniqueClients >= TRUSTED_MIN_UNIQUE && block.timestamp >= uint256(s.createdAt) + trustedMinAge && s.disputesLost == 0;
    }

    function _lockBps(Freelancer storage s) internal view returns (uint256) {
        return _trusted(s) ? LOCK_BPS_TRUSTED : LOCK_BPS_NEW;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _score(Freelancer storage s) internal view returns (uint256) {
        int256 v = 500;
        v += 12 * int256(_min(s.completedVerified, 40));
        v += 4 * int256(_min(s.completedAuto, 40));
        v += 15 * int256(_min(s.disputesWon, 20));
        v -= 90 * int256(uint256(s.disputesLost));
        v -= 40 * int256(uint256(s.disputesSplit));
        v -= 25 * int256(uint256(s.inconclusive));
        v -= 15 * int256(uint256(s.lapsed));
        if (v < 0) return 0;
        if (v > 1000) return 1000;
        return uint256(v);
    }

    function _available(Freelancer storage s) internal view returns (uint256) {
        if (s.stake <= s.locked) return 0;
        uint256 free = s.stake - s.locked;
        return _min(_maxCover(_level(s.stake)), (free * 10000) / _lockBps(s));
    }

    function _validHandle(string memory h) internal pure returns (bool) {
        bytes memory b = bytes(h);
        if (b.length < 3 || b.length > 30) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x5f || c == 0x2e;
            if (!ok) return false;
        }
        return true;
    }

    function _isAlpha(bytes1 c) internal pure returns (bool) {
        return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    }

    function _isDigit(bytes1 c) internal pure returns (bool) {
        return c >= 0x30 && c <= 0x39;
    }

    function _validUrl(string memory u) internal pure returns (bool) {
        bytes memory b = bytes(u);
        if (b.length == 0) return true;
        if (b.length > 300 || b.length < 12) return false;
        bytes memory p = bytes("https://");
        for (uint256 i = 0; i < p.length; i++) {
            if (b[i] != p[i]) return false;
        }
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c <= 0x20 || c >= 0x7f || c == 0x5c) return false;
        }
        uint256 end = b.length;
        for (uint256 i = 8; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == 0x2f || c == 0x3f || c == 0x23) {
                end = i;
                break;
            }
        }
        if (end == 8) return false;
        return _validAuthority(b, 8, end);
    }

    function _validAuthority(bytes memory b, uint256 start, uint256 end) internal pure returns (bool) {
        uint256 hostEnd = end;
        for (uint256 i = start; i < end; i++) {
            bytes1 c = b[i];
            if (c == 0x40 || c == 0x5b || c == 0x5d) return false;
        }
        for (uint256 i = start; i < end; i++) {
            if (b[i] == 0x3a) {
                hostEnd = i;
                break;
            }
        }
        if (hostEnd < end) {
            if (end - hostEnd != 4) return false;
            if (b[hostEnd + 1] != 0x34 || b[hostEnd + 2] != 0x34 || b[hostEnd + 3] != 0x33) return false;
        }
        if (hostEnd == start) return false;
        uint256 labelStart = start;
        uint256 labels = 0;
        for (uint256 i = start; i <= hostEnd; i++) {
            bool atEnd = i == hostEnd;
            if (atEnd || b[i] == 0x2e) {
                if (i == labelStart) return false;
                labels++;
                if (atEnd) {
                    if (i - labelStart < 2) return false;
                    for (uint256 j = labelStart; j < i; j++) {
                        if (!_isAlpha(b[j])) return false;
                    }
                }
                labelStart = i + 1;
            } else if (!(_isAlpha(b[i]) || _isDigit(b[i]) || b[i] == 0x2d)) {
                return false;
            }
        }
        return labels >= 2;
    }

    function _len(string memory s, uint256 lo, uint256 hi) internal pure returns (bool) {
        uint256 n = bytes(s).length;
        return n >= lo && n <= hi;
    }

    function _credit(address who, uint256 amount) internal {
        if (amount == 0) return;
        claimable[who] += amount;
        totalClaimable += amount;
    }

    function _release(Gig storage d, Freelancer storage s) internal {
        s.locked -= d.lock;
        s.activeGigs -= 1;
    }

    function registerFreelancer(string calldata handle) external payable {
        require(!freelancers[msg.sender].exists, "already registered");
        require(_validHandle(handle), "invalid handle");
        bytes32 hk = keccak256(bytes(handle));
        require(handleOwners[hk] == address(0), "handle taken");
        require(msg.value >= MIN_STAKE, "stake below minimum");
        Freelancer storage s = freelancers[msg.sender];
        s.exists = true;
        s.handle = handle;
        s.stake = msg.value;
        s.createdAt = uint64(block.timestamp);
        handleOwners[hk] = msg.sender;
        freelancerList.push(msg.sender);
        emit FreelancerRegistered(msg.sender, handle, msg.value);
    }

    function addStake() external payable {
        Freelancer storage s = freelancers[msg.sender];
        require(s.exists, "not a freelancer");
        require(msg.value > 0, "no value");
        s.stake += msg.value;
        emit StakeChanged(msg.sender, s.stake);
    }

    function withdrawStake(uint256 amount) external {
        Freelancer storage s = freelancers[msg.sender];
        require(s.exists, "not a freelancer");
        require(amount > 0 && amount <= s.stake - s.locked, "exceeds free stake");
        s.stake -= amount;
        _credit(msg.sender, amount);
        emit StakeChanged(msg.sender, s.stake);
    }

    function createGig(
        string calldata scope,
        string calldata feeText,
        string calldata briefUrl,
        uint256 cover,
        uint256 deliveryHours
    ) external returns (uint256 id) {
        Freelancer storage s = freelancers[msg.sender];
        require(s.exists, "not a freelancer");
        require(_len(scope, 10, 600), "scope length");
        require(_len(feeText, 1, 80), "fee length");
        require(_validUrl(briefUrl), "bad url");
        require(cover >= MIN_COVER, "cover below minimum");
        require(cover <= _maxCover(_level(s.stake)), "cover above level cap");
        require(deliveryHours >= 1 && deliveryHours <= MAX_DELIVERY_HOURS, "delivery hours");
        uint256 lock = (cover * _lockBps(s)) / 10000;
        require(lock <= s.stake - s.locked, "not enough free stake");
        id = gigCount++;
        Gig storage d = gigs[id];
        d.id = id;
        d.freelancer = msg.sender;
        d.scope = scope;
        d.feeText = feeText;
        d.briefUrl = briefUrl;
        d.cover = cover;
        d.lock = lock;
        d.deliverySecs = deliveryHours * unit;
        d.status = Status.OPEN;
        d.createdAt = uint64(block.timestamp);
        d.offerExpires = uint64(block.timestamp + offerWindow);
        s.locked += lock;
        s.activeGigs += 1;
        emit GigCreated(id, msg.sender, cover);
    }

    function _gig(uint256 id) internal view returns (Gig storage d) {
        require(id < gigCount, "unknown gig");
        d = gigs[id];
    }

    function cancelGig(uint256 id) external {
        Gig storage d = _gig(id);
        require(msg.sender == d.freelancer, "only freelancer");
        require(d.status == Status.OPEN, "not open");
        _release(d, freelancers[d.freelancer]);
        d.status = Status.CANCELLED;
        d.resolvedAt = uint64(block.timestamp);
        emit GigStatus(id, d.status);
    }

    function expireOffer(uint256 id) external {
        Gig storage d = _gig(id);
        require(d.status == Status.OPEN, "not open");
        require(block.timestamp > d.offerExpires, "not expired");
        _release(d, freelancers[d.freelancer]);
        d.status = Status.EXPIRED;
        d.resolvedAt = uint64(block.timestamp);
        emit GigStatus(id, d.status);
    }

    function claimPayment(uint256 id, string calldata paymentRef) external payable {
        Gig storage d = _gig(id);
        require(msg.value == CLAIM_DEPOSIT, "wrong deposit");
        require(d.status == Status.OPEN, "not open");
        require(block.timestamp <= d.offerExpires, "offer expired");
        require(msg.sender != d.freelancer, "freelancer cannot buy own gig");
        require(_len(paymentRef, 5, 300), "payment ref length");
        require(!rejectedClaim[keccak256(abi.encodePacked(id, msg.sender))], "claim was rejected");
        d.client = msg.sender;
        d.claimDeposit = msg.value;
        depositsHeld += msg.value;
        d.paymentRef = paymentRef;
        d.claimedAt = uint64(block.timestamp);
        d.status = Status.PAYMENT_CLAIMED;
        emit GigStatus(id, d.status);
    }

    function _bind(Gig storage d, uint8 by) internal {
        d.status = Status.ACTIVE;
        d.boundAt = uint64(block.timestamp);
        d.boundBy = by;
        d.deliveryDeadline = uint64(block.timestamp + d.deliverySecs);
        freelancers[d.freelancer].gigsBound += 1;
        emit GigStatus(d.id, d.status);
    }

    function respondPayment(uint256 id, bool accept, string calldata reason) external {
        Gig storage d = _gig(id);
        require(msg.sender == d.freelancer, "only freelancer");
        require(d.status == Status.PAYMENT_CLAIMED, "no claim");
        if (accept) {
            _bind(d, 1);
            return;
        }
        require(_len(reason, 5, 200), "reason length");
        freelancers[d.freelancer].rejectedClaims += 1;
        rejectedClaim[keccak256(abi.encodePacked(id, d.client))] = true;
        depositsHeld -= d.claimDeposit;
        burned += d.claimDeposit;
        d.claimDeposit = 0;
        d.rejections += 1;
        d.rejectReason = reason;
        d.client = address(0);
        d.paymentRef = "";
        d.claimedAt = 0;
        d.status = Status.OPEN;
        d.offerExpires = uint64(block.timestamp + offerWindow);
        emit GigStatus(id, d.status);
    }

    function bindByTimeout(uint256 id) external {
        Gig storage d = _gig(id);
        require(d.status == Status.PAYMENT_CLAIMED, "no claim");
        require(block.timestamp >= uint256(d.claimedAt) + confirmWindow, "freelancer still has time");
        _bind(d, 2);
    }

    function submitDelivery(uint256 id, string calldata text, string calldata url) external {
        Gig storage d = _gig(id);
        require(msg.sender == d.freelancer, "only freelancer");
        require(d.status == Status.ACTIVE, "not active");
        require(_len(text, 3, 1500), "text length");
        require(_validUrl(url), "bad url");
        d.deliveryText = text;
        d.deliveryUrl = url;
        d.deliveredAt = uint64(block.timestamp);
        d.status = Status.DELIVERED;
        emit GigStatus(id, d.status);
    }

    function _returnClaimDeposit(Gig storage d, bool toFreelancer) internal {
        uint256 dep = d.claimDeposit;
        if (dep == 0) return;
        d.claimDeposit = 0;
        depositsHeld -= dep;
        _credit(toFreelancer ? d.freelancer : d.client, dep);
    }

    function _inDispute(Gig storage d) internal view returns (bool) {
        return d.status == Status.DISPUTED || d.status == Status.REOPENED || d.status == Status.CHALLENGED;
    }

    function _credit_completion(Gig storage d, Freelancer storage s, bool verified) internal {
        bytes32 pair = keccak256(abi.encodePacked(d.freelancer, d.client));
        uint256 n = pairCounts[pair];
        if (d.cover >= MIN_COVER && n < PAIR_CREDIT_LIMIT) {
            pairCounts[pair] = n + 1;
            if (n == 0) s.uniqueClients += 1;
            if (verified) s.completedVerified += 1;
            else s.completedAuto += 1;
        }
    }

    function confirmDelivery(uint256 id) external {
        Gig storage d = _gig(id);
        require(msg.sender == d.client, "only client");
        require(d.status == Status.DELIVERED, "not delivered");
        Freelancer storage s = freelancers[d.freelancer];
        _release(d, s);
        _credit_completion(d, s, true);
        _returnClaimDeposit(d, false);
        d.status = Status.COMPLETED;
        d.resolvedAt = uint64(block.timestamp);
        emit GigStatus(id, d.status);
    }

    function finalizeGig(uint256 id) external {
        Gig storage d = _gig(id);
        Freelancer storage s = freelancers[d.freelancer];
        if (d.status == Status.DELIVERED) {
            require(block.timestamp > uint256(d.deliveredAt) + reviewWindow, "review window open");
            _release(d, s);
            _credit_completion(d, s, false);
            _returnClaimDeposit(d, false);
            d.status = Status.COMPLETED;
        } else if (d.status == Status.ACTIVE) {
            require(block.timestamp > uint256(d.deliveryDeadline) + reviewWindow, "dispute window open");
            _release(d, s);
            s.lapsed += 1;
            _returnClaimDeposit(d, false);
            d.status = Status.EXPIRED;
        } else {
            revert("cannot finalize");
        }
        d.resolvedAt = uint64(block.timestamp);
        emit GigStatus(id, d.status);
    }

    function _addEvidence(Gig storage d, bool byClient, string memory text, string memory url) internal {
        bytes32 digest = keccak256(abi.encodePacked(text, "\n", url));
        evidences[d.id].push(Evidence(byClient, text, url, digest, uint64(block.timestamp)));
        if (byClient) d.evClient += 1;
        else d.evFreelancer += 1;
        emit EvidenceAdded(d.id, byClient, digest);
    }

    function openDispute(uint256 id, string calldata claimText, string calldata url) external payable {
        Gig storage d = _gig(id);
        require(msg.sender == d.client, "only client");
        require(msg.value == DISPUTE_DEPOSIT, "wrong deposit");
        bool late = d.status == Status.ACTIVE && block.timestamp > d.deliveryDeadline
            && block.timestamp <= uint256(d.deliveryDeadline) + reviewWindow;
        bool mismatch = d.status == Status.DELIVERED && block.timestamp <= uint256(d.deliveredAt) + reviewWindow;
        require(late || mismatch, "not disputable now");
        require(_len(claimText, 10, 1500), "claim length");
        require(_validUrl(url), "bad url");
        d.deposit = msg.value;
        depositsHeld += msg.value;
        disputeArbiter[id] = arbiter;
        d.evidenceDeadline = uint64(block.timestamp + evidenceWindow);
        d.status = Status.DISPUTED;
        _addEvidence(d, true, claimText, url);
        emit GigStatus(id, d.status);
    }

    function submitEvidence(uint256 id, string calldata text, string calldata url) external {
        Gig storage d = _gig(id);
        require(_inDispute(d), "not in dispute");
        require(block.timestamp <= d.evidenceDeadline, "window closed");
        bool byClient = msg.sender == d.client;
        require(byClient || msg.sender == d.freelancer, "only parties");
        uint256 limit = MAX_EVIDENCE_PER_SIDE + (d.reopened ? EVIDENCE_REOPEN_BONUS : 0) + (d.challenged ? EVIDENCE_REOPEN_BONUS : 0);
        require((byClient ? d.evClient : d.evFreelancer) < limit, "evidence limit");
        require(_len(text, 5, 1500), "text length");
        require(_validUrl(url), "bad url");
        _addEvidence(d, byClient, text, url);
    }

    function resolveDispute(
        uint256 id,
        Verdict verdict,
        bytes32 reasonCode,
        string calldata reason,
        bool paymentEvidenceReviewed
    ) external {
        Gig storage d = _gig(id);
        require(msg.sender == disputeArbiter[id], "only arbiter");
        require(_inDispute(d), "not in dispute");
        require(block.timestamp > d.evidenceDeadline, "evidence window open");
        require(verdict != Verdict.NONE, "verdict required");
        require(bytes(reason).length <= 300, "reason too long");
        if (verdict == Verdict.INSUFFICIENT_EVIDENCE && !d.reopened && d.status != Status.CHALLENGED) {
            d.reopened = true;
            d.status = Status.REOPENED;
            d.evidenceDeadline = uint64(block.timestamp + reopenWindow);
            d.verdict = verdict;
            d.reasonCode = reasonCode;
            d.reason = reason;
            d.paymentEvidenceReviewed = paymentEvidenceReviewed;
            emit Reopened(id, d.evidenceDeadline);
            emit GigStatus(id, d.status);
            return;
        }
        if (d.boundBy != 1 && d.status != Status.CHALLENGED && (verdict == Verdict.CLIENT_WINS || verdict == Verdict.SPLIT)) {
            uint256 pending = _compFor(d, verdict, paymentEvidenceReviewed);
            d.status = Status.PAYOUT_PENDING;
            d.verdict = verdict;
            d.reasonCode = reasonCode;
            d.reason = reason;
            d.paymentEvidenceReviewed = paymentEvidenceReviewed;
            d.pendingComp = pending;
            d.unlockAt = uint64(block.timestamp + payoutDelay);
            emit PayoutPending(id, pending, d.unlockAt);
            emit GigStatus(id, d.status);
            return;
        }
        _settle(d, verdict, reasonCode, reason, paymentEvidenceReviewed);
    }

    function challengePayout(uint256 id, string calldata text, string calldata url) external {
        Gig storage d = _gig(id);
        require(msg.sender == d.freelancer, "only freelancer");
        require(d.status == Status.PAYOUT_PENDING, "no pending payout");
        require(block.timestamp < d.unlockAt, "challenge window closed");
        require(_len(text, 5, 1500), "text length");
        require(_validUrl(url), "bad url");
        d.reopened = true;
        _addEvidence(d, false, text, url);
        d.challenged = true;
        d.status = Status.CHALLENGED;
        d.pendingComp = 0;
        d.evidenceDeadline = uint64(block.timestamp + reopenWindow);
        emit PayoutChallenged(id);
        emit GigStatus(id, d.status);
    }

    function finalizePayout(uint256 id) external {
        Gig storage d = _gig(id);
        require(d.status == Status.PAYOUT_PENDING, "no pending payout");
        require(block.timestamp >= d.unlockAt, "payout is still locked");
        _settle(d, d.verdict, d.reasonCode, d.reason, d.paymentEvidenceReviewed);
    }

    function resolveTimeout(uint256 id) external {
        Gig storage d = _gig(id);
        require(_inDispute(d), "not in dispute");
        require(block.timestamp > uint256(d.evidenceDeadline) + arbiterTimeout, "arbiter still has time");
        _settle(d, Verdict.INSUFFICIENT_EVIDENCE, bytes32("ARBITER_TIMEOUT"), "Arbiter did not rule in time", false);
    }

    function _compFor(Gig storage d, Verdict verdict, bool reviewed) internal view returns (uint256 comp) {
        if (verdict == Verdict.CLIENT_WINS) comp = d.cover;
        else if (verdict == Verdict.SPLIT) comp = d.cover / 2;
        if (comp > 0 && d.boundBy != 1) {
            require(reviewed, "payment evidence not reviewed");
            comp = _min(comp, (d.cover * TIMEOUT_CAP_BPS) / 10000);
        }
    }

    function _settle(Gig storage d, Verdict verdict, bytes32 code, string memory reason, bool reviewed) internal {
        Freelancer storage s = freelancers[d.freelancer];
        uint256 comp = _compFor(d, verdict, reviewed);
        uint256 fee = (comp * FEE_BPS) / 10000;
        require(comp + fee <= d.lock, "payout exceeds lock");
        s.stake -= comp + fee;
        _release(d, s);
        treasury += fee;
        if (comp > 0) {
            _credit(d.client, comp);
            s.compensated += comp;
        }
        uint256 dep = d.deposit;
        depositsHeld -= dep;
        _returnClaimDeposit(d, verdict == Verdict.FREELANCER_WINS);
        d.pendingComp = 0;
        if (verdict == Verdict.FREELANCER_WINS) {
            _credit(d.freelancer, dep);
            s.disputesWon += 1;
        } else {
            _credit(d.client, dep);
            if (verdict == Verdict.CLIENT_WINS) s.disputesLost += 1;
            else if (verdict == Verdict.SPLIT) s.disputesSplit += 1;
            else s.inconclusive += 1;
        }
        d.verdict = verdict;
        d.reasonCode = code;
        d.reason = reason;
        d.paymentEvidenceReviewed = reviewed;
        d.compensation = comp;
        d.fee = fee;
        d.resolvedAt = uint64(block.timestamp);
        d.status = Status.RESOLVED;
        emit Resolved(d.id, verdict, code, comp, reviewed);
        emit GigStatus(d.id, d.status);
    }

    function claim() external nonReentrant {
        uint256 amt = claimable[msg.sender];
        require(amt > 0, "nothing to claim");
        claimable[msg.sender] = 0;
        totalClaimable -= amt;
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "transfer failed");
        emit Claimed(msg.sender, amt);
    }

    function collectFees() external onlyOwner {
        uint256 amt = treasury;
        require(amt > 0, "no fees");
        treasury = 0;
        _credit(owner, amt);
    }

    function getGig(uint256 id) external view returns (Gig memory) {
        require(id < gigCount, "unknown gig");
        return gigs[id];
    }

    function getEvidence(uint256 id) external view returns (Evidence[] memory) {
        return evidences[id];
    }

    function freelancerInfo(address who) public view returns (FreelancerInfo memory i) {
        Freelancer storage s = freelancers[who];
        i.owner = who;
        i.handle = s.handle;
        i.stake = s.stake;
        i.locked = s.locked;
        i.level = _level(s.stake);
        i.maxCover = _maxCover(i.level);
        i.available = s.exists ? _available(s) : 0;
        i.score = s.exists ? _score(s) : 0;
        i.lockBps = s.exists ? _lockBps(s) : LOCK_BPS_NEW;
        i.trusted = s.exists && _trusted(s);
        i.compensated = s.compensated;
        i.gigsBound = s.gigsBound;
        i.completedVerified = s.completedVerified;
        i.completedAuto = s.completedAuto;
        i.disputesLost = s.disputesLost;
        i.disputesSplit = s.disputesSplit;
        i.disputesWon = s.disputesWon;
        i.inconclusive = s.inconclusive;
        i.rejectedClaims = s.rejectedClaims;
        i.lapsed = s.lapsed;
        i.activeGigs = s.activeGigs;
        i.uniqueClients = s.uniqueClients;
    }

    function isFreelancer(address who) external view returns (bool) {
        return freelancers[who].exists;
    }

    function freelancerByHandle(string calldata handle) external view returns (address) {
        return handleOwners[keccak256(bytes(handle))];
    }

    function freelancerCount() external view returns (uint256) {
        return freelancerList.length;
    }

    function freelancerAt(uint256 i) external view returns (address) {
        return freelancerList[i];
    }

    function getCoverage(address who) external view returns (uint256) {
        Freelancer storage s = freelancers[who];
        return s.exists ? _available(s) : 0;
    }

    function isCovered(address who, uint256 amount) external view returns (bool) {
        Freelancer storage s = freelancers[who];
        return s.exists && amount <= _available(s);
    }

    function freelancerScore(address who) external view returns (uint256) {
        Freelancer storage s = freelancers[who];
        return s.exists ? _score(s) : 0;
    }

    function totalStakes() public view returns (uint256 t) {
        for (uint256 i = 0; i < freelancerList.length; i++) t += freelancers[freelancerList[i]].stake;
    }
}
