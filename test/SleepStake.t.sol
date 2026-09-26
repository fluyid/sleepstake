// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {SleepStake} from "../src/SleepStake.sol";

/**
 * @title SleepStakeTest
 * @notice Comprehensive unit tests for SleepStake covering rules, boundaries,
 * settlement math invariants, and access control.
 */
contract SleepStakeTest is Test {
    SleepStake public sleepStake;

    // Roles and test addresses
    address public oracle;
    address public kai;
    address public alice;
    address public bob;
    address public charlie;

    // Base timestamp used as reference for all challenge scheduling
    uint64 public constant BASE_TIME = 1_700_000_000;

    // Receive function so this test contract (which is the treasury/owner) can withdraw funds
    receive() external payable {}

    function setUp() public {
        // Warp timestamp so the clock is set before any deadlines
        vm.warp(BASE_TIME);

        // Separate, dedicated oracle wallet
        oracle = makeAddr("oracle");

        // Player wallets
        kai = makeAddr("kai");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Fund players with native tokens (MON)
        vm.deal(kai, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);

        // Deploy contract; msg.sender (this test contract) becomes owner/treasury
        sleepStake = new SleepStake(oracle);
    }

    // --- Helper Functions ---

    /**
     * @notice Helper to create a challenge with sensible default timing.
     * @param buyIn Buy-in per player.
     * @param nights Total number of nights in the challenge.
     * @return id Challenge ID.
     */
    function _createDefaultChallenge(uint256 buyIn, uint8 nights) internal returns (uint256 id) {
        uint64 firstNightStart = BASE_TIME + 1 days; // 21:00 on night 0
        uint64 joinDeadline = BASE_TIME + 12 hours; // 12 hours to join
        id = sleepStake.createChallenge(buyIn, firstNightStart, nights, joinDeadline);
    }

    /**
     * @notice Helper to compute absolute sleepStart and sleepEnd timestamps from 21:00 offsets.
     */
    function _getSleepTimes(uint256 id, uint8 night, int256 startOffset, int256 endOffset)
        internal
        view
        returns (uint64 sleepStart, uint64 sleepEnd)
    {
        SleepStake.Challenge memory c = sleepStake.getChallenge(id);
        uint64 nightWindowStart = c.firstNightStart + uint64(night) * 1 days;

        sleepStart = uint64(uint256(int256(uint256(nightWindowStart)) + startOffset));
        sleepEnd = uint64(uint256(int256(uint256(nightWindowStart)) + endOffset));
    }

    /**
     * @notice Helper to submit sleep with times given as offsets from each night's 21:00 window start.
     * For example, startOffset = 1 hours means 22:00, endOffset = 9 hours means 06:00.
     * Negative offsets can represent times before 21:00 (e.g. -60 for 20:59).
     */
    function _submitSleepOffset(uint256 id, address player, uint8 night, int256 startOffset, int256 endOffset)
        internal
    {
        (uint64 sleepStart, uint64 sleepEnd) = _getSleepTimes(id, night, startOffset, endOffset);
        vm.prank(oracle);
        sleepStake.submitSleep(id, player, night, sleepStart, sleepEnd);
    }

    // =========================================================================
    // MUST HAVE TESTS
    // =========================================================================

    /**
     * @notice 1. Happy path: 3 players, 2 nights; 2 win, 1 loses.
     * Verifies:
     * - SleepReported event emitted with reason TOO_SHORT for Bob.
     * - 5% fee taken from forfeited pool.
     * - Winners receive original buy-in + equal share of forfeited pool.
     * - Invariant holds: sum of claimables == total buy-ins == contract balance.
     */
    function test_HappyPath_TwoWinnersOneLoser() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 2);

        // 3 players join
        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);

        vm.prank(alice);
        sleepStake.join{value: buyIn}(id);

        vm.prank(bob);
        sleepStake.join{value: buyIn}(id);

        // Night 0: Kai & Alice pass (22:00 to 06:00, 8h)
        _submitSleepOffset(id, kai, 0, 1 hours, 9 hours);
        _submitSleepOffset(id, alice, 0, 1 hours, 9 hours);

        // Bob sleeps 22:00 to 05:00 (7 hours = 25,200s, too short)
        // Expect SleepReported event with reason TOO_SHORT
        vm.expectEmit(true, true, false, true);
        emit SleepStake.SleepReported(id, bob, 0, false, SleepStake.SleepReason.TOO_SHORT, 7 hours);
        _submitSleepOffset(id, bob, 0, 1 hours, 8 hours);

        // Night 1: Kai, Alice, and Bob all pass (22:00 to 06:00, 8h)
        _submitSleepOffset(id, kai, 1, 1 hours, 9 hours);
        _submitSleepOffset(id, alice, 1, 1 hours, 9 hours);
        _submitSleepOffset(id, bob, 1, 1 hours, 9 hours);

        // Settle the challenge (all reports are in)
        sleepStake.settle(id);

        // Settlement math:
        // Loser pool: 1 ether (Bob failed night 0).
        // 5% fee: 0.05 ether (50,000,000,000,000,000 wei).
        // Pool after fee: 0.95 ether.
        // 2 winners (Kai and Alice) split 0.95 ether -> 0.475 ether each.
        // Remainder dust: 0.
        // Winner total payout: 1 ether buy-in + 0.475 ether = 1.475 ether.
        uint256 expectedFee = 0.05 ether;
        uint256 expectedWinnerPayout = 1.475 ether;

        assertEq(sleepStake.claimable(kai), expectedWinnerPayout, "Kai payout mismatch");
        assertEq(sleepStake.claimable(alice), expectedWinnerPayout, "Alice payout mismatch");
        assertEq(sleepStake.claimable(bob), 0, "Bob should have 0 claimable");
        assertEq(sleepStake.claimable(address(this)), expectedFee, "Treasury fee mismatch");

        // Mathematical invariant: sum of all claimable balances == total buy-ins == contract balance
        uint256 totalClaimable = sleepStake.claimable(kai) + sleepStake.claimable(alice) + sleepStake.claimable(bob)
            + sleepStake.claimable(address(this));
        uint256 totalBuyIns = buyIn * 3;

        assertEq(totalClaimable, totalBuyIns, "Invariant failed: sum of claimables != total buy-ins");
        assertEq(address(sleepStake).balance, totalBuyIns, "Invariant failed: contract balance != total buy-ins");
    }

    /**
     * @notice 2. Boundaries: exactly 7h30 passes, 7h29m59s fails, exactly 8h30 passes, 8h30m01s fails.
     */
    function test_Boundaries_MinAndMaxSleep() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);
        vm.prank(alice);
        sleepStake.join{value: buyIn}(id);
        vm.prank(bob);
        sleepStake.join{value: buyIn}(id);
        vm.prank(charlie);
        sleepStake.join{value: buyIn}(id);

        // Kai: exactly 7h30 (27,000s). Starts at 22:00 (1h offset), ends at 1h + 27,000s -> PASS
        _submitSleepOffset(id, kai, 0, 1 hours, 1 hours + 27000);

        // Alice: 7h29m59s (26,999s). Starts at 22:00 (1h offset), ends at 1h + 26,999s -> FAIL (TOO_SHORT)
        _submitSleepOffset(id, alice, 0, 1 hours, 1 hours + 26999);

        // Bob: exactly 8h30 (30,600s). Starts at 21:00 (0h offset), ends at 30,600s -> PASS
        _submitSleepOffset(id, bob, 0, 0 hours, 30600);

        // Charlie: 8h30m01s (30,601s). Starts at 21:00 (0h offset), ends at 30,601s -> FAIL (TOO_LONG)
        _submitSleepOffset(id, charlie, 0, 0 hours, 30601);

        (uint8 kaiPassed,,) = sleepStake.getPlayerStatus(id, kai);
        (uint8 alicePassed,,) = sleepStake.getPlayerStatus(id, alice);
        (uint8 bobPassed,,) = sleepStake.getPlayerStatus(id, bob);
        (uint8 charliePassed,,) = sleepStake.getPlayerStatus(id, charlie);

        assertEq(kaiPassed, 1, "Kai (7h30) should pass");
        assertEq(alicePassed, 0, "Alice (7h29m59s) should fail");
        assertEq(bobPassed, 1, "Bob (8h30) should pass");
        assertEq(charliePassed, 0, "Charlie (8h30m01s) should fail");
    }

    /**
     * @notice 3. Window: start at 20:59 fails, end at 06:01 fails,
     * start 00:30 end 08:15 fails (ends after 06:00), start 22:00 end 06:00 passes.
     */
    function test_Window_SleepWindowConstraints() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);
        vm.prank(alice);
        sleepStake.join{value: buyIn}(id);
        vm.prank(bob);
        sleepStake.join{value: buyIn}(id);
        vm.prank(charlie);
        sleepStake.join{value: buyIn}(id);

        // Kai: starts at 20:59 (-60s offset), ends at 05:00 (8h1m duration) -> FAIL (OUTSIDE_WINDOW)
        _submitSleepOffset(id, kai, 0, -60, 8 hours);

        // Alice: starts at 22:00 (1h offset), ends at 06:01 (9h + 60s offset) -> FAIL (OUTSIDE_WINDOW)
        _submitSleepOffset(id, alice, 0, 1 hours, 9 hours + 60);

        // Bob: starts at 00:30 (3.5h offset), ends at 08:15 (11.25h offset) -> FAIL (OUTSIDE_WINDOW: ends after 06:00)
        _submitSleepOffset(id, bob, 0, int256(3 hours + 30 minutes), int256(11 hours + 15 minutes));

        // Charlie: starts at 22:00 (1h offset), ends at 06:00 (9h offset, 8h duration) -> PASS
        _submitSleepOffset(id, charlie, 0, 1 hours, 9 hours);

        (uint8 kaiPassed,,) = sleepStake.getPlayerStatus(id, kai);
        (uint8 alicePassed,,) = sleepStake.getPlayerStatus(id, alice);
        (uint8 bobPassed,,) = sleepStake.getPlayerStatus(id, bob);
        (uint8 charliePassed,,) = sleepStake.getPlayerStatus(id, charlie);

        assertEq(kaiPassed, 0, "Kai (started 20:59) should fail");
        assertEq(alicePassed, 0, "Alice (ended 06:01) should fail");
        assertEq(bobPassed, 0, "Bob (ended 08:15) should fail");
        assertEq(charliePassed, 1, "Charlie (22:00-06:00) should pass");
    }

    /**
     * @notice 4. Nobody wins: full refunds, no fee.
     */
    function test_NobodyWins_FullRefundsNoFee() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);
        vm.prank(alice);
        sleepStake.join{value: buyIn}(id);
        vm.prank(bob);
        sleepStake.join{value: buyIn}(id);

        // All 3 players fail (too short)
        _submitSleepOffset(id, kai, 0, 1 hours, 6 hours);
        _submitSleepOffset(id, alice, 0, 1 hours, 6 hours);
        _submitSleepOffset(id, bob, 0, 1 hours, 6 hours);

        sleepStake.settle(id);

        // Everyone gets buyIn back, treasury gets 0 fee
        assertEq(sleepStake.claimable(kai), buyIn, "Kai refund mismatch");
        assertEq(sleepStake.claimable(alice), buyIn, "Alice refund mismatch");
        assertEq(sleepStake.claimable(bob), buyIn, "Bob refund mismatch");
        assertEq(sleepStake.claimable(address(this)), 0, "Treasury should receive 0 fee");

        // Invariant holds
        uint256 totalClaimable = sleepStake.claimable(kai) + sleepStake.claimable(alice) + sleepStake.claimable(bob)
            + sleepStake.claimable(address(this));
        assertEq(totalClaimable, buyIn * 3, "Invariant violated");
    }

    /**
     * @notice 5. Everyone wins: full refunds, no fee.
     */
    function test_EveryoneWins_FullRefundsNoFee() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);
        vm.prank(alice);
        sleepStake.join{value: buyIn}(id);
        vm.prank(bob);
        sleepStake.join{value: buyIn}(id);

        // All 3 players pass (8h)
        _submitSleepOffset(id, kai, 0, 1 hours, 9 hours);
        _submitSleepOffset(id, alice, 0, 1 hours, 9 hours);
        _submitSleepOffset(id, bob, 0, 1 hours, 9 hours);

        sleepStake.settle(id);

        // Everyone gets buyIn back, treasury gets 0 fee
        assertEq(sleepStake.claimable(kai), buyIn, "Kai refund mismatch");
        assertEq(sleepStake.claimable(alice), buyIn, "Alice refund mismatch");
        assertEq(sleepStake.claimable(bob), buyIn, "Bob refund mismatch");
        assertEq(sleepStake.claimable(address(this)), 0, "Treasury should receive 0 fee");

        // Invariant holds
        uint256 totalClaimable = sleepStake.claimable(kai) + sleepStake.claimable(alice) + sleepStake.claimable(bob)
            + sleepStake.claimable(address(this));
        assertEq(totalClaimable, buyIn * 3, "Invariant violated");
    }

    /**
     * @notice 6. Non-oracle submit reverts.
     */
    function test_Revert_NonOracleSubmit() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);

        // An unauthorized address attempts to submit sleep report
        vm.prank(alice);
        vm.expectRevert(SleepStake.OnlyOracle.selector);
        sleepStake.submitSleep(id, kai, 0, BASE_TIME + 1 days + 1 hours, BASE_TIME + 1 days + 9 hours);
    }

    /**
     * @notice 7. Withdraw sends the correct balance and a second withdraw reverts.
     */
    function test_Withdraw_CorrectBalanceAndSecondWithdrawReverts() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);

        // Kai passes, challenge settles
        _submitSleepOffset(id, kai, 0, 1 hours, 9 hours);
        sleepStake.settle(id);

        assertEq(sleepStake.claimable(kai), buyIn, "Kai should have claimable refund");

        uint256 balanceBefore = kai.balance;

        // Kai withdraws
        vm.prank(kai);
        sleepStake.withdraw();

        uint256 balanceAfter = kai.balance;
        assertEq(balanceAfter - balanceBefore, buyIn, "Kai did not receive correct MON balance");
        assertEq(sleepStake.claimable(kai), 0, "Kai claimable balance not zeroed");

        // Second withdraw reverts because nothing is claimable
        vm.prank(kai);
        vm.expectRevert(SleepStake.NothingToWithdraw.selector);
        sleepStake.withdraw();
    }

    /**
     * @notice Dust rounding case: 3 winners and 1 loser where the share does not divide evenly.
     * Verifies:
     * - Remainder dust goes to the treasury.
     * - Invariant strictly holds: sum of all claimable balances == total buy-ins == contract balance.
     */
    function test_DustRounding_ThreeWinnersOneLoser() public {
        uint256 buyIn = 1 ether; // 1,000,000,000,000,000,000 wei
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);
        vm.prank(alice);
        sleepStake.join{value: buyIn}(id);
        vm.prank(bob);
        sleepStake.join{value: buyIn}(id);
        vm.prank(charlie);
        sleepStake.join{value: buyIn}(id);

        // Kai, Alice, Bob pass (8h)
        _submitSleepOffset(id, kai, 0, 1 hours, 9 hours);
        _submitSleepOffset(id, alice, 0, 1 hours, 9 hours);
        _submitSleepOffset(id, bob, 0, 1 hours, 9 hours);

        // Charlie fails (too short)
        _submitSleepOffset(id, charlie, 0, 1 hours, 6 hours);

        sleepStake.settle(id);

        // Math:
        // Loser pool: 1 ether = 10^18 wei.
        // 5% fee: 0.05 ether = 50,000,000,000,000,000 wei.
        // Pool after fee: 950,000,000,000,000,000 wei.
        // 950_000_000_000_000_000 / 3 = 316_666_666_666_666_666 wei per winner.
        // Remainder (dust): 950_000_000_000_000_000 % 3 = 2 wei.
        // Treasury gets fee + dust: 50_000_000_000_000_002 wei.
        uint256 expectedPerWinner = buyIn + 316_666_666_666_666_666;
        uint256 expectedTreasury = 0.05 ether + 2;

        assertEq(sleepStake.claimable(kai), expectedPerWinner, "Kai payout mismatch");
        assertEq(sleepStake.claimable(alice), expectedPerWinner, "Alice payout mismatch");
        assertEq(sleepStake.claimable(bob), expectedPerWinner, "Bob payout mismatch");
        assertEq(sleepStake.claimable(charlie), 0, "Charlie should have 0 claimable");
        assertEq(sleepStake.claimable(address(this)), expectedTreasury, "Treasury dust mismatch");

        // Strict invariant check: sum of all claimables == total buy-ins == contract balance
        uint256 totalClaimable = sleepStake.claimable(kai) + sleepStake.claimable(alice) + sleepStake.claimable(bob)
            + sleepStake.claimable(charlie) + sleepStake.claimable(address(this));
        uint256 totalBuyIns = buyIn * 4;

        assertEq(totalClaimable, totalBuyIns, "Dust invariant failed: total claimable != total buy-ins");
        assertEq(address(sleepStake).balance, totalBuyIns, "Dust invariant failed: contract balance != total buy-ins");
    }

    // =========================================================================
    // OPTIONAL TESTS (Edge cases & Reverts)
    // =========================================================================

    /**
     * @notice Joining with incorrect buy-in amount reverts.
     */
    function test_Revert_WrongBuyIn() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        vm.expectRevert(SleepStake.IncorrectBuyIn.selector);
        sleepStake.join{value: 0.5 ether}(id);
    }

    /**
     * @notice Joining twice reverts.
     */
    function test_Revert_DoubleJoin() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);

        vm.prank(kai);
        vm.expectRevert(SleepStake.AlreadyJoined.selector);
        sleepStake.join{value: buyIn}(id);
    }

    /**
     * @notice Joining after joinDeadline reverts.
     */
    function test_Revert_JoinAfterDeadline() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        // Warp past join deadline (joinDeadline is BASE_TIME + 12 hours)
        vm.warp(BASE_TIME + 13 hours);

        vm.prank(kai);
        vm.expectRevert(SleepStake.JoinDeadlinePassed.selector);
        sleepStake.join{value: buyIn}(id);
    }

    /**
     * @notice Submitting sleep report twice for the same player and night reverts.
     */
    function test_Revert_DoubleReport() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);

        _submitSleepOffset(id, kai, 0, 1 hours, 9 hours);

        (uint64 sleepStart, uint64 sleepEnd) = _getSleepTimes(id, 0, 1 hours, 9 hours);

        // Second report for same night reverts
        vm.prank(oracle);
        vm.expectRevert(SleepStake.AlreadyReported.selector);
        sleepStake.submitSleep(id, kai, 0, sleepStart, sleepEnd);
    }

    /**
     * @notice Settling a challenge twice reverts.
     */
    function test_Revert_DoubleSettle() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);

        _submitSleepOffset(id, kai, 0, 1 hours, 9 hours);
        sleepStake.settle(id);

        vm.expectRevert(SleepStake.AlreadySettled.selector);
        sleepStake.settle(id);
    }

    /**
     * @notice Settling too early when reports are missing reverts.
     */
    function test_Revert_SettleTooEarlyWithMissingReports() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 1);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);

        // No reports submitted yet and time has not reached firstNightStart + 1 days
        vm.expectRevert(SleepStake.CannotSettleYet.selector);
        sleepStake.settle(id);
    }

    /**
     * @notice When challenge duration expires, settling is allowed even with missing reports.
     * Unreported nights count as fails.
     */
    function test_Settle_UnreportedNightsCountAsFailsAfterTimeExpiry() public {
        uint256 buyIn = 1 ether;
        uint256 id = _createDefaultChallenge(buyIn, 2);

        vm.prank(kai);
        sleepStake.join{value: buyIn}(id);
        vm.prank(alice);
        sleepStake.join{value: buyIn}(id);

        // Kai passes night 0 and night 1
        _submitSleepOffset(id, kai, 0, 1 hours, 9 hours);
        _submitSleepOffset(id, kai, 1, 1 hours, 9 hours);

        // Alice only reports night 0 (passes), night 1 is never reported
        _submitSleepOffset(id, alice, 0, 1 hours, 9 hours);

        // Warp past firstNightStart + 2 days
        SleepStake.Challenge memory c = sleepStake.getChallenge(id);
        vm.warp(uint256(c.firstNightStart) + (uint256(c.nights) * 1 days) + 1);

        // Settlement succeeds because time has expired
        sleepStake.settle(id);

        // Kai passed both nights -> winner
        // Alice only passed 1 of 2 nights -> loser (unreported night counted as fail)
        uint256 expectedFee = 0.05 ether;
        uint256 expectedWinnerPayout = 1.95 ether; // 1 ether buy-in + 0.95 ether forfeited pool

        assertEq(sleepStake.claimable(kai), expectedWinnerPayout, "Kai should win full forfeited pool minus fee");
        assertEq(sleepStake.claimable(alice), 0, "Alice should lose due to missing report");
        assertEq(sleepStake.claimable(address(this)), expectedFee, "Treasury should receive fee");
    }

    /**
     * @notice Updating oracle address: owner can update, non-owner reverts.
     */
    function test_SetOracle() public {
        address newOracle = makeAddr("newOracle");

        // Non-owner reverts
        vm.prank(kai);
        vm.expectRevert(SleepStake.OnlyOwner.selector);
        sleepStake.setOracle(newOracle);

        // Zero address reverts
        vm.expectRevert(SleepStake.InvalidAddress.selector);
        sleepStake.setOracle(address(0));

        // Owner can update
        sleepStake.setOracle(newOracle);
        assertEq(sleepStake.oracle(), newOracle, "Oracle address not updated");
    }
}
