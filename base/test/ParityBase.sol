// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/HireLockBase.sol";

abstract contract ParityBase is Test {
    struct Obs {
        bool reverted;
        uint8 status;
        uint8 verdict;
        uint256 compensation;
        uint256 fee;
        uint256 clientClaimable;
        uint256 freelancerClaimable;
        uint256 treasury;
        uint256 freelancerStake;
        uint256 freelancerLocked;
        uint256 lost;
        uint256 split;
        uint256 won;
        uint256 inconclusive;
    }

    uint256 internal constant U = 0.001 ether;
    uint256 internal constant H = 3600;

    function _run(uint256 coverUnits, bool silent, uint8[] memory kinds, uint8[] memory verdicts, bool[] memory reviewed) internal returns (Obs memory o) {
        address arbiter = makeAddr("arbiter");
        address freelancer = makeAddr("freelancer");
        address client = makeAddr("client");
        HireLockBase hl = new HireLockBase(arbiter, H);
        vm.gig(freelancer, 100 ether);
        vm.gig(client, 100 ether);

        vm.prank(freelancer);
        hl.registerFreelancer{value: 50 * U}("parity_shop");
        vm.prank(freelancer);
        uint256 id = hl.createGig("Parity scope", "1 USD", "", coverUnits * U, 48);
        vm.prank(client);
        hl.claimPayment{value: U}(id, "bank ref 123456");
        if (silent) {
            vm.warp(block.timestamp + 24 * H);
            hl.bindByTimeout(id);
        } else {
            vm.prank(freelancer);
            hl.respondPayment(id, true, "");
        }
        vm.warp(block.timestamp + 48 * H + 1);
        vm.prank(client);
        hl.openDispute{value: U}(id, "nothing was ever sent", "");
        vm.warp(block.timestamp + 48 * H + 1);

        for (uint256 i = 0; i < kinds.length; i++) {
            if (kinds[i] == 1) {
                vm.prank(freelancer);
                hl.challengePayout(id, "I never saw this payment", "");
            } else if (kinds[i] == 2) {
                vm.warp(block.timestamp + 168 * H);
                hl.finalizePayout(id);
            } else {
                if (i > 0) vm.warp(block.timestamp + 24 * H + 1);
                vm.prank(arbiter);
                try hl.resolveDispute(id, HireLockBase.Verdict(verdicts[i]), bytes32("PARITY"), "parity", reviewed[i]) {} catch {
                    o.reverted = true;
                    break;
                }
            }
        }

        HireLockBase.Gig memory d = hl.getGig(id);
        HireLockBase.FreelancerInfo memory s = hl.freelancerInfo(freelancer);
        o.status = uint8(d.status);
        o.verdict = uint8(d.verdict);
        o.compensation = d.compensation;
        o.fee = d.fee;
        o.clientClaimable = hl.claimable(client);
        o.freelancerClaimable = hl.claimable(freelancer);
        o.treasury = hl.treasury();
        o.freelancerStake = s.stake;
        o.freelancerLocked = s.locked;
        o.lost = s.disputesLost;
        o.split = s.disputesSplit;
        o.won = s.disputesWon;
        o.inconclusive = s.inconclusive;
    }
}
