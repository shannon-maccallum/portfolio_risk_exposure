// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Platform} from "../src/Platform.sol";
import {ExposureOracle} from "../src/ExposureOracle.sol";
import {MockExchange} from "../src/MockExchange.sol";
import {MockToken} from "../src/MockToken.sol";
import {FundFactory} from "../src/FundFactory.sol";
import {ThemeFund} from "../src/ThemeFund.sol";

contract ThemeFundTest is Test {
    Platform platform;
    ExposureOracle oracle;
    MockExchange exchange;
    FundFactory factory;
    MockToken usd;

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    bytes32 AI;
    bytes32 OIL;
    address NVDA;
    address AMD;
    address MSFT;
    address AVGO;
    address GOOGL;
    address XOM;
    address CVX;

    function setUp() public {
        string[] memory themes = new string[](2);
        themes[0] = "AI";
        themes[1] = "Oil";
        string[] memory syms = new string[](7);
        syms[0] = "NVDA";
        syms[1] = "AMD";
        syms[2] = "MSFT";
        syms[3] = "AVGO";
        syms[4] = "GOOGL";
        syms[5] = "XOM";
        syms[6] = "CVX";

        vm.prank(admin);
        platform = new Platform(themes, syms);
        oracle = platform.oracle();
        exchange = platform.exchange();
        factory = platform.factory();
        usd = exchange.usd();
        AI = oracle.themeIdOf("AI");
        OIL = oracle.themeIdOf("Oil");
        NVDA = exchange.stockBySymbol("NVDA");
        AMD = exchange.stockBySymbol("AMD");
        MSFT = exchange.stockBySymbol("MSFT");
        AVGO = exchange.stockBySymbol("AVGO");
        GOOGL = exchange.stockBySymbol("GOOGL");
        XOM = exchange.stockBySymbol("XOM");
        CVX = exchange.stockBySymbol("CVX");

        // Round prices so expected values are easy to work out by hand.
        address[] memory toks = platform.stocks();
        uint256[] memory prices = new uint256[](7);
        prices[0] = 100e18; // NVDA
        prices[1] = 200e18; // AMD
        prices[2] = 400e18; // MSFT
        prices[3] = 300e18; // AVGO
        prices[4] = 250e18; // GOOGL
        prices[5] = 120e18; // XOM
        prices[6] = 150e18; // CVX
        bytes32[] memory th = new bytes32[](2);
        th[0] = AI;
        th[1] = OIL;
        // 10-K scores (AI, Oil) in bps
        uint16[] memory sc = new uint16[](14);
        sc[0] = 8970; sc[1] = 0; // NVDA
        sc[2] = 4790; sc[3] = 0; // AMD
        sc[4] = 4150; sc[5] = 0; // MSFT
        sc[6] = 3130; sc[7] = 0; // AVGO
        sc[8] = 1550; sc[9] = 0; // GOOGL
        sc[10] = 0; sc[11] = 8860; // XOM
        sc[12] = 0; sc[13] = 10000; // CVX
        vm.prank(admin);
        oracle.post(toks, prices, th, sc);

        vm.prank(alice);
        exchange.faucet();
        vm.prank(bob);
        exchange.faucet();
    }

    // ---------------------------------------------------------------- helpers

    function _rules() internal view returns (ThemeFund.Rule[] memory r) {
        r = new ThemeFund.Rule[](2);
        r[0] = ThemeFund.Rule({theme: AI, minBps: 6000, maxBps: 10000, maxTier: 3});
        r[1] = ThemeFund.Rule({theme: OIL, minBps: 0, maxBps: 500, maxTier: 1});
    }

    function _basket() internal view returns (address[] memory a, uint16[] memory w) {
        a = new address[](4);
        w = new uint16[](4);
        a[0] = NVDA; w[0] = 5000;
        a[1] = AMD; w[1] = 2000;
        a[2] = MSFT; w[2] = 2000;
        a[3] = GOOGL; w[3] = 1000;
    }

    function _launch() internal returns (ThemeFund fund) {
        (address[] memory a, uint16[] memory w) = _basket();
        vm.prank(alice);
        fund = ThemeFund(factory.createFund("Want AI, Avoid Oil", "AIXO", a, w, _rules()));
    }

    function _deposit(ThemeFund fund, address who, uint256 amt) internal returns (uint256 shares) {
        vm.startPrank(who);
        usd.approve(address(fund), amt);
        shares = fund.deposit(amt);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- launch

    function test_launch_setsRulesAndBasket() public {
        ThemeFund fund = _launch();
        assertEq(fund.name(), "Want AI, Avoid Oil");
        assertEq(fund.symbol(), "AIXO");
        assertEq(fund.creator(), alice);
        assertEq(fund.assets().length, 4);
        assertEq(fund.rules().length, 2);
        assertEq(fund.checksPassed(), 1);
        assertEq(fund.sharePrice(), 10e18);
        // AI = 0.5*89.7 + 0.2*47.9 + 0.2*41.5 + 0.1*15.5 = 64.28%
        assertEq(fund.exposureOf(AI), 6428);
        assertEq(fund.exposureOf(OIL), 0);
        assertEq(factory.fundCount(), 1);
        assertEq(factory.fundsBy(alice)[0], address(fund));
    }

    function test_launch_rejectsOilStock() public {
        address[] memory a = new address[](2);
        uint16[] memory w = new uint16[](2);
        a[0] = NVDA; w[0] = 9000;
        a[1] = XOM; w[1] = 1000;
        vm.expectRevert(abi.encodeWithSelector(ThemeFund.InvalidBasket.selector, "Oil: High (XOM)"));
        factory.createFund("Bad", "BAD", a, w, _rules());
    }

    function test_launch_rejectsLowAiBasket() public {
        address[] memory a = new address[](2);
        uint16[] memory w = new uint16[](2);
        a[0] = AVGO; w[0] = 5000;
        a[1] = GOOGL; w[1] = 5000;
        // 0.5*31.3 + 0.5*15.5 = 23.4%
        vm.expectRevert(abi.encodeWithSelector(ThemeFund.InvalidBasket.selector, "AI exposure 23.4% is below the 60.0% minimum"));
        factory.createFund("Weak", "WEAK", a, w, _rules());
    }

    function test_launch_rejectsBadRule() public {
        (address[] memory a, uint16[] memory w) = _basket();
        ThemeFund.Rule[] memory r = new ThemeFund.Rule[](1);
        r[0] = ThemeFund.Rule({theme: keccak256("Gold"), minBps: 0, maxBps: 100, maxTier: 3});
        vm.expectRevert(abi.encodeWithSelector(ThemeFund.InvalidRule.selector, 0));
        factory.createFund("X", "X", a, w, r);
        r[0] = ThemeFund.Rule({theme: AI, minBps: 7000, maxBps: 6000, maxTier: 3});
        vm.expectRevert(abi.encodeWithSelector(ThemeFund.InvalidRule.selector, 0));
        factory.createFund("X", "X", a, w, r);
    }

    function test_initialize_onlyOnce() public {
        ThemeFund fund = _launch();
        (address[] memory a, uint16[] memory w) = _basket();
        vm.expectRevert(ThemeFund.AlreadyInitialized.selector);
        fund.initialize(bob, "Hijack", "HJK", oracle, exchange, a, w, _rules());
        // The template itself can't be initialized either.
        ThemeFund impl = ThemeFund(factory.implementation());
        vm.expectRevert(ThemeFund.AlreadyInitialized.selector);
        impl.initialize(bob, "Hijack", "HJK", oracle, exchange, a, w, _rules());
    }

    // ---------------------------------------------------------------- checkBasket edge cases

    function test_checkBasket_messages() public {
        ThemeFund fund = _launch();
        address[] memory a;
        uint16[] memory w;
        bool ok;
        string memory why;

        (ok, why) = fund.checkBasket(new address[](0), new uint16[](0));
        assertFalse(ok);
        assertEq(why, "Basket is empty");

        a = new address[](2);
        w = new uint16[](1);
        a[0] = NVDA; a[1] = AMD; w[0] = 10000;
        (ok, why) = fund.checkBasket(a, w);
        assertEq(why, "Assets and weights differ in length");

        w = new uint16[](2);
        w[0] = 6000; w[1] = 3000;
        (ok, why) = fund.checkBasket(a, w);
        assertEq(why, "Weights must add up to 100%");

        w[0] = 10000; w[1] = 0;
        (ok, why) = fund.checkBasket(a, w);
        assertEq(why, "Zero weight for AMD");

        a[1] = NVDA; w[0] = 5000; w[1] = 5000;
        (ok, why) = fund.checkBasket(a, w);
        assertEq(why, "Duplicate asset NVDA");

        a[1] = address(0xdead);
        (ok, why) = fund.checkBasket(a, w);
        assertEq(why, "Asset has no oracle price");

        a = new address[](11);
        w = new uint16[](11);
        (ok, why) = fund.checkBasket(a, w);
        assertEq(why, "Too many assets (max 10)");

        a = new address[](1);
        w = new uint16[](1);
        a[0] = NVDA; w[0] = 10000;
        (ok, why) = fund.checkBasket(a, w);
        assertTrue(ok);
        assertEq(why, "");
    }

    function test_checkBasket_oilCeiling() public {
        // A rule with no per-stock ban but a 5% fund-level oil cap.
        ThemeFund.Rule[] memory r = new ThemeFund.Rule[](1);
        r[0] = ThemeFund.Rule({theme: OIL, minBps: 0, maxBps: 500, maxTier: 3});
        address[] memory a = new address[](2);
        uint16[] memory w = new uint16[](2);
        a[0] = NVDA; w[0] = 9000;
        a[1] = XOM; w[1] = 1000;
        // 0.1 * 88.6% = 8.86% -> "8.8%"
        vm.expectRevert(abi.encodeWithSelector(ThemeFund.InvalidBasket.selector, "Oil exposure 8.8% is above the 5.0% maximum"));
        factory.createFund("X", "X", a, w, r);
        w[0] = 9500; w[1] = 500; // 4.43% -> allowed
        address f = factory.createFund("X", "X", a, w, r);
        assertEq(ThemeFund(f).exposureOf(OIL), 443);
    }

    // ---------------------------------------------------------------- deposit / redeem math

    function test_deposit_firstDepositor() public {
        ThemeFund fund = _launch();
        uint256 shares = _deposit(fund, alice, 1000e18);
        assertEq(shares, 100e18); // $1,000 at $10/share
        assertEq(fund.balanceOf(alice), 100e18);
        assertEq(usd.balanceOf(alice), 9000e18);
        assertEq(fund.nav(), 1000e18);
        assertEq(fund.sharePrice(), 10e18);
        // $500 of NVDA at $100 = 5 tokens; $200 AMD at $200 = 1; $200 MSFT at $400 = 0.5; $100 GOOGL at $250 = 0.4
        assertEq(MockToken(NVDA).balanceOf(address(fund)), 5e18);
        assertEq(MockToken(AMD).balanceOf(address(fund)), 1e18);
        assertEq(MockToken(MSFT).balanceOf(address(fund)), 0.5e18);
        assertEq(MockToken(GOOGL).balanceOf(address(fund)), 0.4e18);
    }

    function test_navTracksPrices() public {
        ThemeFund fund = _launch();
        _deposit(fund, alice, 1000e18);
        vm.prank(admin);
        oracle.setPrice(NVDA, 120e18); // NVDA +20%: 5 * $20 = +$100
        assertEq(fund.nav(), 1100e18);
        assertEq(fund.sharePrice(), 11e18);
    }

    function test_secondDepositorPaysCurrentPrice() public {
        ThemeFund fund = _launch();
        _deposit(fund, alice, 1000e18);
        vm.prank(admin);
        oracle.setPrice(NVDA, 120e18); // share price now $11
        uint256 shares = _deposit(fund, bob, 1100e18);
        assertEq(shares, 100e18); // $1,100 / $11
        assertEq(fund.totalSupply(), 200e18);
        // Buying fractional tokens rounds down by a few wei; the newcomer absorbs it, not existing holders.
        assertApproxEqAbs(fund.sharePrice(), 11e18, 10);
        assertLe(fund.sharePrice(), 11e18);
    }

    function test_redeem_returnsFairShare() public {
        ThemeFund fund = _launch();
        _deposit(fund, alice, 1000e18);
        vm.prank(admin);
        oracle.setPrice(NVDA, 120e18);
        vm.prank(alice);
        uint256 out = fund.redeem(50e18); // half the fund = $550
        assertEq(out, 550e18);
        assertEq(usd.balanceOf(alice), 9550e18);
        assertEq(fund.totalSupply(), 50e18);
        assertEq(fund.nav(), 550e18);
        assertEq(fund.sharePrice(), 11e18);
    }

    function test_redeem_all() public {
        ThemeFund fund = _launch();
        _deposit(fund, alice, 1000e18);
        vm.prank(alice);
        uint256 out = fund.redeem(100e18);
        assertEq(out, 1000e18);
        assertEq(fund.totalSupply(), 0);
        assertEq(fund.nav(), 0);
        assertEq(fund.sharePrice(), 10e18);
    }

    function test_deposit_redeem_badInputs() public {
        ThemeFund fund = _launch();
        vm.prank(alice);
        vm.expectRevert(ThemeFund.ZeroAmount.selector);
        fund.deposit(0);
        vm.prank(alice);
        vm.expectRevert(ThemeFund.ZeroAmount.selector);
        fund.redeem(0);
        _deposit(fund, alice, 1000e18);
        vm.prank(bob);
        vm.expectRevert(ThemeFund.InsufficientShares.selector);
        fund.redeem(1);
        // No approval -> deposit fails
        vm.prank(bob);
        vm.expectRevert();
        fund.deposit(1e18);
    }

    function test_largeDeposit() public {
        ThemeFund fund = _launch();
        deal(address(usd), alice, 1e30); // a trillion test dollars
        uint256 shares = _deposit(fund, alice, 1e30);
        assertEq(shares, 1e29);
        assertEq(fund.nav(), 1e30);
    }

    // ---------------------------------------------------------------- basket changes

    function test_proposeBasket_rejectsXomAndRecordsIt() public {
        ThemeFund fund = _launch();
        _deposit(fund, alice, 1000e18);
        address[] memory a = new address[](5);
        uint16[] memory w = new uint16[](5);
        a[0] = NVDA; w[0] = 5000;
        a[1] = AMD; w[1] = 2000;
        a[2] = MSFT; w[2] = 1500;
        a[3] = GOOGL; w[3] = 1000;
        a[4] = XOM; w[4] = 500;
        vm.expectEmit(address(fund));
        emit ThemeFund.CheckFailed("basket change", "Oil: High (XOM)", 2);
        vm.prank(alice);
        bool changed = fund.proposeBasket(a, w);
        assertFalse(changed);
        assertEq(fund.checksFailed(), 1);
        assertEq(fund.lastFailReason(), "Oil: High (XOM)");
        assertEq(fund.assets().length, 4); // unchanged
        assertEq(fund.nav(), 1000e18); // nothing traded
    }

    function test_proposeBasket_acceptsValidChange() public {
        ThemeFund fund = _launch();
        _deposit(fund, alice, 1000e18);
        address[] memory a = new address[](2);
        uint16[] memory w = new uint16[](2);
        a[0] = NVDA; w[0] = 7000;
        a[1] = AVGO; w[1] = 3000;
        vm.prank(alice);
        assertTrue(fund.proposeBasket(a, w));
        assertEq(fund.assets().length, 2);
        assertEq(fund.checksPassed(), 2);
        assertEq(fund.nav(), 1000e18); // value preserved at oracle prices
        assertEq(MockToken(NVDA).balanceOf(address(fund)), 7e18);
        assertEq(MockToken(AVGO).balanceOf(address(fund)), 1e18);
        assertEq(MockToken(AMD).balanceOf(address(fund)), 0);
    }

    function test_proposeBasket_onlyCreator() public {
        ThemeFund fund = _launch();
        (address[] memory a, uint16[] memory w) = _basket();
        vm.prank(bob);
        vm.expectRevert(ThemeFund.NotCreator.selector);
        fund.proposeBasket(a, w);
    }

    // ---------------------------------------------------------------- enforcement

    function test_enforce_noViolation_recordsPass() public {
        ThemeFund fund = _launch();
        _deposit(fund, alice, 1000e18);
        vm.prank(stranger);
        uint256 bounty = fund.enforce();
        assertEq(bounty, 0);
        assertEq(fund.checksPassed(), 2);
        assertEq(usd.balanceOf(stranger), 0);
    }

    function test_enforce_sellsDriftedHoldingAndPaysBounty() public {
        ThemeFund fund = _launch();
        _deposit(fund, alice, 1000e18);
        // Simulated new filing: MSFT oil exposure jumps to 45% (High).
        vm.prank(admin);
        oracle.setScore(MSFT, OIL, 4500);

        vm.prank(stranger);
        uint256 bounty = fund.enforce();

        // MSFT holding was $200. Bounty = 0.5% = $1. $199 reinvested.
        assertEq(bounty, 1e18);
        assertEq(usd.balanceOf(stranger), 1e18);
        assertEq(MockToken(MSFT).balanceOf(address(fund)), 0);
        assertEq(fund.checksFailed(), 1);
        assertEq(fund.lastFailReason(), "Oil: High (MSFT)");

        address[] memory a = fund.assets();
        uint16[] memory w = fund.weights();
        assertEq(a.length, 3);
        assertEq(a[0], NVDA);
        assertEq(a[1], AMD);
        assertEq(a[2], GOOGL);
        // 50/20/10 rescaled to 100: 62.5 / 25 / 12.5
        assertEq(w[0], 6250);
        assertEq(w[1], 2500);
        assertEq(w[2], 1250);
        assertEq(fund.nav(), 999e18); // fund lost only the $1 bounty
        // The fund passes its rules again.
        (bool ok,) = fund.checkBasket(a, w);
        assertTrue(ok);

        // A second call finds nothing to fix and pays nothing.
        vm.prank(bob);
        assertEq(fund.enforce(), 0);
    }

    function test_enforce_allHoldingsBad_holdsCash() public {
        address[] memory a = new address[](1);
        uint16[] memory w = new uint16[](1);
        a[0] = NVDA; w[0] = 10000;
        vm.prank(alice);
        ThemeFund fund = ThemeFund(factory.createFund("Solo", "SOLO", a, w, _rules()));
        _deposit(fund, alice, 1000e18);
        vm.prank(admin);
        oracle.setScore(NVDA, OIL, 5000);
        vm.prank(stranger);
        uint256 bounty = fund.enforce();
        assertEq(bounty, 5e18);
        assertEq(fund.assets().length, 0);
        assertEq(usd.balanceOf(address(fund)), 995e18);
        assertEq(fund.nav(), 995e18);
        // Investors can still cash out.
        vm.prank(alice);
        assertEq(fund.redeem(100e18), 995e18);
    }

    // ---------------------------------------------------------------- oracle and exchange guards

    function test_oracle_onlyOwnerAndValidation() public {
        vm.expectRevert(ExposureOracle.NotOwner.selector);
        oracle.setPrice(NVDA, 1);
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ExposureOracle.ZeroPrice.selector, NVDA));
        oracle.setPrice(NVDA, 0);
        vm.expectRevert(abi.encodeWithSelector(ExposureOracle.ScoreTooHigh.selector, uint16(10001)));
        oracle.setScore(NVDA, AI, 10001);
        vm.expectRevert(abi.encodeWithSelector(ExposureOracle.UnknownTheme.selector, keccak256("Gold")));
        oracle.setScore(NVDA, keccak256("Gold"), 100);
        vm.expectRevert(ExposureOracle.LengthMismatch.selector);
        oracle.post(new address[](1), new uint256[](2), new bytes32[](0), new uint16[](0));
        oracle.transferOwnership(bob);
        vm.stopPrank();
        assertEq(oracle.owner(), bob);
    }

    function test_oracle_tiers() public view {
        assertEq(oracle.tierOf(NVDA, AI), 3);
        assertEq(oracle.tierOf(AVGO, AI), 2);
        assertEq(oracle.tierOf(XOM, AI), 0);
        assertEq(oracle.tierForScore(1), 1);
        assertEq(oracle.tierForScore(1499), 1);
        assertEq(oracle.tierForScore(1500), 2);
        assertEq(oracle.tierForScore(4000), 3);
        assertEq(oracle.tierName(0), "None");
        assertEq(oracle.tierName(1), "Low");
        assertEq(oracle.tierName(2), "Medium");
        assertEq(oracle.tierName(3), "High");
        assertEq(oracle.themeCount(), 2);
        assertEq(oracle.themeName(OIL), "Oil");
    }

    function test_exchange_guards() public {
        vm.expectRevert(abi.encodeWithSelector(MockExchange.NotAStock.selector, address(usd)));
        exchange.buy(address(usd), 1);
        vm.expectRevert(MockToken.NotMinter.selector);
        usd.mint(alice, 1);
        vm.expectRevert(MockToken.NotMinter.selector);
        usd.burn(alice, 1);
        assertEq(MockToken(NVDA).symbol(), "NVDA");
        assertEq(MockToken(NVDA).name(), "Simulated NVDA");
        assertEq(platform.stocks().length, 7);
    }

    function test_exchange_noPrice() public {
        string[] memory themes = new string[](1);
        themes[0] = "AI";
        string[] memory syms = new string[](1);
        syms[0] = "TEST";
        Platform p2 = new Platform(themes, syms);
        MockExchange ex2 = p2.exchange();
        address t = ex2.stockBySymbol("TEST");
        vm.expectRevert(abi.encodeWithSelector(MockExchange.NoPrice.selector, t));
        ex2.buy(t, 1);
    }
}
