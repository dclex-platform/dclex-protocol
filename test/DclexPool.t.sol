// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IDclexSwapCallback} from "../src/IDclexSwapCallback.sol";
import {InvalidDID, InvalidSmartcontract} from "dclex-blockchain/contracts/libs/Model.sol";
import {IFactory} from "dclex-blockchain/contracts/interfaces/IFactory.sol";
import {DclexPool} from "../src/DclexPool.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "../test/USDCMock.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {TokenBuilder} from "dclex-blockchain/contracts/dclex/TokenBuilder.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {SmartcontractIdentity} from "dclex-blockchain/contracts/dclex/SmartcontractIdentity.sol";
import {SignatureUtils} from "dclex-blockchain/contracts/dclex/SignatureUtils.sol";
import {DeployDclex} from "script/DeployDclex.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {DclexPythMock} from "./PythMock.sol";
import {TestBalance} from "./TestBalance.sol";

contract DclexRouterMock is IDclexSwapCallback {
    struct CallbackData {
        address recordBalanceToken;
    }

    uint256 private amountToBePaid;
    bool private amountToBePaidSet;
    bool public dclexSwapCallbackCalled;
    uint256 public recordedBalance;

    function dclexSwapCallback(address token, uint256 amount, bytes calldata callbackData) external {
        if (callbackData.length > 4) {
            CallbackData memory decodedData = abi.decode(callbackData, (CallbackData));
            recordedBalance = IERC20(decodedData.recordBalanceToken).balanceOf(address(this));
        }
        dclexSwapCallbackCalled = true;
        IERC20(token).transfer(msg.sender, amountToBePaidSet ? amountToBePaid: amount);
    }

    function setAmountToBePaid(uint256 _amountToBePaid) external {
        amountToBePaidSet = true;
        amountToBePaid = _amountToBePaid;
    }

    function reset() external{
        dclexSwapCallbackCalled = false;
    }
}

