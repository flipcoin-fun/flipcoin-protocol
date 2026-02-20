// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DelegationRegistry} from "../contracts/v2/DelegationRegistry.sol";
import {Delegation} from "../contracts/v2/interfaces/Types.sol";

contract DelegationRegistryTest is Test {
    DelegationRegistry public registry;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public exchange = makeAddr("exchange");

    function setUp() public {
        vm.prank(admin);
        registry = new DelegationRegistry(admin);

        vm.prank(admin);
        registry.addAuthorizedContract(exchange);
    }

    function test_setDelegation() public {
        vm.prank(alice);
        registry.setDelegation(bob, address(0), 100_000_000, 0);

        Delegation memory d = registry.getDelegation(alice, bob);
        assertTrue(d.active);
        assertEq(d.scope, address(0));
        assertEq(d.maxNotionalPerDay, 100_000_000);
        assertEq(d.expiresAt, 0);
    }

    function test_setDelegation_withScope() public {
        vm.prank(alice);
        registry.setDelegation(bob, exchange, 0, uint64(block.timestamp + 1 days));

        assertTrue(registry.isAuthorized(alice, bob, exchange, bytes32(0)));
        assertFalse(registry.isAuthorized(alice, bob, makeAddr("other"), bytes32(0)));
    }

    function test_revokeDelegation() public {
        vm.prank(alice);
        registry.setDelegation(bob, address(0), 0, 0);
        assertTrue(registry.isAuthorized(alice, bob, exchange, bytes32(0)));

        vm.prank(alice);
        registry.revokeDelegation(bob);
        assertFalse(registry.isAuthorized(alice, bob, exchange, bytes32(0)));
    }

    function test_isAuthorized_expired() public {
        vm.prank(alice);
        registry.setDelegation(bob, address(0), 0, uint64(block.timestamp + 1 hours));

        assertTrue(registry.isAuthorized(alice, bob, exchange, bytes32(0)));

        // Fast forward past expiry
        vm.warp(block.timestamp + 2 hours);
        assertFalse(registry.isAuthorized(alice, bob, exchange, bytes32(0)));
    }

    function test_recordSpend_basic() public {
        vm.prank(alice);
        registry.setDelegation(bob, address(0), 50_000_000, 0);

        vm.prank(exchange);
        registry.recordSpend(alice, bob, 10_000_000);

        Delegation memory d = registry.getDelegation(alice, bob);
        assertEq(d.spentToday, 10_000_000);
    }

    function test_recordSpend_exceedsLimit() public {
        vm.prank(alice);
        registry.setDelegation(bob, address(0), 50_000_000, 0);

        vm.prank(exchange);
        vm.expectRevert(DelegationRegistry.DailyLimitExceeded.selector);
        registry.recordSpend(alice, bob, 60_000_000);
    }

    function test_recordSpend_unlimitedWhenZero() public {
        vm.prank(alice);
        registry.setDelegation(bob, address(0), 0, 0); // 0 = unlimited

        vm.prank(exchange);
        registry.recordSpend(alice, bob, 999_999_999_999);
        // Should not revert
    }

    function test_recordSpend_dailyReset() public {
        vm.prank(alice);
        registry.setDelegation(bob, address(0), 50_000_000, 0);

        // Spend 40 USDC
        vm.prank(exchange);
        registry.recordSpend(alice, bob, 40_000_000);

        // Next day: window resets
        vm.warp(block.timestamp + 25 hours);

        vm.prank(exchange);
        registry.recordSpend(alice, bob, 40_000_000); // Should succeed (new day)

        Delegation memory d = registry.getDelegation(alice, bob);
        assertEq(d.spentToday, 40_000_000); // Only today's spend
    }

    function test_recordSpend_notAuthorizedContract() public {
        vm.prank(alice);
        registry.setDelegation(bob, address(0), 0, 0);

        vm.prank(makeAddr("random"));
        vm.expectRevert(DelegationRegistry.NotAuthorizedContract.selector);
        registry.recordSpend(alice, bob, 1_000_000);
    }

    function test_cannotDelegateToSelf() public {
        vm.prank(alice);
        vm.expectRevert("cannot delegate to self");
        registry.setDelegation(alice, address(0), 0, 0);
    }

    function test_cannotDelegateToZero() public {
        vm.prank(alice);
        vm.expectRevert(DelegationRegistry.InvalidSigner.selector);
        registry.setDelegation(address(0), address(0), 0, 0);
    }

    function test_addRemoveAuthorizedContract() public {
        address newContract = makeAddr("new");

        vm.prank(admin);
        registry.addAuthorizedContract(newContract);
        assertTrue(registry.authorizedContracts(newContract));

        vm.prank(admin);
        registry.removeAuthorizedContract(newContract);
        assertFalse(registry.authorizedContracts(newContract));
    }

    function test_onlyAdminCanAddAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(DelegationRegistry.NotAdmin.selector);
        registry.addAuthorizedContract(makeAddr("x"));
    }

    function test_transferAdmin() public {
        vm.prank(admin);
        registry.transferAdmin(alice);
        assertEq(registry.admin(), alice);
    }
}
