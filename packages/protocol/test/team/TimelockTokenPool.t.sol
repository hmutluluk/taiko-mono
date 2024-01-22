// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../TaikoTest.sol";

contract MyERC20 is ERC20 {
    constructor(address owner) ERC20("Taiko Token", "TKO") {
        _mint(owner, 1_000_000_000e18);
    }
}

contract USDC is ERC20 {
    constructor(address recipient) ERC20("USDC", "USDC") {
        _mint(recipient, 1_000_000_000e6);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

contract TestTimelockTokenPool is TaikoTest {
    address internal Vault = randAddress();

    ERC20 tko = new MyERC20(Vault);
    ERC20 usdc = new USDC(Alice);

    uint128 public constant ONE_TKO_UNIT = 1e18;

    // 0.01 USDC if decimals are 6 (as in our test)
    uint64 strikePrice1 = uint64(10 ** usdc.decimals() / 100);
    // 0.05 USDC if decimals are 6 (as  in our test)
    uint64 strikePrice2 = uint64(10 ** usdc.decimals() / 20);

    TimelockTokenPool pool;

    function setUp() public {
        pool = TimelockTokenPool(
            deployProxy({
                name: "time_lock_token_pool",
                impl: address(new TimelockTokenPool()),
                data: abi.encodeCall(TimelockTokenPool.init, (address(tko), address(usdc), Vault))
            })
        );
    }

    function test_invalid_granting() public {
        vm.expectRevert(TimelockTokenPool.INVALID_GRANT.selector);
        pool.grant(Alice, TimelockTokenPool.Grant(0, 0, 0, 0, 0, 0, 0, 0));

        vm.expectRevert(TimelockTokenPool.INVALID_PARAM.selector);
        pool.grant(address(0), TimelockTokenPool.Grant(100e18, 0, 0, 0, 0, 0, 0, 0));
    }

    function test_single_grant_zero_grant_period_zero_unlock_period() public {
        pool.grant(Alice, TimelockTokenPool.Grant(10_000e18, 0, 0, 0, 0, 0, 0, 0));
        vm.prank(Vault);
        tko.approve(address(pool), 10_000e18);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100); // Very high number, higher than actual grant nr.
            // shall have no effect.
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 10_000e18);
        assertEq(costToWithdraw, 0);

        // Try to void the grant
        vm.expectRevert(TimelockTokenPool.NOTHING_TO_VOID.selector);
        pool.void(Alice);

        vm.prank(Alice);
        pool.withdraw(100); // Higher than max grant nr. shall have no effect.
        assertEq(tko.balanceOf(Alice), 10_000e18);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, 10_000e18);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);
    }

    function test_single_grant_zero_grant_period_1year_unlock_period() public {
        uint64 unlockStart = uint64(block.timestamp);
        uint32 unlockPeriod = 365 days;
        uint64 unlockCliff = unlockStart + unlockPeriod / 2;

        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                10_000e18, strikePrice1, 0, 0, 0, unlockStart, unlockCliff, unlockPeriod
            )
        );
        vm.prank(Vault);
        tko.approve(address(pool), 10_000e18);
        vm.prank(Alice);
        usdc.approve(address(pool), 10_000e18 / ONE_TKO_UNIT * strikePrice1);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        vm.warp(unlockCliff);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        vm.warp(unlockCliff + 1);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);

        uint256 amount1 = uint128(10_000e18) * uint64(block.timestamp - unlockStart) / unlockPeriod;
        uint256 expectedCost = amount1 / ONE_TKO_UNIT * strikePrice1;

        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, amount1);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, amount1);
        assertEq(costToWithdraw, expectedCost);

        vm.prank(Alice);
        pool.withdraw(100);

        vm.warp(unlockStart + unlockPeriod + 365 days);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);

        expectedCost = amount1 / ONE_TKO_UNIT * strikePrice1;

        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, amount1);
        assertEq(amountToWithdraw, 10_000e18 - amount1);
        assertEq(costToWithdraw, expectedCost);

        vm.prank(Alice);
        pool.withdraw(100);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, 10_000e18);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);
    }

    function test_single_grant_1year_grant_period_zero_unlock_period() public {
        uint64 grantStart = uint64(block.timestamp);
        uint32 grantPeriod = 365 days;
        uint64 grantCliff = grantStart + grantPeriod / 2;

        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                10_000e18, strikePrice1, grantStart, grantCliff, grantPeriod, 0, 0, 0
            )
        );
        vm.prank(Vault);
        tko.approve(address(pool), 10_000e18);

        vm.prank(Alice);
        usdc.approve(address(pool), 10_000e18 / ONE_TKO_UNIT * strikePrice1);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        vm.warp(grantCliff);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        vm.warp(grantCliff + 1);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);

        uint256 amount1 = uint128(10_000e18) * uint64(block.timestamp - grantStart) / grantPeriod;
        uint256 expectedCost = amount1 / ONE_TKO_UNIT * strikePrice1;

        assertEq(amountOwned, amount1);
        assertEq(amountUnlocked, amount1);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, amount1);
        assertEq(costToWithdraw, expectedCost);

        vm.prank(Alice);
        pool.withdraw(100);

        vm.warp(grantStart + grantPeriod + 365 days);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);

        expectedCost = amount1 / ONE_TKO_UNIT * strikePrice1;
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, amount1);
        assertEq(amountToWithdraw, 10_000e18 - amount1);
        assertEq(costToWithdraw, expectedCost);

        vm.prank(Alice);
        pool.withdraw(100);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, 10_000e18);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);
    }

    function test_single_grant_4year_grant_period_4year_unlock_period() public {
        uint64 grantStart = uint64(block.timestamp);
        uint32 grantPeriod = 4 * 365 days;
        uint64 grantCliff = grantStart + 90 days;

        uint64 unlockStart = grantStart + 365 days;
        uint32 unlockPeriod = 4 * 365 days;
        uint64 unlockCliff = unlockStart + 365 days;

        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                10_000e18,
                strikePrice1,
                grantStart,
                grantCliff,
                grantPeriod,
                unlockStart,
                unlockCliff,
                unlockPeriod
            )
        );
        vm.prank(Vault);
        tko.approve(address(pool), 10_000e18);

        vm.prank(Alice);
        usdc.approve(address(pool), 10_000e18 / ONE_TKO_UNIT * strikePrice1);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        // 90 days later
        vm.warp(grantStart + 90 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        // 1 year later
        vm.warp(grantStart + 365 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 2500e18);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        // 2 year later
        vm.warp(grantStart + 2 * 365 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 5000e18);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        // 3 year later
        vm.warp(grantStart + 3 * 365 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);

        uint256 expectedCost = 3750e18 / ONE_TKO_UNIT * strikePrice1;

        assertEq(amountOwned, 7500e18);
        assertEq(amountUnlocked, 3750e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 3750e18);
        assertEq(costToWithdraw, expectedCost);

        // 4 year later
        vm.warp(grantStart + 4 * 365 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);

        expectedCost = 7500e18 / ONE_TKO_UNIT * strikePrice1;

        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 7500e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 7500e18);
        assertEq(costToWithdraw, expectedCost);

        // 5 year later
        vm.warp(grantStart + 5 * 365 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);

        expectedCost = 10_000e18 / ONE_TKO_UNIT * strikePrice1;

        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 10_000e18);
        assertEq(costToWithdraw, expectedCost);

        // 6 year later
        vm.warp(grantStart + 6 * 365 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 10_000e18);
        assertEq(costToWithdraw, expectedCost);
    }

    function test_multiple_grants() public {
        pool.grant(Alice, TimelockTokenPool.Grant(10_000e18, strikePrice1, 0, 0, 0, 0, 0, 0));
        pool.grant(Alice, TimelockTokenPool.Grant(20_000e18, strikePrice2, 0, 0, 0, 0, 0, 0));

        vm.prank(Vault);
        tko.approve(address(pool), 30_000e18);

        uint256 overallCost =
            (10_000e18 / ONE_TKO_UNIT * strikePrice1) + (20_000e18 / ONE_TKO_UNIT * strikePrice2);

        vm.prank(Alice);
        usdc.approve(address(pool), overallCost);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 30_000e18);
        assertEq(amountUnlocked, 30_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 30_000e18);
        assertEq(costToWithdraw, overallCost);
    }

    function test_void_multiple_grants_before_granted() public {
        uint64 grantStart = uint64(block.timestamp) + 30 days;
        pool.grant(Alice, TimelockTokenPool.Grant(10_000e18, 0, grantStart, 0, 0, 0, 0, 0));
        pool.grant(Alice, TimelockTokenPool.Grant(20_000e18, 0, grantStart, 0, 0, 0, 0, 0));

        vm.prank(Vault);
        tko.approve(address(pool), 30_000e18);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        // Try to void the grant
        pool.void(Alice);

        TimelockTokenPool.Grant[] memory grants = pool.getMyGrants(Alice);
        for (uint256 i; i < grants.length; ++i) {
            assertEq(grants[i].grantStart, 0);
            assertEq(grants[i].grantPeriod, 0);
            assertEq(grants[i].grantCliff, 0);

            assertEq(grants[i].unlockStart, 0);
            assertEq(grants[i].unlockPeriod, 0);
            assertEq(grants[i].unlockCliff, 0);

            assertEq(grants[i].amount, 0);
        }
    }

    function test_void_multiple_grants_after_granted() public {
        uint64 grantStart = uint64(block.timestamp) + 30 days;
        pool.grant(Alice, TimelockTokenPool.Grant(10_000e18, 0, grantStart, 0, 0, 0, 0, 0));
        pool.grant(Alice, TimelockTokenPool.Grant(20_000e18, 0, grantStart, 0, 0, 0, 0, 0));

        vm.prank(Vault);
        tko.approve(address(pool), 30_000e18);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);

        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        vm.warp(grantStart + 1);

        // Try to void the grant
        vm.expectRevert(TimelockTokenPool.NOTHING_TO_VOID.selector);
        pool.void(Alice);
    }

    function test_void_multiple_grants_in_the_middle() public {
        uint64 grantStart = uint64(block.timestamp);
        uint32 grantPeriod = 100 days;
        pool.grant(
            Alice,
            TimelockTokenPool.Grant(10_000e18, strikePrice1, grantStart, 0, grantPeriod, 0, 0, 0)
        );
        pool.grant(
            Alice,
            TimelockTokenPool.Grant(20_000e18, strikePrice2, grantStart, 0, grantPeriod, 0, 0, 0)
        );

        vm.prank(Vault);
        tko.approve(address(pool), 30_000e18);

        uint256 halfTimeWithdrawCost =
            (5000e18 / ONE_TKO_UNIT * strikePrice1) + (10_000e18 / ONE_TKO_UNIT * strikePrice2);

        vm.warp(grantStart + 50 days);
        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);

        assertEq(amountOwned, 15_000e18);
        assertEq(amountUnlocked, 15_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 15_000e18);
        assertEq(costToWithdraw, halfTimeWithdrawCost);

        pool.void(Alice);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 15_000e18);
        assertEq(amountUnlocked, 15_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 15_000e18);
        assertEq(costToWithdraw, halfTimeWithdrawCost);

        vm.warp(grantStart + 100 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 15_000e18);
        assertEq(amountUnlocked, 15_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 15_000e18);
        assertEq(costToWithdraw, halfTimeWithdrawCost);
    }

    function test_correct_strike_price() public {
        uint64 grantStart = uint64(block.timestamp);
        uint32 grantPeriod = 4 * 365 days;
        uint64 grantCliff = grantStart + 90 days;

        uint64 unlockStart = grantStart + 365 days;
        uint32 unlockPeriod = 4 * 365 days;
        uint64 unlockCliff = unlockStart + 365 days;

        uint64 strikePrice = 10_000; // 0.01 USDC if decimals are 6 (as in our test)

        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                10_000e18,
                strikePrice,
                grantStart,
                grantCliff,
                grantPeriod,
                unlockStart,
                unlockCliff,
                unlockPeriod
            )
        );
        vm.prank(Vault);
        tko.approve(address(pool), 10_000e18);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        // When withdraw (5 years later) - check if correct price is deducted
        vm.warp(grantStart + 5 * 365 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 10_000e18);

        // 10_000 TKO tokens * strikePrice
        uint256 payedUsdc = 10_000 * strikePrice;

        vm.prank(Alice);
        usdc.approve(address(pool), payedUsdc);

        vm.prank(Alice);
        pool.withdraw(100);
        assertEq(tko.balanceOf(Alice), 10_000e18);
        assertEq(usdc.balanceOf(Alice), 1_000_000_000e6 - payedUsdc);
    }

    function test_correct_strike_price_if_multiple_grants_different_price() public {
        uint64 grantStart = uint64(block.timestamp);
        uint32 grantPeriod = 4 * 365 days;
        uint64 grantCliff = grantStart + 90 days;

        uint64 unlockStart = grantStart + 365 days;
        uint32 unlockPeriod = 4 * 365 days;
        uint64 unlockCliff = unlockStart + 365 days;

        // Grant Alice 2 times (2x 10_000), with different strik price
        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                10_000e18,
                strikePrice1,
                grantStart,
                grantCliff,
                grantPeriod,
                unlockStart,
                unlockCliff,
                unlockPeriod
            )
        );

        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                10_000e18,
                strikePrice2,
                grantStart,
                grantCliff,
                grantPeriod,
                unlockStart,
                unlockCliff,
                unlockPeriod
            )
        );
        vm.prank(Vault);
        tko.approve(address(pool), 20_000e18);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);

        // When withdraw (5 years later) - check if correct price is deducted
        vm.warp(grantStart + 5 * 365 days);
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 20_000e18);
        assertEq(amountUnlocked, 20_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 20_000e18);

        // 10_000 TKO * strikePrice1 + 10_000 TKO * strikePrice2
        uint256 payedUsdc = 10_000 * strikePrice1 + 10_000 * strikePrice2;

        vm.prank(Alice);
        usdc.approve(address(pool), payedUsdc);

        vm.prank(Alice);
        pool.withdraw(100);
        assertEq(tko.balanceOf(Alice), 20_000e18);
        assertEq(usdc.balanceOf(Alice), 1_000_000_000e6 - payedUsdc);
    }

    function test_if_Alice_priced_out_with_grant2() public {
        uint64 grantStart = uint64(block.timestamp);
        uint32 grantPeriod = 4 * 365 days;
        uint64 grantCliff = grantStart + 90 days;

        uint64 unlockStart = grantStart + 365 days;
        uint32 unlockPeriod = 4 * 365 days;
        uint64 unlockCliff = unlockStart + 365 days;

        // 0.1 USDC if decimals are 6 (as in our test)
        uint64 tenCent = uint64(10 ** usdc.decimals() / 10);
        // 2 USDC if decimals are 6 (as  in our test)
        uint64 twoDollars = uint64(10 ** usdc.decimals() * 2);

        // Grant Alice 2 grants (1x 10_000, 2 x 2_000), with different strike price
        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                10_000e18,
                tenCent,
                grantStart,
                grantCliff,
                grantPeriod,
                unlockStart,
                unlockCliff,
                unlockPeriod
            )
        );

        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                3000e18,
                twoDollars,
                grantStart,
                grantCliff,
                grantPeriod,
                unlockStart,
                unlockCliff,
                unlockPeriod
            )
        );
        vm.prank(Vault);
        tko.approve(address(pool), 20_000e18);

        (
            uint128 amountOwned,
            uint128 amountUnlocked,
            uint128 amountWithdrawn,
            uint128 amountToWithdraw,
            uint128 costToWithdraw
        ) = pool.getMyGrantSummary(Alice, 100);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);

        // After some time let's see if return values are correct both for first and second (all)
        // grants
        vm.warp(grantStart + 5 * 365 days);

        // 10_000 TKO * 0.1
        uint256 grant1Price = 10_000 * tenCent;

        // If getMyGrantSummary(Alice, 0): 0 means, Alice does not really want any info. (But
        // supplying 0 no reverts tho)
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 0);
        assertEq(amountOwned, 0);
        assertEq(amountUnlocked, 0);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);

        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 1);
        assertEq(amountOwned, 10_000e18);
        assertEq(amountUnlocked, 10_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 10_000e18);
        assertEq(costToWithdraw, grant1Price);

        // 10_000 TKO * 0.1 + 3_000 TKO * 2.0
        uint256 allPrice = 10_000 * tenCent + 3000 * twoDollars;

        // Let's see how much she has to pay if she want to have both (all)
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 2);
        assertEq(amountOwned, 13_000e18);
        assertEq(amountUnlocked, 13_000e18);
        assertEq(amountWithdrawn, 0);
        assertEq(amountToWithdraw, 13_000e18);
        assertEq(amountToWithdraw, 13_000e18);
        assertEq(costToWithdraw, allPrice);

        vm.prank(Alice);
        usdc.approve(address(pool), allPrice);

        // Alice only wants to withdraw first (cheapest) grant because she is priced out, or dont
        // want to activate grant2 for that strike price, because it is too high.
        vm.prank(Alice);
        pool.withdraw(1);

        assertEq(tko.balanceOf(Alice), 10_000e18);
        assertEq(usdc.balanceOf(Alice), 1_000_000_000e6 - grant1Price);

        // After Alice withdrawing grant 1, she still has the grant 2 "non-withdrawn"
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 2);
        assertEq(amountOwned, 13_000e18);
        assertEq(amountUnlocked, 13_000e18);
        assertEq(amountWithdrawn, 10_000e18);
        assertEq(amountToWithdraw, 3000e18);
        assertEq(costToWithdraw, (allPrice - grant1Price));

        // Now the price consolidate, it is worth to withdraw the second one
        vm.prank(Alice);
        pool.withdraw(2); // grant 1 already withdrawn, but it is OK, Alice has to call withdraw
            // with nr. 2

        // After Alice withdrawing grant 1, she still has the grant 2 "non-withdrawn"
        (amountOwned, amountUnlocked, amountWithdrawn, amountToWithdraw, costToWithdraw) =
            pool.getMyGrantSummary(Alice, 2);
        assertEq(amountOwned, 13_000e18);
        assertEq(amountUnlocked, 13_000e18);
        assertEq(amountWithdrawn, 13_000e18);
        assertEq(amountToWithdraw, 0);
        assertEq(costToWithdraw, 0);
    }

    function test_new_grant_has_lower_price_than_first() public {
        uint64 grantStart = uint64(block.timestamp);
        uint32 grantPeriod = 4 * 365 days;
        uint64 grantCliff = grantStart + 90 days;

        uint64 unlockStart = grantStart + 365 days;
        uint32 unlockPeriod = 4 * 365 days;
        uint64 unlockCliff = unlockStart + 365 days;

        // 0.1 USDC if decimals are 6 (as in our test)
        uint64 tenCent = uint64(10 ** usdc.decimals() / 10);
        // 0.01 USDC if decimals are 6 (as  in our test)
        uint64 oneCent = uint64(10 ** usdc.decimals() / 100);

        // Grant Alice 2 grants (1x 10_000, 2 x 2_000), with different strike price
        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                10_000e18,
                tenCent,
                grantStart,
                grantCliff,
                grantPeriod,
                unlockStart,
                unlockCliff,
                unlockPeriod
            )
        );

        vm.expectRevert(TimelockTokenPool.GRANT_PRICE_SHALL_INCREASE.selector);
        pool.grant(
            Alice,
            TimelockTokenPool.Grant(
                3000e18,
                oneCent,
                grantStart,
                grantCliff,
                grantPeriod,
                unlockStart,
                unlockCliff,
                unlockPeriod
            )
        );
    }
}
