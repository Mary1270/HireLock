// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/HireLockBase.sol";

contract HireLockBaseTest is Test {
    HireLockBase hl;
    address owner = makeAddr("owner");
    address arbiter = makeAddr("arbiter");
    address freelancer = makeAddr("freelancer");
    address client = makeAddr("client");
    address stranger = makeAddr("stranger");
    uint256 constant U = 0.001 ether;
    uint256 constant H = 3600;

    function setUp() public {
        vm.prank(owner);
        hl = new HireLockBase(arbiter, H);
        vm.gig(freelancer, 10 ether);
        vm.gig(client, 10 ether);
        vm.gig(stranger, 10 ether);
    }

    function _register(uint256 stake) internal {
        vm.prank(freelancer);
        hl.registerFreelancer{value: stake}("shop_one");
    }

    function _gig(uint256 cover) internal returns (uint256 id) {
        vm.prank(freelancer);
        id = hl.createGig("Landing page design in Figma", "40 USD", "https://example.com/p/1", cover, 48);
    }

    function _bound(uint256 cover) internal returns (uint256 id) {
        _register(20 * U);
        id = _gig(cover);
        vm.prank(client);
        hl.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(freelancer);
        hl.respondPayment(id, true, "");
    }

    function _delivered(uint256 cover) internal returns (uint256 id) {
        id = _bound(cover);
        vm.prank(freelancer);
        hl.submitDelivery(id, "shipped with tracking", "https://example.com/t/1");
    }

    function _disputed(uint256 cover) internal returns (uint256 id) {
        id = _delivered(cover);
        vm.prank(client);
        hl.openDispute{value: U}(id, "parcel never arrived at all", "");
    }

    function _accounting() internal view {
        uint256 total = hl.totalStakes() + hl.totalClaimable() + hl.treasury() + hl.burned() + hl.depositsHeld();
        assertEq(address(hl).balance, total);
    }

    function test_register_and_level() public {
        _register(20 * U);
        HireLockBase.FreelancerInfo memory i = hl.freelancerInfo(freelancer);
        assertEq(uint256(i.level), 1);
        assertEq(i.handle, "shop_one");
        assertEq(hl.freelancerByHandle("shop_one"), freelancer);
        _accounting();
    }

    function test_register_rejects_bad_input() public {
        vm.prank(freelancer);
        vm.expectRevert("stake below minimum");
        hl.registerFreelancer{value: U}("shop_one");
        vm.prank(freelancer);
        vm.expectRevert("invalid handle");
        hl.registerFreelancer{value: 6 * U}("Bad Handle");
        _register(6 * U);
        vm.prank(stranger);
        vm.expectRevert("handle taken");
        hl.registerFreelancer{value: 6 * U}("shop_one");
    }

    function test_create_locks_stake_and_caps() public {
        _register(20 * U);
        _gig(4 * U);
        assertEq(hl.freelancerInfo(freelancer).locked, 6 * U);
        vm.prank(freelancer);
        vm.expectRevert("cover above level cap");
        hl.createGig("Another scope", "1", "", 11 * U, 5);
        vm.prank(freelancer);
        vm.expectRevert("bad url");
        hl.createGig("Another scope", "1", "http://x.com", 2 * U, 5);
        vm.prank(freelancer);
        vm.expectRevert("bad url");
        hl.createGig("Another scope", "1", "https://user:pw@x.com/a", 2 * U, 5);
    }

    function test_happy_path() public {
        uint256 id = _delivered(4 * U);
        vm.prank(client);
        hl.confirmDelivery(id);
        HireLockBase.FreelancerInfo memory i = hl.freelancerInfo(freelancer);
        assertEq(uint256(i.completedVerified), 1);
        assertEq(i.locked, 0);
        assertGt(i.score, 500);
        _accounting();
    }

    function test_reject_reopens_offer() public {
        _register(20 * U);
        uint256 id = _gig(4 * U);
        vm.prank(client);
        hl.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(freelancer);
        hl.respondPayment(id, false, "no money received");
        HireLockBase.Gig memory d = hl.getGig(id);
        assertEq(uint256(d.status), uint256(HireLockBase.Status.OPEN));
        assertEq(d.client, address(0));
        assertEq(uint256(hl.freelancerInfo(freelancer).rejectedClaims), 1);
    }

    function test_timeout_binding() public {
        _register(20 * U);
        uint256 id = _gig(4 * U);
        vm.prank(client);
        hl.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(stranger);
        vm.expectRevert("freelancer still has time");
        hl.bindByTimeout(id);
        vm.warp(block.timestamp + 24 * H);
        vm.prank(stranger);
        hl.bindByTimeout(id);
        assertEq(uint256(hl.getGig(id).status), uint256(HireLockBase.Status.ACTIVE));
    }

    function test_auto_finalize_and_lapse() public {
        uint256 id = _delivered(4 * U);
        vm.expectRevert("review window open");
        hl.finalizeGig(id);
        vm.warp(block.timestamp + 72 * H + 1);
        hl.finalizeGig(id);
        assertEq(uint256(hl.freelancerInfo(freelancer).completedAuto), 1);
    }

    function test_lapsed_when_nobody_acts() public {
        uint256 id = _bound(4 * U);
        vm.warp(block.timestamp + 48 * H + 72 * H + 1);
        hl.finalizeGig(id);
        HireLockBase.FreelancerInfo memory i = hl.freelancerInfo(freelancer);
        assertEq(uint256(i.lapsed), 1);
        assertEq(i.locked, 0);
    }

    function test_client_wins_pays_from_stake() public {
        uint256 id = _disputed(4 * U);
        vm.prank(freelancer);
        hl.submitEvidence(id, "I posted it yesterday", "https://example.com/t/1");
        vm.prank(arbiter);
        vm.expectRevert("evidence window open");
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "none", true);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(stranger);
        vm.expectRevert("only arbiter");
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("X"), "x", true);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "none", true);
        uint256 fee = (4 * U * 500) / 10000;
        assertEq(hl.claimable(client), 4 * U + U + U);
        assertEq(hl.treasury(), fee);
        assertEq(hl.freelancerInfo(freelancer).stake, 20 * U - 4 * U - fee);
        assertEq(hl.freelancerInfo(freelancer).locked, 0);
        _accounting();
        uint256 before = client.balance;
        vm.prank(client);
        hl.claim();
        assertEq(client.balance, before + 6 * U);
        vm.prank(owner);
        hl.collectFees();
        vm.prank(owner);
        hl.claim();
        _accounting();
    }

    function test_freelancer_wins_gets_deposit() public {
        uint256 id = _disputed(4 * U);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.FREELANCER_WINS, bytes32("WORK_MATCHES_BRIEF"), "ok", true);
        assertEq(hl.claimable(freelancer), 2 * U);
        assertEq(hl.claimable(client), 0);
        assertEq(uint256(hl.freelancerInfo(freelancer).disputesWon), 1);
        _accounting();
    }

    function test_split() public {
        uint256 id = _disputed(4 * U);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.SPLIT, bytes32("PARTIAL_OR_OFF_BRIEF"), "half", true);
        assertEq(hl.getGig(id).compensation, 2 * U);
        assertEq(hl.claimable(client), 4 * U);
        _accounting();
    }

    function test_insufficient_reopens_then_inconclusive() public {
        uint256 id = _disputed(4 * U);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "thin", true);
        assertEq(uint256(hl.getGig(id).status), uint256(HireLockBase.Status.REOPENED));
        vm.warp(block.timestamp + 24 * H + 1);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "thin", true);
        assertEq(hl.getGig(id).compensation, 0);
        assertEq(hl.claimable(client), 2 * U);
        assertEq(hl.freelancerInfo(freelancer).locked, 0);
        _accounting();
    }

    function test_arbiter_timeout_is_inconclusive() public {
        uint256 id = _disputed(4 * U);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.expectRevert("arbiter still has time");
        hl.resolveTimeout(id);
        vm.warp(block.timestamp + 168 * H + 1);
        hl.resolveTimeout(id);
        assertEq(hl.getGig(id).compensation, 0);
        assertEq(hl.claimable(client), 2 * U);
        _accounting();
    }

    function test_dispute_guards() public {
        uint256 id = _bound(4 * U);
        vm.prank(client);
        vm.expectRevert("not disputable now");
        hl.openDispute{value: U}(id, "too early to complain", "");
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(stranger);
        vm.expectRevert("only client");
        hl.openDispute{value: U}(id, "not my gig at all", "");
        vm.prank(client);
        vm.expectRevert("wrong deposit");
        hl.openDispute{value: U / 2}(id, "claim text long enough", "");
        vm.prank(client);
        vm.expectRevert("wrong deposit");
        hl.openDispute{value: 2 * U}(id, "claim text long enough", "");
        vm.prank(client);
        hl.openDispute{value: U}(id, "claim text long enough", "");
        _accounting();
    }

    function test_evidence_limit() public {
        uint256 id = _disputed(4 * U);
        vm.startPrank(client);
        hl.submitEvidence(id, "second piece of proof", "");
        hl.submitEvidence(id, "third piece of proof", "");
        vm.expectRevert("evidence limit");
        hl.submitEvidence(id, "fourth piece of proof", "");
        vm.stopPrank();
        assertEq(hl.getEvidence(id).length, 3);
        vm.prank(stranger);
        vm.expectRevert("only parties");
        hl.submitEvidence(id, "outsider text here", "");
    }

    function test_pair_credit_limit() public {
        _register(50 * U);
        for (uint256 k = 0; k < 5; k++) {
            vm.prank(freelancer);
            uint256 id = hl.createGig("Landing page design in Figma", "40 USD", "", 2 * U, 5);
            vm.prank(client);
            hl.claimPayment{value: U}(id, "bank ref 123456");
            vm.prank(freelancer);
            hl.respondPayment(id, true, "");
            vm.prank(freelancer);
            hl.submitDelivery(id, "shipped ok", "");
            vm.prank(client);
            hl.confirmDelivery(id);
        }
        HireLockBase.FreelancerInfo memory i = hl.freelancerInfo(freelancer);
        assertEq(uint256(i.completedVerified), 3);
        assertFalse(i.trusted);
    }

    function test_withdraw_limited_by_lock() public {
        _register(20 * U);
        _gig(4 * U);
        vm.prank(freelancer);
        vm.expectRevert("exceeds free stake");
        hl.withdrawStake(15 * U);
        vm.prank(freelancer);
        hl.withdrawStake(14 * U);
        vm.prank(freelancer);
        hl.claim();
        _accounting();
    }

    function test_only_owner_can_propose_arbiter() public {
        vm.prank(stranger);
        vm.expectRevert("only owner");
        hl.proposeArbiter(stranger);
        vm.prank(owner);
        hl.proposeArbiter(stranger);
        assertEq(hl.arbiter(), arbiter);
        assertEq(hl.pendingArbiter(), stranger);
    }

    function test_arbiter_change_is_timelocked() public {
        address other = makeAddr("other_arbiter");
        vm.prank(owner);
        hl.proposeArbiter(other);
        vm.expectRevert("change is still locked");
        hl.applyArbiterChange();
        vm.warp(block.timestamp + 168 * H);
        hl.applyArbiterChange();
        assertEq(hl.arbiter(), other);
        assertEq(hl.pendingArbiter(), address(0));
    }

    function test_arbiter_proposal_can_be_cancelled() public {
        vm.prank(owner);
        hl.proposeArbiter(stranger);
        vm.prank(owner);
        hl.cancelArbiterChange();
        vm.warp(block.timestamp + 168 * H);
        vm.expectRevert("nothing proposed");
        hl.applyArbiterChange();
    }

    function test_arbiter_change_does_not_affect_open_dispute() public {
        uint256 id = _disputed(4 * U);
        address other = makeAddr("other_arbiter");
        vm.prank(owner);
        hl.proposeArbiter(other);
        vm.warp(block.timestamp + 168 * H);
        hl.applyArbiterChange();
        assertEq(hl.arbiter(), other);
        vm.prank(other);
        vm.expectRevert("only arbiter");
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("X"), "x", true);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.FREELANCER_WINS, bytes32("WORK_MATCHES_BRIEF"), "ok", true);
        _accounting();
    }

    function test_rejected_client_cannot_reclaim() public {
        _register(20 * U);
        uint256 id = _gig(4 * U);
        vm.prank(client);
        hl.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(freelancer);
        hl.respondPayment(id, false, "no money received");
        vm.prank(client);
        vm.expectRevert("claim was rejected");
        hl.claimPayment{value: U}(id, "bank ref 654321");
        vm.prank(stranger);
        hl.claimPayment{value: U}(id, "bank ref 777777");
    }

    function test_reopen_allows_more_evidence() public {
        uint256 id = _disputed(4 * U);
        vm.startPrank(client);
        hl.submitEvidence(id, "second piece of proof", "");
        hl.submitEvidence(id, "third piece of proof", "");
        vm.stopPrank();
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "thin", true);
        vm.startPrank(client);
        hl.submitEvidence(id, "fourth piece of proof", "");
        hl.submitEvidence(id, "fifth piece of proof", "");
        vm.expectRevert("evidence limit");
        hl.submitEvidence(id, "sixth piece of proof", "");
        vm.stopPrank();
    }

    function test_trusted_needs_client_confirmed_gigs() public {
        _register(50 * U);
        for (uint256 k = 0; k < 5; k++) {
            address b = makeAddr(string(abi.encodePacked("client", vm.toString(k))));
            vm.gig(b, 10 ether);
            vm.prank(freelancer);
            uint256 id = hl.createGig("Landing page design in Figma", "40 USD", "", 2 * U, 5);
            vm.prank(b);
            hl.claimPayment{value: U}(id, "bank ref 123456");
            vm.prank(freelancer);
            hl.respondPayment(id, true, "");
            vm.prank(freelancer);
            hl.submitDelivery(id, "shipped ok", "");
            vm.warp(block.timestamp + 72 * H + 1);
            hl.finalizeGig(id);
        }
        HireLockBase.FreelancerInfo memory i = hl.freelancerInfo(freelancer);
        assertEq(uint256(i.completedAuto), 5);
        assertFalse(i.trusted);
    }

    function test_rejection_does_not_lower_score() public {
        _register(20 * U);
        uint256 before = hl.freelancerScore(freelancer);
        uint256 id = _gig(4 * U);
        vm.prank(client);
        hl.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(freelancer);
        hl.respondPayment(id, false, "no money received");
        assertEq(hl.freelancerScore(freelancer), before);
    }

    function test_bad_unit_rejected() public {
        vm.expectRevert("bad unit");
        new HireLockBase(arbiter, 86401);
    }

    function _timeoutDisputed(uint256 cover) internal returns (uint256 id) {
        _register(20 * U);
        id = _gig(cover);
        vm.prank(client);
        hl.claimPayment{value: U}(id, "bank ref 123456");
        vm.warp(block.timestamp + 24 * H);
        hl.bindByTimeout(id);
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(client);
        hl.openDispute{value: U}(id, "nothing was ever sent", "");
        vm.warp(block.timestamp + 48 * H + 1);
    }

    function test_timeout_gig_client_win_is_capped_at_25_percent() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "x", true);
        assertEq(uint256(hl.getGig(id).status), uint256(HireLockBase.Status.PAYOUT_PENDING));
        vm.expectRevert("payout is still locked");
        hl.finalizePayout(id);
        vm.warp(block.timestamp + 168 * H);
        hl.finalizePayout(id);
        HireLockBase.Gig memory d = hl.getGig(id);
        assertEq(d.compensation, U);
        assertTrue(d.paymentEvidenceReviewed);
        assertEq(hl.claimable(client), 3 * U);
        _accounting();
    }

    function test_timeout_gig_split_is_capped_at_25_percent() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.SPLIT, bytes32("PARTIAL_OR_OFF_BRIEF"), "x", true);
        vm.warp(block.timestamp + 168 * H);
        hl.finalizePayout(id);
        assertEq(hl.getGig(id).compensation, U);
        _accounting();
    }

    function test_timeout_gig_needs_review_flag_for_compensation() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        vm.expectRevert("payment evidence not reviewed");
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "x", false);
        vm.prank(arbiter);
        vm.expectRevert("payment evidence not reviewed");
        hl.resolveDispute(id, HireLockBase.Verdict.SPLIT, bytes32("PARTIAL_OR_OFF_BRIEF"), "x", false);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.FREELANCER_WINS, bytes32("CLIENT_CLAIM_UNSUPPORTED"), "x", false);
        assertEq(hl.getGig(id).compensation, 0);
        _accounting();
    }

    function test_timeout_gig_arbiter_cannot_exceed_cap_even_if_flagged() public {
        uint256 id = _timeoutDisputed(10 * U);
        uint256 stakeBefore = hl.freelancerInfo(freelancer).stake;
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "x", true);
        vm.warp(block.timestamp + 168 * H);
        hl.finalizePayout(id);
        uint256 comp = (10 * U * 2500) / 10000;
        uint256 fee = (comp * 500) / 10000;
        assertEq(stakeBefore - hl.freelancerInfo(freelancer).stake, comp + fee);
    }

    function test_timeout_gig_inconclusive_needs_no_flag() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "x", false);
        assertEq(uint256(hl.getGig(id).status), uint256(HireLockBase.Status.REOPENED));
    }

    function test_claim_deposit_must_be_exact() public {
        _register(20 * U);
        uint256 id = _gig(4 * U);
        vm.prank(client);
        vm.expectRevert("wrong deposit");
        hl.claimPayment{value: U / 2}(id, "bank ref 123456");
        vm.prank(client);
        vm.expectRevert("wrong deposit");
        hl.claimPayment{value: 2 * U}(id, "bank ref 123456");
    }

    function test_rejected_claim_deposit_is_burned() public {
        _register(20 * U);
        uint256 id = _gig(4 * U);
        vm.prank(client);
        hl.claimPayment{value: U}(id, "bank ref 123456");
        vm.prank(freelancer);
        hl.respondPayment(id, false, "no money received");
        assertEq(hl.burned(), U);
        assertEq(hl.treasury(), 0);
        assertEq(hl.claimable(freelancer), 0);
        assertEq(hl.getGig(id).claimDeposit, 0);
        _accounting();
    }

    function test_claim_deposit_returned_on_completion() public {
        uint256 id = _delivered(4 * U);
        vm.prank(client);
        hl.confirmDelivery(id);
        assertEq(hl.claimable(client), U);
        _accounting();
    }

    function test_freelancer_can_challenge_pending_payout() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "x", true);
        vm.prank(stranger);
        vm.expectRevert("only freelancer");
        hl.challengePayout(id, "I never saw this payment", "");
        vm.prank(freelancer);
        hl.challengePayout(id, "My bank shows no incoming transfer", "https://example.com/stmt");
        assertEq(uint256(hl.getGig(id).status), uint256(HireLockBase.Status.CHALLENGED));
        vm.warp(block.timestamp + 24 * H + 1);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.FREELANCER_WINS, bytes32("CLIENT_CLAIM_UNSUPPORTED"), "x", false);
        assertEq(hl.getGig(id).compensation, 0);
        assertEq(hl.claimable(freelancer), 2 * U);
        assertEq(hl.claimable(client), 0);
        _accounting();
    }

    function test_challenge_window_closes() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "x", true);
        vm.warp(block.timestamp + 168 * H);
        vm.prank(freelancer);
        vm.expectRevert("challenge window closed");
        hl.challengePayout(id, "too late to object", "");
    }

    function test_challenged_ruling_pays_immediately_and_stays_capped() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "x", true);
        vm.prank(freelancer);
        hl.challengePayout(id, "My bank shows no incoming transfer", "");
        vm.warp(block.timestamp + 24 * H + 1);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "x", true);
        assertEq(uint256(hl.getGig(id).status), uint256(HireLockBase.Status.RESOLVED));
        assertEq(hl.getGig(id).compensation, U);
        _accounting();
    }

    function test_trusted_needs_age_and_unique_clients() public {
        _register(50 * U);
        for (uint256 k = 0; k < 6; k++) {
            address b = makeAddr(string(abi.encodePacked("rep", vm.toString(k % 2))));
            vm.gig(b, 100 ether);
            vm.prank(freelancer);
            uint256 id = hl.createGig("Landing page design in Figma", "40 USD", "", 2 * U, 5);
            vm.prank(b);
            hl.claimPayment{value: U}(id, "bank ref 123456");
            vm.prank(freelancer);
            hl.respondPayment(id, true, "");
            vm.prank(freelancer);
            hl.submitDelivery(id, "shipped ok", "");
            vm.prank(b);
            hl.confirmDelivery(id);
        }
        vm.warp(block.timestamp + 340 * H);
        HireLockBase.FreelancerInfo memory i = hl.freelancerInfo(freelancer);
        assertEq(uint256(i.completedVerified), 6);
        assertEq(uint256(i.uniqueClients), 2);
        assertFalse(i.trusted);
    }

    function test_freelancer_can_challenge_after_using_all_evidence_slots() public {
        uint256 id = _timeoutDisputed(4 * U);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.INSUFFICIENT_EVIDENCE, bytes32("NO_SUBSTANTIVE_EVIDENCE"), "x", false);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(freelancer);
            hl.submitEvidence(id, "freelancer evidence text", "");
        }
        vm.warp(block.timestamp + 24 * H + 1);
        vm.prank(arbiter);
        hl.resolveDispute(id, HireLockBase.Verdict.CLIENT_WINS, bytes32("NO_DELIVERABLE"), "x", true);
        vm.prank(freelancer);
        hl.challengePayout(id, "My bank shows no incoming transfer", "");
        assertEq(uint256(hl.getGig(id).status), uint256(HireLockBase.Status.CHALLENGED));
        vm.prank(client);
        hl.submitEvidence(id, "client reply to the challenge", "");
        vm.prank(freelancer);
        hl.submitEvidence(id, "freelancer follow-up after challenge", "");
        _accounting();
    }
}
