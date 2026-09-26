// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Sleepstake.sol";

contract SleepstakeTest is Test {
    Sleepstake public sleepstake;
    address user = address(0x1);

    function setUp() public {
        sleepstake = new Sleepstake();
        vm.deal(user, 10 ether);
    }

    function test_Stake() public {
        vm.prank(user);
        sleepstake.stake{value: 1 ether}();

        assertEq(sleepstake.getBalance(user), 1 ether);
    }

    function test_Unstake() public {
        vm.startPrank(user);
        sleepstake.stake{value: 2 ether}();
        sleepstake.unstake(1 ether);
        vm.stopPrank();

        assertEq(sleepstake.getBalance(user), 1 ether);
    }
}