contract DclexPoolTest is Test, TestBalance {
    event Paused(address account);
    event Unpaused(address account);
    event FeeCurveUpdated(uint256 baseFeeRate, uint256 sensitivity);
    event LiquidityAdded(uint256 addedLiquidity, uint256 addedStockAmount, uint256 addedUsdcAmount);
    event LiquidityRemoved(uint256 removedLiquidity, uint256 removedStockAmount, uint256 removedUsdcAmount);
    event SwapExecuted(bool usdcInput, uint256 inputAmount, uint256 outputAmount, uint256 stockPrice, uint256 usdcPrice, address recipient);
    event ProtocolFeeRateChanged(uint256 feeRate);
    event ProtocolFeeWithdrawn(uint256 stocksWithdrawn, uint256 usdcWithdrawn, address recipient);

    bytes32 constant internal AAPL_PRICE_FEED_ID = bytes32(uint256(0x1));
    bytes32 constant internal NVDA_PRICE_FEED_ID = bytes32(uint256(0x2));
    bytes32 constant internal USDC_PRICE_FEED_ID = bytes32(uint256(0x3));
    bytes[] internal PYTH_DATA = new bytes[](0);
    address internal POOL_ADMIN = makeAddr("pool_admin");
    address internal ADMIN = makeAddr("admin");
    address internal MASTER_ADMIN = makeAddr("master_admin");
    address internal USER_1 = makeAddr("user_1");
    address internal USER_2 = makeAddr("user_2");
    address internal RECEIVER_1 = makeAddr("receiver_1");
    address internal RECEIVER_2 = makeAddr("receiver_2");
    DclexPool internal aaplPool;
    DclexPool internal nvdaPool;
    DigitalIdentity internal digitalIdentity;
    SmartcontractIdentity internal contractIdentity;
    TokenBuilder internal tokenBuilder;
    Factory internal stocksFactory;
    Stock internal aaplStock;
    Stock internal nvdaStock;
    USDCMock internal usdcMock;
    DclexPythMock pythMock;
    DclexRouterMock routerMock1;
    DclexRouterMock routerMock2;

    receive() external payable {}

    function setUp() public {
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(ADMIN, MASTER_ADMIN);
        digitalIdentity = contracts.digitalIdentity;
        stocksFactory = contracts.stocksFactory;
        contractIdentity = contracts.contractIdentity;

        usdcMock = new USDCMock("USDC", "USD Coin");
        pythMock = new DclexPythMock();
        vm.deal(address(pythMock), 1 ether);
        vm.startPrank(ADMIN);
        stocksFactory.createStocks("Apple", "AAPL");
        stocksFactory.createStocks("NVIDIA", "NVDA");
        vm.stopPrank();
        aaplStock = Stock(stocksFactory.stocks("AAPL"));
        nvdaStock = Stock(stocksFactory.stocks("NVDA"));
        aaplPool = new DclexPool(IFactory(address(stocksFactory)), pythMock.getPyth(), aaplStock, usdcMock, AAPL_PRICE_FEED_ID, USDC_PRICE_FEED_ID, POOL_ADMIN);
        nvdaPool = new DclexPool(IFactory(address(stocksFactory)), pythMock.getPyth(), nvdaStock, usdcMock, NVDA_PRICE_FEED_ID, USDC_PRICE_FEED_ID, POOL_ADMIN);
        vm.prank(ADMIN);
        contractIdentity.mintAdmin(address(aaplPool));
        vm.prank(ADMIN);
        contractIdentity.mintAdmin(address(nvdaPool));
        updatePrice(USDC_PRICE_FEED_ID, 1 ether);
        updatePrice(AAPL_PRICE_FEED_ID, 1 ether);
        updatePrice(NVDA_PRICE_FEED_ID, 1 ether);
        setupAccount(address(this));
        setupAccount(USER_1);
        setupAccount(USER_2);
        vm.startPrank(ADMIN);
        digitalIdentity.mintAdmin(RECEIVER_1, 0, "");
        digitalIdentity.mintAdmin(RECEIVER_2, 0, "");
        vm.stopPrank();
        routerMock1 = new DclexRouterMock();
        routerMock2 = new DclexRouterMock();
        setupAccount(address(routerMock1));
        setupAccount(address(routerMock2));
    }

    modifier liquidityMinted() {
        address liquidityProvider = makeAddr("liquidityProvider");
        vm.startPrank(ADMIN);
        digitalIdentity.mintAdmin(liquidityProvider, 0, "");
        vm.stopPrank();
        vm.startPrank(MASTER_ADMIN);
        stocksFactory.forceMintStocks("AAPL", liquidityProvider, 5000 ether);
        stocksFactory.forceMintStocks("NVDA", liquidityProvider, 5000 ether);
        vm.stopPrank();
        usdcMock.mint(liquidityProvider, 10000e6);
        vm.startPrank(liquidityProvider);
        aaplStock.approve(address(aaplPool), 5000 ether);
        nvdaStock.approve(address(nvdaPool), 5000 ether);
        usdcMock.approve(address(aaplPool), 5000e6);
        usdcMock.approve(address(nvdaPool), 5000e6);
        aaplPool.initialize(5000 ether, 5000e6, PYTH_DATA);
        nvdaPool.initialize(5000 ether, 5000e6, PYTH_DATA);
        vm.stopPrank();
        _;
    }

    function setupAccount(address account) private {
        usdcMock.mint(account, 100000e6);
        vm.prank(ADMIN);
        if (account.code.length == 0) {
            digitalIdentity.mintAdmin(account, 0, "");
        } else {
            contractIdentity.mintAdmin(account);
        }
        vm.startPrank(MASTER_ADMIN);
        stocksFactory.forceMintStocks("AAPL", account, 100000 ether);
        stocksFactory.forceMintStocks("NVDA", account, 10000 ether);
        vm.startPrank(account);
        aaplStock.approve(address(aaplPool), 100000 ether);
        nvdaStock.approve(address(nvdaPool), 100000 ether);
        usdcMock.approve(address(aaplPool), 100000e6);
        usdcMock.approve(address(nvdaPool), 100000e6);
        vm.stopPrank();
    }

    function updatePrice(bytes32 priceFeedId, uint256 price) private {
        skip(1);
        pythMock.updatePrice(priceFeedId, price);
    }

    function setPoolStockBalance(DclexPool pool, uint256 desiredAmount) private {
        IERC20 stockToken = pool.stockToken();
        uint256 poolBalance = stockToken.balanceOf(address(pool));
        if (desiredAmount < poolBalance) {
            vm.prank(address(pool));
            stockToken.transfer(address(this), poolBalance - desiredAmount);
        } else {
            stockToken.transfer(address(pool), desiredAmount - poolBalance);
        }
        assertEq(pool.stockToken().balanceOf(address(pool)), desiredAmount);
    }

    function setPoolUSDCBalance(DclexPool pool, uint256 desiredAmount) private {
        uint256 poolBalance = usdcMock.balanceOf(address(pool));
        if (desiredAmount < poolBalance) {
            vm.prank(address(pool));
            usdcMock.transfer(address(this), poolBalance - desiredAmount);
        } else {
            usdcMock.transfer(address(pool), desiredAmount - poolBalance);
        }
        assertEq(usdcMock.balanceOf(address(pool)), desiredAmount);
    }

    function setPoolStocksProportion(DclexPool pool, bytes32 stockPriceFeedId, uint256 desiredProportion) private {
        if (desiredProportion == 1 ether) {
            setPoolUSDCBalance(pool, 0);
            return;
        }
        uint256 usdcBalance = usdcMock.balanceOf(address(pool));
        uint256 currentStockPrice = pythMock.getPrice(stockPriceFeedId);
        uint256 desiredStockBalance = usdcBalance * desiredProportion * 1e30 / (currentStockPrice * (1e18 - desiredProportion));
        setPoolStockBalance(pool, desiredStockBalance);
    }

    function assertOutputFeeRate(uint256 expectedFeeRate, uint256 outputReceived, uint256 netOutput) public pure {
        uint256 feeRate = 1e18 * (netOutput - outputReceived) / netOutput;
        assertApproxEqAbsDecimal(feeRate, expectedFeeRate, 0.001 ether, 18);
    }

    function assertInputFeeRate(uint256 expectedFeeRate, uint256 inputPaid, uint256 netInput) public pure {
        uint256 feeRate = 1e18 * (inputPaid - netInput) / netInput;
        assertApproxEqAbsDecimal(feeRate, expectedFeeRate, 0.001 ether, 18);
    }

    function assertStockToUSDCExactInputFeeRate(DclexPool pool, uint256 expectedFeeRate) public {
        recordBalance(address(usdcMock), address(this));
        pool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        int256 balanceChange = getBalanceChange();
        int256 feeRate = (1e6 - balanceChange) * 1e12;
        assertApproxEqAbsDecimal(feeRate, int256(expectedFeeRate), 0.001 ether, 18);
    }

    function assertStockToUSDCExactOutputFeeRate(DclexPool pool, uint256 expectedFeeRate) public {
        recordBalance(address(aaplStock), address(this));
        pool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        int256 balanceChange = getBalanceChange();
        int256 feeRate = -balanceChange - 1e18;
        assertApproxEqAbsDecimal(feeRate, int256(expectedFeeRate), 0.001 ether, 18);
    }

    function assertUSDCToStockExactInputFeeRate(DclexPool pool, uint256 expectedFeeRate) public {
        recordBalance(address(aaplStock), address(this));
        pool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        int256 balanceChange = getBalanceChange();
        int256 feeRate = 1e18 - balanceChange;
        assertApproxEqAbsDecimal(feeRate, int256(expectedFeeRate), 0.001 ether, 18);
    }

    function assertUSDCToStockExactOutputFeeRate(DclexPool pool, uint256 expectedFeeRate) public {
        recordBalance(address(usdcMock), address(this));
        pool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        int256 balanceChange = getBalanceChange();
        int256 feeRate = (-balanceChange - 1e6) * 1e12;
        assertApproxEqAbsDecimal(feeRate, int256(expectedFeeRate), 0.001 ether, 18);
    }

    function dclexSwapCallback(address token, uint256 amount, bytes calldata) external {
        IERC20(token).transfer(msg.sender, amount);
    }

    function testSwapExactOutputSendsBackRequestedTokensAmount() public liquidityMinted {
        uint256 outputBalanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        uint256 outputBalanceAfter = aaplStock.balanceOf(address(this));
        assertEq(outputBalanceAfter - outputBalanceBefore, 1 ether);

        outputBalanceBefore = nvdaStock.balanceOf(address(this));
        nvdaPool.swapExactOutput(true, 10.000001 ether, address(this), "", PYTH_DATA);
        outputBalanceAfter = nvdaStock.balanceOf(address(this));
        assertEq(outputBalanceAfter - outputBalanceBefore, 10.000001 ether);

        outputBalanceBefore = usdcMock.balanceOf(address(this));
        nvdaPool.swapExactOutput(false, 300e6, address(this), "", PYTH_DATA);
        outputBalanceAfter = usdcMock.balanceOf(address(this));
        assertEq(outputBalanceAfter - outputBalanceBefore, 300e6);
    }

    function testSwapExactOutputSendsTokensToRecipient() public liquidityMinted {
        uint256 outputBalanceBefore = aaplStock.balanceOf(address(routerMock1));
        vm.prank(address(routerMock2));
        aaplPool.swapExactOutput(true, 1 ether, address(routerMock1), "", PYTH_DATA);
        uint256 outputBalanceAfter = aaplStock.balanceOf(address(routerMock1));
        assertEq(outputBalanceAfter - outputBalanceBefore, 1 ether);

        outputBalanceBefore = aaplStock.balanceOf(address(routerMock2));
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, address(routerMock2), "", PYTH_DATA);
        outputBalanceAfter = aaplStock.balanceOf(address(routerMock2));
        assertEq(outputBalanceAfter - outputBalanceBefore, 1 ether);
    }

    function testSwapExactOutputCallsBackIntoCaller() public liquidityMinted {
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);
        assertTrue(routerMock1.dclexSwapCallbackCalled());
        assertFalse(routerMock2.dclexSwapCallbackCalled());

        routerMock1.reset();

        vm.prank(address(routerMock2));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);
        assertFalse(routerMock1.dclexSwapCallbackCalled());
        assertTrue(routerMock2.dclexSwapCallbackCalled());
    }

    function testSwapExactOutputCallsBackWithInputTokenAmountToBePaid() public liquidityMinted {
        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(usdcMock), 1e6, "")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);

        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(usdcMock), 80e6, "")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 4 ether, USER_1, "", PYTH_DATA);
    }

    function testSwapExactOutputCallsBackWithInputTokenAddress() public liquidityMinted {
        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(usdcMock), 1e6, "")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);

        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(aaplStock), 1 ether, "")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(false, 1e6, USER_1, "", PYTH_DATA);

        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(nvdaStock), 1 ether, "")));
        vm.prank(address(routerMock1));
        nvdaPool.swapExactOutput(false, 1e6, USER_1, "", PYTH_DATA);
    }

    function testSwapExactOutputCallsBackWithDataPassedByCaller() public liquidityMinted {
        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(usdcMock), 1e6, hex"1234")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, hex"1234", PYTH_DATA);

        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(usdcMock), 1e6, hex"ABCD")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, hex"ABCD", PYTH_DATA);
    }

    function testSwapExactOutputRevertsIfCallerPaysInCallbackLessThanGivenAmount() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        routerMock1.setAmountToBePaid(0);
        vm.prank(address(routerMock1));
        vm.expectRevert(DclexPool.DclexPool__InsufficientInputAmount.selector);
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);

        routerMock1.setAmountToBePaid(10e6);
        vm.prank(address(routerMock1));
        vm.expectRevert(DclexPool.DclexPool__InsufficientInputAmount.selector);
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);

        routerMock1.setAmountToBePaid(20e6 - 1);
        vm.prank(address(routerMock1));
        vm.expectRevert(DclexPool.DclexPool__InsufficientInputAmount.selector);
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);
    }

    function testSwapExactOutputDoesNotRevertIfCallerPaysInCallbackGivenAmountOrMore() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        routerMock1.setAmountToBePaid(20e6);
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);

        routerMock1.setAmountToBePaid(20e6 + 1);
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);

        routerMock1.setAmountToBePaid(30e6);
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);
    }

    function testSwapExactOutputSendsOutputTokensBeforeCallingCallback() public liquidityMinted {
        DclexRouterMock.CallbackData memory data = DclexRouterMock.CallbackData(address(aaplStock));
        uint256 outputBalanceBefore = aaplStock.balanceOf(address(this));
        vm.prank(address(routerMock1));
        aaplPool.swapExactOutput(true, 1 ether, address(routerMock1), abi.encode(data), PYTH_DATA);
        uint256 balanceChangeOnCallback = routerMock1.recordedBalance() - outputBalanceBefore;
        assertEq(balanceChangeOnCallback, 1 ether);
    }

    function testBuySwapExactOutputTakesInputTokenAmountEqualInValueToRequestedOutput() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 5.05 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreased(101e6);

        updatePrice(AAPL_PRICE_FEED_ID, 0.001 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 0.01 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreased(0.00001e6);
    }

    function testSellSwapExactOutputTakesInputTokenAmountEqualInValueToRequestedOutput() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        updatePrice(NVDA_PRICE_FEED_ID, 30 ether);

        recordBalance(address(nvdaStock), address(this));
        nvdaPool.swapExactOutput(false, 3, address(this), "", PYTH_DATA);
        assertBalanceDecreased(0.0000001 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 2, address(this), "", PYTH_DATA);
        assertBalanceDecreased(0.0000001 ether);

        updatePrice(NVDA_PRICE_FEED_ID, 0.0001 ether);

        recordBalance(address(nvdaStock), address(this));
        nvdaPool.swapExactOutput(false, 0.1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreased(1000 ether);
    }

    function testBuySwapExactOutputReturnsFinalInputTokenAmount() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        uint256 result = aaplPool.swapExactOutput(true, 5.05 ether, address(this), "", PYTH_DATA);
        assertEq(result, 101e6);
    }

    function testSellSwapExactOutputReturnsFinalInputTokenAmount() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        uint256 result = aaplPool.swapExactOutput(false, 101e6, address(this), "", PYTH_DATA);
        assertEq(result, 5.05 ether);
    }

    function testBuyExactOutputRevertsIfItWouldDrainPoolOutOfStocks() public liquidityMinted {
        uint256 aaplPoolBalance = aaplStock.balanceOf(address(aaplPool));
        vm.expectRevert(DclexPool.DclexPool__NotEnoughPoolLiquidity.selector);
        aaplPool.swapExactOutput(true, aaplPoolBalance, address(this), "", PYTH_DATA);

        vm.expectRevert(DclexPool.DclexPool__NotEnoughPoolLiquidity.selector);
        aaplPool.swapExactOutput(true, aaplPoolBalance + 1 ether, address(this), "", PYTH_DATA);
    }

    function testSellExactOutputRevertsIfItWouldDrainPoolOutOfUsdc() public liquidityMinted {
        uint256 usdcPoolBalance = usdcMock.balanceOf(address(aaplPool));
        vm.expectRevert(DclexPool.DclexPool__NotEnoughPoolLiquidity.selector);
        aaplPool.swapExactOutput(false, usdcPoolBalance, address(this), "", PYTH_DATA);

        vm.expectRevert(DclexPool.DclexPool__NotEnoughPoolLiquidity.selector);
        aaplPool.swapExactOutput(false, usdcPoolBalance + 1e6, address(this), "", PYTH_DATA);
    }

    function testSellExactOutputTakesStockMultiplierIntoAccount() public liquidityMinted {
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreased(1 ether);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 2, 1);
        updatePrice(AAPL_PRICE_FEED_ID, 0.5 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);  // 2 AAPL shares
        assertBalanceDecreased(1 ether);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 1, 2);
        updatePrice(AAPL_PRICE_FEED_ID, 2 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);  // 0.5 AAPL shares
        assertBalanceDecreased(1 ether);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 4, 5);
        updatePrice(AAPL_PRICE_FEED_ID, 1.25 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);  // 0.8 AAPL shares
        assertBalanceDecreased(1 ether);
    }

    function testBuyExactOutputTakesStockMultiplierIntoAccount() public liquidityMinted {
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreased(1e6);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 2, 1);
        updatePrice(AAPL_PRICE_FEED_ID, 0.5 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);  // 2 AAPL shares
        assertBalanceDecreased(1e6);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 1, 2);
        updatePrice(AAPL_PRICE_FEED_ID, 2 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);  // 0.5 AAPL shares
        assertBalanceDecreased(1e6);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 4, 5);
        updatePrice(AAPL_PRICE_FEED_ID, 1.25 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);  // 0.8 AAPL shares
        assertBalanceDecreased(1e6);
    }

    function testSellSwapExactOutputTakesUsdcPriceIntoAccount() public liquidityMinted {
        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreased(0.8 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 10e6, address(this), "", PYTH_DATA);
        assertBalanceDecreased(8 ether);

        updatePrice(USDC_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreased(0.5 ether);

        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreased(0.04 ether);
    }

    function testBuySwapExactOutputTakesUsdcPriceIntoAccount() public liquidityMinted {
        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreased(1.25e6);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 10 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreased(12.5e6);

        updatePrice(USDC_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreased(2e6);

        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreased(25e6);
    }

    function testSwapExactOutputRoundsTakenInputTokenAmountUp() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 3 ether);
        uint256 inputBalanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        uint256 inputBalanceAfter = aaplStock.balanceOf(address(this));
        assertEq(inputBalanceBefore - inputBalanceAfter, 333333333333333334);
    }

    function testSwapExactInputTakesRequestedTokensAmount() public liquidityMinted {
        uint256 inputBalanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        uint256 inputBalanceAfter = aaplStock.balanceOf(address(this));
        assertEq(inputBalanceBefore - inputBalanceAfter, 1 ether);

        inputBalanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.swapExactInput(true, 1, address(this), "", PYTH_DATA);
        inputBalanceAfter = usdcMock.balanceOf(address(this));
        assertEq(inputBalanceBefore - inputBalanceAfter, 1);

        inputBalanceBefore = usdcMock.balanceOf(address(this));
        nvdaPool.swapExactInput(true, 15e6, address(this), "", PYTH_DATA);
        inputBalanceAfter = usdcMock.balanceOf(address(this));
        assertEq(inputBalanceBefore - inputBalanceAfter, 15e6);

        inputBalanceBefore = nvdaStock.balanceOf(address(this));
        nvdaPool.swapExactInput(false, 20.00001 ether, address(this), "", PYTH_DATA);
        inputBalanceAfter = nvdaStock.balanceOf(address(this));
        assertEq(inputBalanceBefore - inputBalanceAfter, 20.00001 ether);
    }

    function testSwapExactInputSendsOutputTokensToRecipient() public liquidityMinted {
        recordBalance(address(usdcMock), USER_1);
        vm.prank(address(routerMock2));
        aaplPool.swapExactInput(false, 1 ether, USER_1, "", PYTH_DATA);
        assertBalanceIncreased(1e6);

        recordBalance(address(usdcMock), USER_2);
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(false, 1 ether, USER_2, "", PYTH_DATA);
        assertBalanceIncreased(1e6);
    }

    function testSwapExactInputCallsBackIntoCaller() public liquidityMinted {
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(true, 1e6, USER_1, "", PYTH_DATA);
        assertTrue(routerMock1.dclexSwapCallbackCalled());
        assertFalse(routerMock2.dclexSwapCallbackCalled());

        routerMock1.reset();

        vm.prank(address(routerMock2));
        aaplPool.swapExactInput(true, 1e6, USER_1, "", PYTH_DATA);
        assertFalse(routerMock1.dclexSwapCallbackCalled());
        assertTrue(routerMock2.dclexSwapCallbackCalled());
    }

    function testSwapExactInputCallsBackWithInputTokenAmountToBePaid() public liquidityMinted {
        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(aaplStock), 1 ether, "")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(false, 1 ether, USER_1, "", PYTH_DATA);

        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(usdcMock), 5e6, "")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(true, 5e6, USER_1, "", PYTH_DATA);
    }

    function testSwapExactInputCallsBackWithInputTokenAddress() public liquidityMinted {
        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(usdcMock), 1e6, "")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(true, 1e6, USER_1, "", PYTH_DATA);

        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(aaplStock), 1 ether, "")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(false, 1 ether, USER_1, "", PYTH_DATA);

        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(nvdaStock), 1 ether, "")));
        vm.prank(address(routerMock1));
        nvdaPool.swapExactInput(false, 1 ether, USER_1, "", PYTH_DATA);
    }

    function testSwapExactInputCallsBackWithDataPassedByCaller() public liquidityMinted {
        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(aaplStock), 1 ether, hex"1234")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(false, 1 ether, USER_1, hex"1234", PYTH_DATA);

        vm.expectCall(address(routerMock1), abi.encodeCall(routerMock1.dclexSwapCallback, (address(aaplStock), 1 ether, hex"ABCD")));
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(false, 1 ether, USER_1, hex"ABCD", PYTH_DATA);
    }

    function testSwapExactInputRevertsIfCallerPaysInCallbackLessThanGivenAmount() public liquidityMinted {
        routerMock1.setAmountToBePaid(0);
        vm.prank(address(routerMock1));
        vm.expectRevert(DclexPool.DclexPool__InsufficientInputAmount.selector);
        aaplPool.swapExactInput(false, 20 ether, USER_1, "", PYTH_DATA);

        routerMock1.setAmountToBePaid(10 ether);
        vm.prank(address(routerMock1));
        vm.expectRevert(DclexPool.DclexPool__InsufficientInputAmount.selector);
        aaplPool.swapExactInput(false, 20 ether, USER_1, "", PYTH_DATA);

        routerMock1.setAmountToBePaid(20 ether - 1);
        vm.prank(address(routerMock1));
        vm.expectRevert(DclexPool.DclexPool__InsufficientInputAmount.selector);
        aaplPool.swapExactInput(false, 20 ether, USER_1, "", PYTH_DATA);
    }

    function testSwapExactInputDoesNotRevertIfCallerPaysInCallbackGivenAmountOrMore() public liquidityMinted {
        routerMock1.setAmountToBePaid(20 ether);
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(false, 20 ether, USER_1, "", PYTH_DATA);

        routerMock1.setAmountToBePaid(20 ether + 1);
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(false, 20 ether, USER_1, "", PYTH_DATA);

        routerMock1.setAmountToBePaid(30 ether);
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(false, 20 ether, USER_1, "", PYTH_DATA);
    }

    function testSwapExactInputSendsOutputTokensBeforeCallingCallback() public liquidityMinted {
        DclexRouterMock.CallbackData memory data = DclexRouterMock.CallbackData(address(aaplStock));
        uint256 outputBalanceBefore = aaplStock.balanceOf(address(this));
        vm.prank(address(routerMock1));
        aaplPool.swapExactInput(true, 1e6, address(routerMock1), abi.encode(data), PYTH_DATA);
        uint256 balanceChangeOnCallback = routerMock1.recordedBalance() - outputBalanceBefore;
        assertEq(balanceChangeOnCallback, 1 ether);
    }

    function testBuySwapExactInputSendsOutputTokenAmountEqualInValueToSentInputTokens() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        updatePrice(NVDA_PRICE_FEED_ID, 30 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 2, address(this), "", PYTH_DATA);
        assertBalanceIncreased(0.0000001 ether);

        recordBalance(address(nvdaStock), address(this));
        nvdaPool.swapExactInput(true, 3, address(this), "", PYTH_DATA);
        assertBalanceIncreased(0.0000001 ether);

        updatePrice(AAPL_PRICE_FEED_ID, 0.001 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1.0001e6, address(this), "", PYTH_DATA);
        assertBalanceIncreased(1000.1 ether);
    }

    function testSellSwapExactInputSendsOutputTokenAmountEqualInValueToSentInputTokens() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        updatePrice(NVDA_PRICE_FEED_ID, 30 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 5.05 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreased(101e6);

        recordBalance(address(usdcMock), address(this));
        nvdaPool.swapExactInput(false, 10 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreased(300e6);

        updatePrice(AAPL_PRICE_FEED_ID, 0.001 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 0.1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreased(0.0001e6);
    }

    function testBuySwapExactIntputReturnsFinalInputTokenAmount() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        uint256 result = aaplPool.swapExactInput(true, 101e6, address(this), "", PYTH_DATA);
        assertEq(result, 5.05 ether);
    }

    function testSellSwapExactInputReturnsFinalInputTokenAmount() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        uint256 result = aaplPool.swapExactInput(false, 5.05 ether, address(this), "", PYTH_DATA);
        assertEq(result, 101e6);
    }

    function testSwapExactInputRoundsGivenOutputTokenAmountDown() public liquidityMinted {
        updatePrice(AAPL_PRICE_FEED_ID, 3 ether);
        uint256 outputBalanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        uint256 outputBalanceAfter = aaplStock.balanceOf(address(this));
        assertEq(outputBalanceAfter - outputBalanceBefore, 333333333333333333);
    }

    function testSellSwapExactInputTakesUsdcPriceIntoAccount() public liquidityMinted {
        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreased(1.25e6);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 10 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreased(12.5e6);

        updatePrice(USDC_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreased(2e6);

        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreased(25e6);
    }

    function testSellExactInputTakesStockMultiplierIntoAccount() public liquidityMinted {
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreased(1e6);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 2, 1);
        updatePrice(AAPL_PRICE_FEED_ID, 0.5 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);  // 2 AAPL shares
        assertBalanceIncreased(1e6);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 1, 2);
        updatePrice(AAPL_PRICE_FEED_ID, 2 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);  // 0.5 AAPL shares
        assertBalanceIncreased(1e6);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 4, 5);
        updatePrice(AAPL_PRICE_FEED_ID, 1.25 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);  // 0.8 AAPL shares
        assertBalanceIncreased(1e6);
    }

    function testBuyExactInputTakesStockMultiplierIntoAccount() public liquidityMinted {
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreased(1 ether);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 2, 1);
        updatePrice(AAPL_PRICE_FEED_ID, 0.5 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);  // 2 AAPL shares
        assertBalanceIncreased(1 ether);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 1, 2);
        updatePrice(AAPL_PRICE_FEED_ID, 2 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);  // 0.5 AAPL shares
        assertBalanceIncreased(1 ether);

        vm.prank(ADMIN);
        stocksFactory.setStockMultiplier("AAPL", 4, 5);
        updatePrice(AAPL_PRICE_FEED_ID, 1.25 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);  // 0.8 AAPL shares
        assertBalanceIncreased(1 ether);
    }

    function testBuySwapExactInputTakesUsdcPriceIntoAccount() public liquidityMinted {
        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreased(0.8 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 10e6, address(this), "", PYTH_DATA);
        assertBalanceIncreased(8 ether);

        updatePrice(USDC_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreased(0.5 ether);

        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreased(0.04 ether);
    }

    function testBuyExactInputRevertsIfItWouldDrainPoolOutOfStocks() public liquidityMinted {
        uint256 aaplPoolBalance = aaplStock.balanceOf(address(aaplPool));
        uint256 usdcInputToTakeAllStocks = aaplPoolBalance / 1e12;
        vm.expectRevert(DclexPool.DclexPool__NotEnoughPoolLiquidity.selector);
        aaplPool.swapExactInput(true, usdcInputToTakeAllStocks, address(this), "", PYTH_DATA);

        vm.expectRevert(DclexPool.DclexPool__NotEnoughPoolLiquidity.selector);
        aaplPool.swapExactInput(true, usdcInputToTakeAllStocks + 1e6, address(this), "", PYTH_DATA);
    }

    function testSellExactInputRevertsIfItWouldDrainPoolOutOfUsdc() public liquidityMinted {
        uint256 usdcPoolBalance = usdcMock.balanceOf(address(aaplPool));
        uint256 aaplInputToTakeAllUsdc = usdcPoolBalance * 1e12;
        vm.expectRevert(DclexPool.DclexPool__NotEnoughPoolLiquidity.selector);
        aaplPool.swapExactInput(false, aaplInputToTakeAllUsdc, address(this), "", PYTH_DATA);

        vm.expectRevert(DclexPool.DclexPool__NotEnoughPoolLiquidity.selector);
        aaplPool.swapExactInput(false, aaplInputToTakeAllUsdc + 1 ether, address(this), "", PYTH_DATA);
    }

    function testInitializeMintsLPTokensAmountEqualToDepositedTokensUsdValue() public {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        recordBalance(address(aaplPool), address(this));
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);
        assertBalanceIncreased(21 ether);

        updatePrice(NVDA_PRICE_FEED_ID, 30 ether);
        recordBalance(address(nvdaPool), address(this));
        nvdaPool.initialize(3 ether, 20e6, PYTH_DATA);
        assertBalanceIncreased(3 * 30 ether + 20 ether);
    }

    function testInitializeMintsTokensToCaller() public {
        uint256 balanceBefore = aaplPool.balanceOf(USER_1);
        vm.prank(USER_1);
        aaplPool.initialize(0.5 ether, 0.5e6, PYTH_DATA);
        uint256 balanceAfter = aaplPool.balanceOf(USER_1);
        assertEq(balanceAfter - balanceBefore, 1 ether);

        balanceBefore = nvdaPool.balanceOf(USER_2);
        vm.prank(USER_2);
        nvdaPool.initialize(0.5 ether, 0.5e6, PYTH_DATA);
        balanceAfter = nvdaPool.balanceOf(USER_2);
        assertEq(balanceAfter - balanceBefore, 1 ether);
    }

    function testInitializeTakesTakesPassedUsdcAmount() public {
        recordBalance(address(usdcMock), address(this));
        aaplPool.initialize(1 ether, 1, PYTH_DATA);
        assertBalanceDecreased(1);

        recordBalance(address(usdcMock), address(this));
        nvdaPool.initialize(2 ether, 5e6, PYTH_DATA);
        assertBalanceDecreased(5e6);
    }

    function testInitializeTakesPassedStocksAmount() public {
        recordBalance(address(aaplStock), address(this));
        aaplPool.initialize(1, 1e6, PYTH_DATA);
        assertBalanceDecreased(1);

        recordBalance(address(nvdaStock), address(this));
        nvdaPool.initialize(5 ether, 2e6, PYTH_DATA);
        assertBalanceDecreased(5 ether);
    }

    function testInitializeTakesUsdcPriceIntoAccount() public {
        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);

        recordBalance(address(aaplPool), address(this));
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);
        assertBalanceIncreased(1.8 ether);

        updatePrice(USDC_PRICE_FEED_ID, 1.5 ether);

        recordBalance(address(nvdaPool), address(this));
        nvdaPool.initialize(1 ether, 1e6, PYTH_DATA);
        assertBalanceIncreased(2.5 ether);
    }

    function testInitializeCannotBeCalledAgain() public {
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);
        vm.expectRevert(DclexPool.DclexPool__AlreadyInitialized.selector);
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);

        nvdaPool.initialize(1 ether, 1e6, PYTH_DATA);
        vm.expectRevert(DclexPool.DclexPool__AlreadyInitialized.selector);
        nvdaPool.initialize(1 ether, 1e6, PYTH_DATA);
    }

    function testAddLiquidityRevertsWhenNotInitialized() public {
        vm.expectRevert(DclexPool.DclexPool__NotInitialized.selector);
        aaplPool.addLiquidity(1);
    }

    function testAddLiquidityMintsGivenAmountOfLiquidityTokens() public {
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);

        uint256 totalBalanceBefore = aaplPool.totalSupply();
        uint256 balanceBefore = aaplPool.balanceOf(address(this));
        aaplPool.addLiquidity(1);
        uint256 totalBalanceAfter = aaplPool.totalSupply();
        uint256 balanceAfter = aaplPool.balanceOf(address(this));
        assertEq(totalBalanceAfter - totalBalanceBefore, 1);
        assertEq(balanceAfter - balanceBefore, 1);

        totalBalanceBefore = aaplPool.totalSupply();
        balanceBefore = aaplPool.balanceOf(address(this));
        aaplPool.addLiquidity(5000);
        totalBalanceAfter = aaplPool.totalSupply();
        balanceAfter = aaplPool.balanceOf(address(this));
        assertEq(totalBalanceAfter - totalBalanceBefore, 5000);
        assertEq(balanceAfter - balanceBefore, 5000);
    }

    function testAddLiquidityMintsTokensToCaller() public {
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);

        uint256 balanceBefore = aaplPool.balanceOf(USER_1);
        vm.prank(USER_1);
        aaplPool.addLiquidity(1);
        uint256 balanceAfter = aaplPool.balanceOf(USER_1);
        assertEq(balanceAfter - balanceBefore, 1);

        balanceBefore = aaplPool.balanceOf(USER_2);
        vm.prank(USER_2);
        aaplPool.addLiquidity(1);
        balanceAfter = aaplPool.balanceOf(USER_2);
        assertEq(balanceAfter - balanceBefore, 1);
    }

    function testAddLiquidityTakesStockTokensProportionallyToRequestedLiquidityTokensShare() public {
        aaplPool.initialize(50 ether, 50e6, PYTH_DATA);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 50 ether);
        uint256 balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.addLiquidity(1 ether); // total share requested: 1%
        uint256 stocksTaken1 = balanceBefore - aaplStock.balanceOf(address(this));

        aaplPool.addLiquidity(99 ether);
        setPoolStockBalance(aaplPool, 50 ether);

        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.addLiquidity(100 ether); // total share requested: 50%
        uint256 stocksTaken2 = balanceBefore - aaplStock.balanceOf(address(this));

        setPoolStockBalance(aaplPool, 50 ether);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 50 ether);
        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.addLiquidity(240 ether); // total share requested: 80%
        uint256 stocksTaken3 = balanceBefore - aaplStock.balanceOf(address(this));

        assertNotEq(stocksTaken1, 0);
        assertEq(stocksTaken2, 50 * stocksTaken1);
        assertEq(stocksTaken3, 80 * stocksTaken1);
    }

    function testAddLiquidityTakesStocksTokensProportionallyToStocksAmountHeldByPool() public {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        aaplPool.initialize(0.05 ether, 1e6, PYTH_DATA);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 0.05 ether);
        uint256 balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.addLiquidity(2 ether); // total share requested: 100%
        uint256 balanceAfter = aaplStock.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 0.05 ether);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 0.1 ether);
        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.addLiquidity(4 ether); // total share requested: 100%
        balanceAfter = aaplStock.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 0.1 ether);

        aaplPool.addLiquidity(16 ether);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 0.6 ether);
        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.addLiquidity(24 ether); // total share requested: 100%
        balanceAfter = aaplStock.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 0.6 ether);

        setPoolStockBalance(aaplPool, 1);

        /* TODO: fix this test
        assertEq(aaplStock.balanceOf(address(aaplPool)), 1);
        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.addLiquidity(48); // total share requested: 100%
        balanceAfter = aaplStock.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 1); */
    }

    function testAddLiquidityTakesUSDCTokensProportionallyToRequestedLiquidityTokensShare() public {
        aaplPool.initialize(50 ether, 50e6, PYTH_DATA);
        assertEq(aaplPool.totalSupply(), 100 ether);

        uint256 balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.addLiquidity(1 ether); // total share requested: 1%
        uint256 usdcTaken1 = balanceBefore - usdcMock.balanceOf(address(this));

        aaplPool.addLiquidity(99 ether);
        setPoolUSDCBalance(aaplPool, 50e6);

        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.addLiquidity(100 ether); // total share requested: 50%
        uint256 usdcTaken2 = balanceBefore - usdcMock.balanceOf(address(this));

        setPoolUSDCBalance(aaplPool, 50e6);

        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.addLiquidity(240 ether); // total share requested: 80%
        uint256 usdcTaken3 = balanceBefore - usdcMock.balanceOf(address(this));

        assertNotEq(usdcTaken1, 0);
        assertEq(usdcTaken2, 50 * usdcTaken1);
        assertEq(usdcTaken3, 80 * usdcTaken1);
    }

    function testAddLiquidityTakesUSDCTokensProportionallyToStocksAmountHeldByPool() public {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        aaplPool.initialize(0.05 ether, 1e6, PYTH_DATA);

        assertEq(usdcMock.balanceOf(address(aaplPool)), 1e6);
        uint256 balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.addLiquidity(2 ether); // total share requested: 100%
        uint256 balanceAfter = usdcMock.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 1e6);

        assertEq(usdcMock.balanceOf(address(aaplPool)), 2e6);
        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.addLiquidity(4 ether); // total share requested: 100%
        balanceAfter = usdcMock.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 2e6);

        aaplPool.addLiquidity(16 ether);

        assertEq(usdcMock.balanceOf(address(aaplPool)), 12e6);
        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.addLiquidity(24 ether); // total share requested: 100%
        balanceAfter = usdcMock.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 12e6);

        setPoolUSDCBalance(aaplPool, 1);

        assertEq(usdcMock.balanceOf(address(aaplPool)), 1);
        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.addLiquidity(48 ether); // total share requested: 100%
        balanceAfter = usdcMock.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 1);
    }

    function testRemoveLiquidityBurnsGivenAmountOfLiquidityTokens() public {
        aaplPool.initialize(6000 ether, 6000e6, PYTH_DATA);

        uint256 totalBalanceBefore = aaplPool.totalSupply();
        uint256 balanceBefore = aaplPool.balanceOf(address(this));
        aaplPool.removeLiquidity(1);
        uint256 totalBalanceAfter = aaplPool.totalSupply();
        uint256 balanceAfter = aaplPool.balanceOf(address(this));
        assertEq(totalBalanceBefore - totalBalanceAfter, 1);
        assertEq(balanceBefore - balanceAfter, 1);

        totalBalanceBefore = aaplPool.totalSupply();
        balanceBefore = aaplPool.balanceOf(address(this));
        aaplPool.removeLiquidity(5000);
        totalBalanceAfter = aaplPool.totalSupply();
        balanceAfter = aaplPool.balanceOf(address(this));
        assertEq(totalBalanceBefore - totalBalanceAfter, 5000);
        assertEq(balanceBefore - balanceAfter, 5000);
    }

    function testRemoveLiquidityRevertsWhenCallerHasNotEnoughLiquidityTokens() public {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);

        vm.expectRevert("ERC20: burn amount exceeds balance");
        aaplPool.removeLiquidity(200 ether + 1);

        vm.expectRevert("ERC20: burn amount exceeds balance");
        aaplPool.removeLiquidity(201 ether);

        aaplPool.removeLiquidity(200 ether);
        assertEq(aaplPool.balanceOf(address(this)), 0);
    }

    function testAddLiquidityMintsTokensFromCaller() public {
        vm.prank(USER_1);
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);
        vm.prank(USER_2);
        aaplPool.addLiquidity(1);

        uint256 balanceBefore = aaplPool.balanceOf(USER_1);
        vm.prank(USER_1);
        aaplPool.removeLiquidity(1);
        uint256 balanceAfter = aaplPool.balanceOf(USER_1);
        assertEq(balanceBefore - balanceAfter, 1);

        balanceBefore = aaplPool.balanceOf(USER_2);
        vm.prank(USER_2);
        aaplPool.removeLiquidity(1);
        balanceAfter = aaplPool.balanceOf(USER_2);
        assertEq(balanceBefore - balanceAfter, 1);
    }

    function testRemoveLiquidityGivesStockTokensProportionallyToBurnedLiquidityTokensShare() public {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);

        uint256 balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.removeLiquidity(2 ether); // total share burned: 1%
        uint256 stocksReceived = aaplStock.balanceOf(address(this)) - balanceBefore;
        assertEq(stocksReceived, 1 ether);

        aaplPool.addLiquidity(2 ether);
        setPoolStockBalance(aaplPool, 100 ether);

        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.removeLiquidity(100 ether); // total share burned: 50%
        stocksReceived = aaplStock.balanceOf(address(this)) - balanceBefore;
        assertEq(stocksReceived, 50 ether);

        setPoolStockBalance(aaplPool, 100 ether);

        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.removeLiquidity(80 ether); // total share burned: 80%
        stocksReceived = aaplStock.balanceOf(address(this)) - balanceBefore;
        assertEq(stocksReceived, 80 ether);
    }

    function testRemoveLiquidityGivesStocksTokensProportionallyToStocksAmountHeldByPool() public {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        aaplPool.initialize(5 ether, 100e6, PYTH_DATA);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 5 ether);
        uint256 balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.removeLiquidity(20 ether); // total share requested: 10%
        uint256 balanceAfter = aaplStock.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 0.5 ether);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 4.5 ether);
        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.removeLiquidity(18 ether); // total share requested: 10%
        balanceAfter = aaplStock.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 0.45 ether);

        aaplPool.removeLiquidity(2 ether);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 4 ether);
        balanceBefore = aaplStock.balanceOf(address(this));
        aaplPool.removeLiquidity(16 ether); // total share requested: 10%
        balanceAfter = aaplStock.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 0.4 ether);
    }

    function testRemoveLiquidityGivesUSDCTokensProportionallyToBurnedLiquidityTokensShare() public {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);

        assertEq(usdcMock.balanceOf(address(aaplPool)), 100e6);
        uint256 balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.removeLiquidity(4 ether); // total share burned: 2%
        uint256 usdcReceived = usdcMock.balanceOf(address(this)) - balanceBefore;
        assertEq(usdcReceived, 2e6);

        setPoolUSDCBalance(aaplPool, 100e6);

        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.removeLiquidity(98 ether); // total share requested: 50%
        usdcReceived = usdcMock.balanceOf(address(this)) - balanceBefore;
        assertEq(usdcReceived, 50e6);

        aaplPool.addLiquidity(102 ether);
        setPoolUSDCBalance(aaplPool, 100e6);

        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.removeLiquidity(160 ether); // total share requested: 80%
        usdcReceived = usdcMock.balanceOf(address(this)) - balanceBefore;
        assertEq(usdcReceived, 80e6);
    }

    function testRemoveLiquidityGivesUSDCTokensProportionallyToUSDCAmountHeldByPool() public {
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);
        aaplPool.initialize(5 ether, 100e6, PYTH_DATA);

        uint256 balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.removeLiquidity(20 ether); // total share requested: 10%
        uint256 balanceAfter = usdcMock.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 10e6);

        assertEq(usdcMock.balanceOf(address(aaplPool)), 90e6);
        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.removeLiquidity(18 ether); // total share requested: 10%
        balanceAfter = usdcMock.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 9e6);

        aaplPool.removeLiquidity(2 ether);
        setPoolUSDCBalance(aaplPool, 80e6);

        balanceBefore = usdcMock.balanceOf(address(this));
        aaplPool.removeLiquidity(16 ether); // total share requested: 10%
        balanceAfter = usdcMock.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 8e6);
    }

    function testLPTokensCannotBeTransferredToNonDclexVerifiedContracts() public {
        aaplPool.initialize(1000 ether, 1000e6, PYTH_DATA);
        address nonVerifiedContract = address(new USDCMock("", ""));

        vm.expectRevert(InvalidSmartcontract.selector);
        aaplPool.transfer(nonVerifiedContract, 1);

        aaplPool.approve(address(this), 1);
        vm.expectRevert(InvalidSmartcontract.selector);
        aaplPool.transferFrom(address(this), nonVerifiedContract, 1);
    }

    function testLPTokensCannotBeTransferredToBlockedContracts() public {
        aaplPool.initialize(1000 ether, 1000e6, PYTH_DATA);

        address blockedAddress = address(new USDCMock("", ""));
        vm.prank(ADMIN);
        contractIdentity.mintAdmin(blockedAddress);
        uint256[] memory ids = new uint256[](1);
        ids[0] = contractIdentity.getId(blockedAddress);
        uint256[] memory valids = new uint256[](1);
        valids[0] = 2;
        vm.prank(ADMIN);
        contractIdentity.setValids(ids, valids);

        vm.expectRevert(InvalidSmartcontract.selector);
        aaplPool.transfer(blockedAddress, 1);

        aaplPool.approve(address(this), 1);
        vm.expectRevert(InvalidSmartcontract.selector);
        aaplPool.transferFrom(address(this), blockedAddress, 1);
    }

    function testLPTokenCanBeTransferredToDclexVerifiedContracts() public {
        aaplPool.initialize(1000 ether, 1000e6, PYTH_DATA);

        address verifiedAddress = address(new USDCMock("", ""));
        vm.prank(ADMIN);
        contractIdentity.mintAdmin(verifiedAddress);
        aaplPool.transfer(verifiedAddress, 1);

        aaplPool.approve(address(this), 1);
        aaplPool.transferFrom(address(this), verifiedAddress, 1);
    }

    function testLPTokensCannotBeTransferredToNonDclexVerifiedAccounts() public {
        aaplPool.initialize(1000 ether, 1000e6, PYTH_DATA);
        address nonVerifiedAddress = makeAddr("non-verified");

        vm.expectRevert(InvalidDID.selector);
        aaplPool.transfer(nonVerifiedAddress, 1);

        aaplPool.approve(address(this), 1);
        vm.expectRevert(InvalidDID.selector);
        aaplPool.transferFrom(address(this), nonVerifiedAddress, 1);
    }

    function testLPTokensCannotBeTransferredToBlockedAccounts() public {
        aaplPool.initialize(1000 ether, 1000e6, PYTH_DATA);

        address blockedAddress = makeAddr("blocked");
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(blockedAddress, 0, "");
        uint256[] memory ids = new uint256[](1);
        ids[0] = digitalIdentity.getId(blockedAddress);
        uint256[] memory valids = new uint256[](1);
        valids[0] = 2;
        vm.prank(ADMIN);
        digitalIdentity.setValids(ids, valids);

        vm.expectRevert(InvalidDID.selector);
        aaplPool.transfer(blockedAddress, 1);

        aaplPool.approve(address(this), 1);
        vm.expectRevert(InvalidDID.selector);
        aaplPool.transferFrom(address(this), blockedAddress, 1);
    }

    function testLPTokenCanBeTransferredToDclexVerifiedAccounts() public {
        aaplPool.initialize(1000 ether, 1000e6, PYTH_DATA);

        address verifiedAddress = makeAddr("verified");
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(verifiedAddress, 0, "");
        aaplPool.transfer(verifiedAddress, 1);

        aaplPool.approve(address(this), 1);
        aaplPool.transferFrom(address(this), verifiedAddress, 1);
    }

    function testSwapExactOutputFeesDoNotChangeOutputAmount() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.001 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(1 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(1e6);
    }

    function testSwapExactOutputFeeIsProportionalToNetSwapAmount() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.001 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1.03e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1.03 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 5 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(5.15e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 5e6, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(5.15 ether);

        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 5 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(103e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 100e6, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(5.15 ether);
    }

    function testSwapExactOutputFeeIsProportionalToFeeRate() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.001 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1.03e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1.03 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0.001 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1.05e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1.05 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0, 0);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1 ether);
    }

    function testSwapExactInputFeesDoNotChangeInputAmount() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.001 ether);

        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1 ether);

        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceDecreasedApprox(1e6);
    }

    function testSwapExactInputFeeIsProportionalToGrossSwapAmount() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.001 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(0.97e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(0.97 ether);
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 5 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(4.85e6);
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 5e6, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(4.85 ether);

        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 5 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(97e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 100e6, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(4.85 ether);
    }

    function testSwapExactInputFeeIsProportionalToFeeRate() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.001 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(0.97e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(0.97 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0.001 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(0.95e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(0.95 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0, 0);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(1e6);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
        assertBalanceIncreasedApprox(1 ether);
    }

    function testFeeRateisBaseFeeRateWhenPoolIsBalancedInValue() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.001 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.03 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.03 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.03 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.03 ether);
    }

    function testStockToUSDCSwapExactInputHigherSensitivityCauseQuickerFeeRateRaise() public liquidityMinted {
        uint256 baseFeeRate = 0.05 ether;
        uint256 poolProportion = 0.75 ether;

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.0000000001 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, baseFeeRate);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.001 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.053 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.005 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.065 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.05 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.2 ether);
    }
    
    function testStockToUSDCSwapExactOutputHigherSensitivityCauseQuickerFeeRateRaise() public liquidityMinted {
        uint256 baseFeeRate = 0.05 ether;
        uint256 poolProportion = 0.75 ether;

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.0000000001 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, baseFeeRate);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.001 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.053 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.005 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.065 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.05 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.2 ether);
    }
    
    function testUSDCToStockSwapExactInputHigherSensitivityCauseQuickerFeeRateRaise() public liquidityMinted {
        uint256 baseFeeRate = 0.05 ether;
        uint256 poolProportion = 0.25 ether;

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.0000000001 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, baseFeeRate);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.001 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.053 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.005 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.065 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.05 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.2 ether);
    }

    function testUSDCToStockSwapExactOutputHigherSensitivityCauseQuickerFeeRateRaise() public liquidityMinted {
        uint256 baseFeeRate = 0.05 ether;
        uint256 poolProportion = 0.25 ether;

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.0000000001 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, baseFeeRate);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.001 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.053 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.005 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.065 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, poolProportion);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(baseFeeRate, 0.05 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.2 ether);
    }
    
    function testUSDCToStockFeeRateIsGettingLowerWithIncreasingStockProportionInPool() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.016 ether, 0.016 ether);

        // TODO: sell fee rate cannot be more than 100%
        //setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.05 ether);
        //assertUSDCToStockExactInputFeeRate(aaplPool, 1.6 ether);

        //setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.05 ether);
        //assertUSDCToStockExactOutputFeeRate(aaplPool, 1.6 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.1 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.4 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.1 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.4 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.2 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.1 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.2 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.1 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.4 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.025 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.4 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.025 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.016 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.016 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.8 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.00625 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.8 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.00625 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 1 ether);
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.004 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 1 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.004 ether);
    }

    function testStockToUSDCFeeRateIsGettingHigherWithIncreasingStockProportionInPool() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.016 ether, 0.016 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.2 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.00625 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.2 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.00625 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.016 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.016 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.6 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.025 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.6 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.025 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.8 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.1 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.8 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.1 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.9 ether);
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.4 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.9 ether);
        assertStockToUSDCExactOutputFeeRate(aaplPool, 0.4 ether);

        // TODO: fee rate cannot be more than 100%
        //setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.95 ether);
        //assertStockToUSDCExactInputFeeRate(aaplPool, 1.6 ether);

        //setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.95 ether);
        //assertStockToUSDCExactOutputFeeRate(aaplPool, 1.6 ether);
    }

    function testStockToUSDCSwapExactInputTheMoreUnbalancedPoolBecomesTheHigherFee() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.01 ether);

        uint256 sellProportionOfPoolStocks = 0.5 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        uint256 swapSizeInStocks = sellProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, swapSizeInStocks, address(this), "", PYTH_DATA);
        assertOutputFeeRate(0.04 ether, uint256(getBalanceChange()), swapSizeInStocks / 1e12);

        sellProportionOfPoolStocks = 0.6 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        swapSizeInStocks = sellProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, swapSizeInStocks, address(this), "", PYTH_DATA);
        assertOutputFeeRate(0.045 ether, uint256(getBalanceChange()), swapSizeInStocks / 1e12);

        sellProportionOfPoolStocks = 0.75 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        swapSizeInStocks = sellProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactInput(false, swapSizeInStocks, address(this), "", PYTH_DATA);
        assertOutputFeeRate(0.06 ether, uint256(getBalanceChange()), swapSizeInStocks / 1e12);
    }

    function testStockToUSDCSwapExactOutputTheMoreUnbalancedPoolBecomesTheHigherFee() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.01 ether);

        uint256 sellProportionOfPoolStocks = 0.5 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        uint256 swapSizeInStocks = sellProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, swapSizeInStocks / 1e12, address(this), "", PYTH_DATA);
        assertInputFeeRate(0.04 ether, uint256(-getBalanceChange()), swapSizeInStocks);

        sellProportionOfPoolStocks = 0.6 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        swapSizeInStocks = sellProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, swapSizeInStocks / 1e12, address(this), "", PYTH_DATA);
        assertInputFeeRate(0.045 ether, uint256(-getBalanceChange()), swapSizeInStocks);

        sellProportionOfPoolStocks = 0.75 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        swapSizeInStocks = sellProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactOutput(false, swapSizeInStocks / 1e12, address(this), "", PYTH_DATA);
        assertInputFeeRate(0.06 ether, uint256(-getBalanceChange()), swapSizeInStocks);
    }

    function testUSDCToStockSwapExactInputTheMoreUnbalancedPoolBecomesTheHigherFee() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.01 ether);

        uint256 buyProportionOfPoolStocks = 0.5 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        uint256 swapSizeInStocks = buyProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, swapSizeInStocks / 1e12, address(this), "", PYTH_DATA);
        assertOutputFeeRate(0.04 ether, uint256(getBalanceChange()), swapSizeInStocks);

        buyProportionOfPoolStocks = 0.6 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        swapSizeInStocks = buyProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, swapSizeInStocks / 1e12, address(this), "", PYTH_DATA);
        assertOutputFeeRate(0.045 ether, uint256(getBalanceChange()), swapSizeInStocks);

        buyProportionOfPoolStocks = 0.75 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        swapSizeInStocks = buyProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(aaplStock), address(this));
        aaplPool.swapExactInput(true, swapSizeInStocks / 1e12, address(this), "", PYTH_DATA);
        assertOutputFeeRate(0.06 ether, uint256(getBalanceChange()), swapSizeInStocks);
    }

    function testUSDCToStockSwapExactOutputTheMoreUnbalancedPoolBecomesTheHigherFee() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.03 ether, 0.01 ether);

        uint256 buyProportionOfPoolStocks = 0.5 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        uint256 swapSize = buyProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, swapSize, address(this), "", PYTH_DATA);
        assertInputFeeRate(0.04 ether, uint256(-getBalanceChange() * 1e12), swapSize);

        buyProportionOfPoolStocks = 0.6 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        swapSize = buyProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, swapSize, address(this), "", PYTH_DATA);
        assertInputFeeRate(0.045 ether, uint256(-getBalanceChange() * 1e12), swapSize);

        buyProportionOfPoolStocks = 0.75 ether;
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        swapSize = buyProportionOfPoolStocks * aaplStock.balanceOf(address(aaplPool)) / 1e18;
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, swapSize, address(this), "", PYTH_DATA);
        assertInputFeeRate(0.06 ether, uint256(-getBalanceChange() * 1e12), swapSize);
    }

    function testSellExactInputUsdcProtocolFeeIsProportionalToSetProtocolFeeRate() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0);

        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);  // 0.01 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0.01 ether);
        assertEq(aaplFees, 0);

        vm.prank(POOL_ADMIN);
        aaplPool.setProtocolFeeRate(0.15 ether);
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);  // 0.015 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0.01 ether + 0.015 ether);
        assertEq(aaplFees, 0);
    }

    function testSellExactInputUsdcProtocolFeeIsProportionalToSwapFee() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0);

        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);  // 0.05 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0.005 ether);
        assertEq(aaplFees, 0);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.08 ether, 0);
        aaplPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA);  // 0.08 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0.005 ether + 0.008 ether);
        assertEq(aaplFees, 0);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0);
        aaplPool.swapExactInput(false, 2 ether, address(this), "", PYTH_DATA);  // 0.1 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0.005 ether + 0.008 ether + 0.01 ether);
        assertEq(aaplFees, 0);
    }

    function testBuyExactInputUsdcProtocolFeeIsProportionalToSetProtocolFeeRate() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0);

        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);  // 0.01 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0.01 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setProtocolFeeRate(0.15 ether);
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);  // 0.015 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0.01 ether + 0.015 ether);
    }

    function testBuyExactInputCollectedUsdcProtocolFeeIsProportionalToSwapFee() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0);

        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);  // 0.05 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0.005 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.08 ether, 0);
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);  // 0.08 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0.005 ether + 0.008 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0);
        aaplPool.swapExactInput(true, 2e6, address(this), "", PYTH_DATA);  // 0.1 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 0);
        assertEq(aaplFees, 0.005 ether + 0.008 ether + 0.01 ether);
    }

    function testSellExactOutputUsdcProtocolFeeIsProportionalToSetProtocolFeeRate() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0);

        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);  // 0.01 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0.01 ether);
        assertEq(usdcFees, 0);

        vm.prank(POOL_ADMIN);
        aaplPool.setProtocolFeeRate(0.15 ether);
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);  // 0.015 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0.01 ether + 0.015 ether);
        assertEq(usdcFees, 0);
    }

    function testSellExactOutputCollectedUsdcProtocolFeeIsProportionalToSwapFee() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0);

        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);  // 0.05 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0.005 ether);
        assertEq(usdcFees, 0);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.08 ether, 0);
        aaplPool.swapExactOutput(false, 1e6, address(this), "", PYTH_DATA);  // 0.08 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0.005 ether + 0.008 ether);
        assertEq(usdcFees, 0);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0);
        aaplPool.swapExactOutput(false, 2e6, address(this), "", PYTH_DATA);  // 0.1 AAPL fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0.005 ether + 0.008 ether + 0.01 ether);
        assertEq(usdcFees, 0);
    }

    function testUsdcPriceInfluencesPoolBalance() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.016 ether, 0.016 ether);

        updatePrice(USDC_PRICE_FEED_ID, 1 ether);
        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        assertUSDCToStockExactOutputFeeRate(aaplPool, 0.016 ether);

        setPoolStocksProportion(aaplPool, AAPL_PRICE_FEED_ID, 0.5 ether);
        updatePrice(USDC_PRICE_FEED_ID, 0.25 ether);
        recordBalance(address(usdcMock), address(this));
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
        int256 balanceChange = getBalanceChange();
        int256 feeRate = (-balanceChange - 4e6) * 1e12 / 4;
        assertApproxEqAbsDecimal(feeRate, 0.00625 ether, 0.001 ether, 18);
    }

    function testBuyExactOutputUsdcProtocolFeeIsProportionalToSetProtocolFeeRate() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0);

        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);  // 0.01 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0.01 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setProtocolFeeRate(0.15 ether);
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);  // 0.015 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0.01 ether + 0.015 ether);
    }

    function testBuyExactOutputCollectedUsdcProtocolFeeIsProportionalToSwapFee() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0);

        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);  // 0.05 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0.005 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.08 ether, 0);
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);  // 0.08 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0.005 ether + 0.008 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.05 ether, 0);
        aaplPool.swapExactOutput(true, 2 ether, address(this), "", PYTH_DATA);  // 0.1 USDC fee
        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0.005 ether + 0.008 ether + 0.01 ether);
    }

    function testWithdrawCollectedProtocolFeesSendsCollectedStockProtocolFees() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();
        aaplPool.swapExactOutput(false, 300e6, address(this), "", PYTH_DATA);  // 3 AAPL protocol fee
        (uint256 aaplFees, ) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 3 ether);

        recordBalance(address(aaplStock), RECEIVER_1);
        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(RECEIVER_1);
        assertBalanceIncreased(3 ether);

        aaplPool.swapExactOutput(false, 500e6, address(this), "", PYTH_DATA);  // 5 AAPL protocol fee
        aaplPool.swapExactOutput(false, 100e6, address(this), "", PYTH_DATA);  // 1 AAPL protocol fee
        recordBalance(address(aaplStock), RECEIVER_1);
        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(RECEIVER_1);
        assertBalanceIncreased(6 ether);
    }

    function testWithdrawCollectedProtocolFeesSendsCollectedUsdcProtocolFees() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();
        aaplPool.swapExactOutput(true, 300 ether, address(this), "", PYTH_DATA);  // 3 USDC protocol fee
        (, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(usdcFees, 3 ether);

        recordBalance(address(usdcMock), RECEIVER_1);
        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(RECEIVER_1);
        assertBalanceIncreased(3e6);

        aaplPool.swapExactOutput(true, 500 ether, address(this), "", PYTH_DATA);  // 5 USDC protocol fee
        aaplPool.swapExactOutput(true, 100 ether, address(this), "", PYTH_DATA);  // 1 USDC protocol fee
        recordBalance(address(usdcMock), RECEIVER_1);
        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(RECEIVER_1);
        assertBalanceIncreased(6e6);
    }

    function testWithdrawCollectedProtocolFeesResetsCollectedProtocolFees() public liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();
        aaplPool.swapExactOutput(false, 300e6, address(this), "", PYTH_DATA);  // 3 AAPL protocol fee
        aaplPool.swapExactOutput(true, 500 ether, address(this), "", PYTH_DATA);  // 5 USDC protocol fee
        (uint256 aaplFees, uint256 usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 3 ether);
        assertEq(usdcFees, 5 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(RECEIVER_1);

        (aaplFees, usdcFees) = aaplPool.collectedProtocolFees();
        assertEq(aaplFees, 0);
        assertEq(usdcFees, 0);
    }

    function testAddingLiquidityDoesNotTakeCollectedStocksProtocolFeesIntoAccount() public {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();
        aaplPool.swapExactOutput(false, 20e6, address(this), "", PYTH_DATA);  // 0.2 AAPL protocol fee

        recordBalance(address(aaplStock), address(this));
        aaplPool.addLiquidity(200 ether);  // pool has 121.8 AAPL of reserves and 0.2 AAPL collected protocol fee 
        assertBalanceDecreased(121.8 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(RECEIVER_1);
        aaplPool.removeLiquidity(400 ether);
        assertEq(aaplStock.balanceOf(address(aaplPool)), 0);
        assertEq(usdcMock.balanceOf(address(aaplPool)), 0);
    }

    function testAddingLiquidityDoesNotTakeCollectedUsdcProtocolFeesIntoAccount() public {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();
        aaplPool.swapExactOutput(true, 20 ether, address(this), "", PYTH_DATA);  // 0.2 USDC protocol fee

        recordBalance(address(usdcMock), address(this));
        aaplPool.addLiquidity(200 ether);  // pool has 121.8 USDC of reserves and 0.2 USDC collected protocol fee 
        assertBalanceDecreased(121.8e6);

        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(RECEIVER_1);
        aaplPool.removeLiquidity(400 ether);
        assertEq(aaplStock.balanceOf(address(aaplPool)), 0);
        assertEq(usdcMock.balanceOf(address(aaplPool)), 0);
    }

    function testWithdrawingAllLiquidityLeavesCollectedProtocolFee() public {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();
        aaplPool.swapExactOutput(false, 30e6, address(this), "", PYTH_DATA);  // 0.3 AAPL protocol fee
        aaplPool.swapExactOutput(true, 50 ether, address(this), "", PYTH_DATA);  // 0.5 USDC protocol fee

        aaplPool.removeLiquidity(200 ether);

        assertEq(aaplStock.balanceOf(address(aaplPool)), 0.3 ether);
        assertEq(usdcMock.balanceOf(address(aaplPool)), 0.5e6);
        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(RECEIVER_1);
    }

    function testCollectedStockProtocolFeeDoesNotImpactFeeCalculations() public {
        aaplPool.initialize(1000 ether, 1000e6, PYTH_DATA);
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.5 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();
        aaplPool.swapExactOutput(false, 600e6, address(this), "", PYTH_DATA);  // 30 AAPL protocol fee

        // we take LP fees out of the pool
        vm.prank(address(aaplPool));
        aaplStock.transfer(address(this), 270 ether);

        console.log(aaplStock.balanceOf(address(aaplPool)));
        console.log(usdcMock.balanceOf(address(aaplPool)));
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.016 ether, 0.016 ether);
        // pool should have 1600 AAPL (+30 AAPL protocol fee) and 400 USDC
        assertStockToUSDCExactInputFeeRate(aaplPool, 0.1 ether);
    }

    function testCollectedUsdcProtocolFeeDoesNotImpactFeeCalculations() public {
        aaplPool.initialize(1000 ether, 1000e6, PYTH_DATA);
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.5 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();
        aaplPool.swapExactOutput(true, 600 ether, address(this), "", PYTH_DATA);  // 30 USDC protocol fee

        // we take LP fees out of the pool
        vm.prank(address(aaplPool));
        usdcMock.transfer(address(this), 270e6);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.016 ether, 0.016 ether);
        // pool should have 1600 USDC (+24 USDC protocol fee) and 400 AAPL
        assertUSDCToStockExactInputFeeRate(aaplPool, 0.1 ether);
    }

    function testCannotSetNegativeFees() public {
        vm.expectRevert(DclexPool.DclexPool__FeesCannotBeNegative.selector);
        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0.1 ether + 1);
    }

    function testOnlyAdminCanCallSetFeeCurve() public {
        vm.prank(USER_1);
        vm.expectRevert();
        aaplPool.setFeeCurve(0.1 ether, 0.01 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0.01 ether);
    }

    function testOnlyAdminCanCallPause() public {
        vm.prank(USER_1);
        vm.expectRevert();
        aaplPool.pause();

        vm.prank(POOL_ADMIN);
        aaplPool.pause();
    }

    function testOnlyAdminCanCallUnpause() public {
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.prank(USER_1);
        vm.expectRevert();
        aaplPool.unpause();

        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
    }

    function testOnlyAdminCanCallSetProtocolFeeRate() public {
        vm.prank(USER_1);
        vm.expectRevert();
        aaplPool.setProtocolFeeRate(0.1 ether);

        vm.prank(POOL_ADMIN);
        aaplPool.setProtocolFeeRate(0.1 ether);
    }

    function testOnlyAdminCanCallWithdrawCollectedProtocolFees() public {
        vm.prank(USER_1);
        vm.expectRevert();
        aaplPool.withdrawCollectedProtocolFees(USER_1);

        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(USER_1);
    }

    function testPausePausesPool() public {
        assertFalse(aaplPool.paused());
        vm.prank(POOL_ADMIN);
        aaplPool.pause();
        assert(aaplPool.paused());
    }

    function testPauseEmitsPauseEvent() public {
        vm.prank(POOL_ADMIN);
        vm.expectEmit(address(aaplPool));
        emit Paused(POOL_ADMIN);
        aaplPool.pause();
    }

    function testUnpauseUnpausesPool() public {
        vm.prank(POOL_ADMIN);
        aaplPool.pause();
        assert(aaplPool.paused());
        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
        assertFalse(aaplPool.paused());
    }

    function testUnpauseEmitsUnpausedEvent() public {
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.prank(POOL_ADMIN);
        vm.expectEmit(address(aaplPool));
        emit Unpaused(POOL_ADMIN);
        aaplPool.unpause();
    }

    function testInitializeRevertsWhenPoolIsPaused() public {
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.expectRevert("Pausable: paused");
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);

        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);
    }

    function testAddLiquidityRevertsWhenPoolIsPaused() public {
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.expectRevert("Pausable: paused");
        aaplPool.addLiquidity(1);

        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
        aaplPool.addLiquidity(1);
    }

    function testRemoveLiquidityRevertsWhenPoolIsPaused() public {
        aaplPool.initialize(1 ether, 1e6, PYTH_DATA);
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.expectRevert("Pausable: paused");
        aaplPool.removeLiquidity(1);

        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
        aaplPool.removeLiquidity(1);
    }

    function testSwapExactInputRevertsWhenPoolIsPaused() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.expectRevert("Pausable: paused");
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);

        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA);
    }

    function testSwapExactOutputRevertsWhenPoolIsPaused() public liquidityMinted {
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.expectRevert("Pausable: paused");
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);

        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
        aaplPool.swapExactOutput(true, 1 ether, address(this), "", PYTH_DATA);
    }
    
    function testTransferRevertsWhenPoolIsPaused() public {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.expectRevert("Pausable: paused");
        aaplPool.transfer(RECEIVER_1, 1);

        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
        aaplPool.transfer(RECEIVER_1, 1);
    }
    
    function testTransferFromRevertsWhenPoolIsPaused() public {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);
        aaplPool.approve(address(this), 1);
        vm.prank(POOL_ADMIN);
        aaplPool.pause();

        vm.expectRevert("Pausable: paused");
        aaplPool.transferFrom(address(this), RECEIVER_1, 1);

        vm.prank(POOL_ADMIN);
        aaplPool.unpause();
        aaplPool.transferFrom(address(this), RECEIVER_1, 1);
    }

    function testFeeCanBeChangedOnPausedContract() public {
        vm.startPrank(POOL_ADMIN);
        aaplPool.pause();
        aaplPool.setFeeCurve(0.1 ether, 0.01 ether);
        vm.stopPrank();
    }

    function testSetFeeCurveEmitsFeeCurveUpdatedEvent() external {
        vm.expectEmit(address(aaplPool));
        vm.prank(POOL_ADMIN);
        emit FeeCurveUpdated(0.1 ether, 0.01 ether);
        aaplPool.setFeeCurve(0.1 ether, 0.01 ether);

        vm.expectEmit(address(nvdaPool));
        vm.prank(POOL_ADMIN);
        emit FeeCurveUpdated(0.2 ether, 0.03 ether);
        nvdaPool.setFeeCurve(0.2 ether, 0.03 ether);
    }

    function testInitializeEmitsLiquidityAddedEvent() external {
        vm.expectEmit(address(aaplPool));
        emit LiquidityAdded(200 ether, 100 ether, 100e6);
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);

        vm.expectEmit(address(nvdaPool));
        emit LiquidityAdded(230 ether, 110 ether, 120e6);
        nvdaPool.initialize(110 ether, 120e6, PYTH_DATA);
    }

    function testAddLiquidityEmitsLiquidityAddedEvent() external {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);
        nvdaPool.initialize(100 ether, 100e6, PYTH_DATA);

        vm.expectEmit(address(aaplPool));
        emit LiquidityAdded(10 ether, 5 ether, 5e6);
        aaplPool.addLiquidity(10 ether);

        vm.expectEmit(address(nvdaPool));
        emit LiquidityAdded(20 ether, 10 ether, 10e6);
        nvdaPool.addLiquidity(20 ether);
    }

    function testRemoveLiquidityEmitsLiquidityRemovedEvent() external {
        aaplPool.initialize(100 ether, 100e6, PYTH_DATA);
        nvdaPool.initialize(100 ether, 100e6, PYTH_DATA);

        vm.expectEmit(address(aaplPool));
        emit LiquidityRemoved(10 ether, 5 ether, 5e6);
        aaplPool.removeLiquidity(10 ether);

        vm.expectEmit(address(nvdaPool));
        emit LiquidityRemoved(20 ether, 10 ether, 10e6);
        nvdaPool.removeLiquidity(20 ether);
    }

    function testSwapExactInputEmitsSwapExecutedEvent() external liquidityMinted {
        updatePrice(USDC_PRICE_FEED_ID, 1 ether);
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(true, 100e6, 5 ether, 20 ether, 1 ether, USER_1);
        aaplPool.swapExactInput(true, 100e6, USER_1, "", PYTH_DATA);

        updatePrice(USDC_PRICE_FEED_ID, 0.8 ether);
        updatePrice(NVDA_PRICE_FEED_ID, 30 ether);
        vm.expectEmit(address(nvdaPool));
        emit SwapExecuted(false, 2 ether, 75e6, 30 ether, 0.8 ether, USER_2);
        nvdaPool.swapExactInput(false, 2 ether, USER_2, "", PYTH_DATA);
    }

    function testSwapExactOutputEmitsSwapExecutedEvent() external liquidityMinted {
        updatePrice(USDC_PRICE_FEED_ID, 1 ether);
        updatePrice(AAPL_PRICE_FEED_ID, 20 ether);

        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(true, 20e6, 1 ether, 20 ether, 1 ether, USER_1);
        aaplPool.swapExactOutput(true, 1 ether, USER_1, "", PYTH_DATA);

        updatePrice(USDC_PRICE_FEED_ID, 0.9 ether);
        updatePrice(NVDA_PRICE_FEED_ID, 30 ether);
        vm.expectEmit(address(nvdaPool));
        emit SwapExecuted(false, 9 ether, 300e6, 30 ether, 0.9 ether, USER_2);
        nvdaPool.swapExactOutput(false, 300e6, USER_2, "", PYTH_DATA);
    }

    function testSetProtocolFeeRateEmitsProtocolFeeRateChanged() external liquidityMinted {
        vm.prank(POOL_ADMIN);
        vm.expectEmit(address(aaplPool));
        emit ProtocolFeeRateChanged(0.1 ether);
        aaplPool.setProtocolFeeRate(0.1 ether);

        vm.prank(POOL_ADMIN);
        vm.expectEmit(address(nvdaPool));
        emit ProtocolFeeRateChanged(0.15 ether);
        nvdaPool.setProtocolFeeRate(0.15 ether);
    }

    function testWithdrawCollectedProtocolFeesEmitsProtocolFeeWithdrawn() external liquidityMinted {
        vm.startPrank(POOL_ADMIN);
        aaplPool.setFeeCurve(0.1 ether, 0);
        aaplPool.setProtocolFeeRate(0.1 ether);
        nvdaPool.setFeeCurve(0.1 ether, 0);
        nvdaPool.setProtocolFeeRate(0.1 ether);
        vm.stopPrank();

        aaplPool.swapExactInput(true, 1e6, address(this), "", PYTH_DATA); // 0.01 AAPL protocol fee
        vm.expectEmit(address(aaplPool));
        emit ProtocolFeeWithdrawn(0.01 ether, 0, USER_1);
        vm.prank(POOL_ADMIN);
        aaplPool.withdrawCollectedProtocolFees(USER_1);

        nvdaPool.swapExactInput(false, 1 ether, address(this), "", PYTH_DATA); // 0.01 USDC protocol fee
        vm.expectEmit(address(nvdaPool));
        emit ProtocolFeeWithdrawn(0, 0.01e6, USER_2);
        vm.prank(POOL_ADMIN);
        nvdaPool.withdrawCollectedProtocolFees(USER_2);
    }

    function testUpdatePythPriceFeedsUpdatesPriceFeed() external liquidityMinted {
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 20 ether);
        pythData[1] = pythMock.getUpdatePriceData(USDC_PRICE_FEED_ID, 0.8 ether);
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        aaplPool.updatePythPriceFeeds{value: expectedFee}(pythData);

        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(true, 25e6, 1 ether, 20 ether, 0.8 ether, address(this));
        aaplPool.swapExactInput{value: 1 ether}(true, 25e6, address(this), "", PYTH_DATA);
    }

    function testUpdatePythPriceFeedsRefundsLeftoverEther() external liquidityMinted {
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 20 ether);
        pythData[1] = pythMock.getUpdatePriceData(USDC_PRICE_FEED_ID, 0.8 ether);
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        uint256 ethBalanceBefore = address(this).balance;
        aaplPool.updatePythPriceFeeds{value: expectedFee}(pythData);
        uint256 ethBalanceAfter = address(this).balance;
        assertEq(ethBalanceBefore - ethBalanceAfter, expectedFee);
    }

    function testInitializeUpdatesPythPriceFeed() external {
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 20 ether);
        pythData[1] = pythMock.getUpdatePriceData(USDC_PRICE_FEED_ID, 0.8 ether);
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        vm.expectEmit(address(aaplPool));
        emit LiquidityAdded(20.8 ether, 1 ether, 1e6);
        aaplPool.initialize{value: expectedFee}(1 ether, 1e6, pythData);
    }

    function testInitializeRefundsLeftoverEther() external {
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 20 ether);
        pythData[1] = pythMock.getUpdatePriceData(USDC_PRICE_FEED_ID, 0.8 ether);
        uint256 expectedFee = pythMock.getUpdateFee(pythData);

        uint256 ethBalanceBefore = address(this).balance;
        aaplPool.initialize{value: 1 ether}(1 ether, 1e6, pythData);
        uint256 ethBalanceAfter = address(this).balance;
        assertEq(ethBalanceBefore - ethBalanceAfter, expectedFee);
    }

    function testSwapExactInputUpdatesPriceFeed() external liquidityMinted {
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 20 ether);
        pythData[1] = pythMock.getUpdatePriceData(USDC_PRICE_FEED_ID, 0.8 ether);
        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(true, 25e6, 1 ether, 20 ether, 0.8 ether, address(this));
        aaplPool.swapExactInput{value: 1 ether}(true, 25e6, address(this), "", pythData);
    }

    function testSwapExactInputRefundsLeftoverEther() external liquidityMinted {
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 20 ether);
        pythData[1] = pythMock.getUpdatePriceData(USDC_PRICE_FEED_ID, 0.8 ether);
        uint256 expectedFee = pythMock.getUpdateFee(pythData);
        uint256 ethBalanceBefore = address(this).balance;
        aaplPool.swapExactInput{value: 1 ether}(true, 25e6, address(this), "", pythData);
        uint256 ethBalanceAfter = address(this).balance;
        assertEq(ethBalanceBefore - ethBalanceAfter, expectedFee);
    }

    function testSwapExactOutputUpdatesPriceFeed() external liquidityMinted {
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 20 ether);
        pythData[1] = pythMock.getUpdatePriceData(USDC_PRICE_FEED_ID, 0.8 ether);
        vm.expectEmit(address(aaplPool));
        emit SwapExecuted(true, 25e6, 1 ether, 20 ether, 0.8 ether, address(this));
        aaplPool.swapExactOutput{value: 1 ether}(true, 1 ether, address(this), "", pythData);
    }

    function testSwapExactOutputRefundsLeftoverEther() external liquidityMinted {
        bytes[] memory pythData = new bytes[](2);
        pythData[0] = pythMock.getUpdatePriceData(AAPL_PRICE_FEED_ID, 20 ether);
        pythData[1] = pythMock.getUpdatePriceData(USDC_PRICE_FEED_ID, 0.8 ether);
        uint256 expectedFee = pythMock.getUpdateFee(pythData);
        uint256 ethBalanceBefore = address(this).balance;
        aaplPool.swapExactOutput{value: 1 ether}(true, 1 ether, address(this), "", pythData);
        uint256 ethBalanceAfter = address(this).balance;
        assertEq(ethBalanceBefore - ethBalanceAfter, expectedFee);
    }

    function testProtocolFeeRateCannotBeSetHigherThan15Percent() external {
        vm.startPrank(POOL_ADMIN);
        vm.expectRevert(DclexPool.DclexPool__ProtocolFeeRateTooHigh.selector);
        aaplPool.setProtocolFeeRate(0.2 ether);

        vm.expectRevert(DclexPool.DclexPool__ProtocolFeeRateTooHigh.selector);
        aaplPool.setProtocolFeeRate(0.15 ether + 1);

        aaplPool.setProtocolFeeRate(0.15 ether);
        vm.stopPrank();
    }
}

