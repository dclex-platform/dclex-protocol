// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IDclexSwapCallback} from "./IDclexSwapCallback.sol";
import {IPriceOracle} from "./IPriceOracle.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";
import {InvalidDID} from "dclex-blockchain/contracts/libs/Model.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";

contract DclexPool is ERC20, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IStock;

    error DclexPool__AlreadyInitialized();
    error DclexPool__NotInitialized();
    error DclexPool__InsufficientInputAmount();
    error DclexPool__ZeroOutputAmount();
    error DclexPool__NativeTransferFailed();
    error DclexPool__NotEnoughPoolLiquidity();
    error DclexPool__FeesCannotBeNegative();
    error DclexPool__ProtocolFeeRateTooHigh();
    error DclexPool__InvalidPriceOrExponent();

    uint256 private constant MAX_PROTOCOL_FEE_RATE = 0.15 ether;
    uint8 private constant DECIMALS = 18;
    uint8 private constant USDC_DECIMALS = 6;
    IPriceOracle private immutable oracle;
    IStock public immutable stockToken;
    IERC20 public immutable usdcToken;
    bytes32 private immutable stockPriceFeedId;
    uint256 private immutable maxPriceStaleness;
    bool private initialized = false;
    uint256 private feeCurveA;
    uint256 private feeCurveB;
    uint256 private protocolFeeRate;
    uint256 private collectedProtocolFeesStock;
    uint256 private collectedProtocolFeesUsdc;

    event FeeCurveUpdated(uint256 baseFeeRate, uint256 sensitivity);
    event LiquidityAdded(
        uint256 addedLiquidity,
        uint256 addedStockAmount,
        uint256 addedUsdcAmount
    );
    event LiquidityRemoved(
        uint256 removedLiquidity,
        uint256 removedStockAmount,
        uint256 removedUsdcAmount
    );
    event SwapExecuted(
        bool usdcInput,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 stockPrice,
        uint256 usdcPrice,
        address recipient
    );
    event ProtocolFeeRateChanged(uint256 feeRate);
    event ProtocolFeeWithdrawn(
        uint256 stocksWithdrawn,
        uint256 usdcWithdrawn,
        address recipient
    );

    constructor(
        IStock _stockToken,
        IERC20 _usdcToken,
        IPriceOracle _oracle,
        bytes32 _stockPriceFeedId,
        address admin,
        uint256 _maxPriceStaleness
    )
        ERC20(
            string.concat(_stockToken.symbol(), "-LP"),
            string.concat(_stockToken.symbol(), "-LP")
        )
    {
        oracle = _oracle;
        stockToken = _stockToken;
        usdcToken = _usdcToken;
        stockPriceFeedId = _stockPriceFeedId;
        maxPriceStaleness = _maxPriceStaleness;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeeCurve(
        uint256 baseFeeRate,
        uint256 sensitivity
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeCurveA = sensitivity / 4;
        if (sensitivity > baseFeeRate) {
            revert DclexPool__FeesCannotBeNegative();
        }
        feeCurveB = baseFeeRate - sensitivity;
        emit FeeCurveUpdated(baseFeeRate, sensitivity);
    }

    function updatePriceFeeds(bytes[] memory priceUpdateData) public payable {
        uint256 balanceBefore = address(this).balance - msg.value;
        if (priceUpdateData.length > 0) {
            uint256 fee = oracle.getUpdateFee(priceUpdateData);
            oracle.updatePriceFeeds{value: fee}(priceUpdateData);
        }
        uint256 refund = address(this).balance - balanceBefore;
        if (refund > 0) {
            (bool success, ) = msg.sender.call{value: refund}(new bytes(0));
            if (!success) revert DclexPool__NativeTransferFailed();
        }
    }

    function initialize(
        uint256 stockAmount,
        uint256 usdcAmount,
        bytes[] memory priceUpdateData
    ) public payable whenNotPaused nonReentrant {
        if (initialized) {
            revert DclexPool__AlreadyInitialized();
        }
        updatePriceFeeds(priceUpdateData);
        uint256 stockUsdValue = (stockAmount *
            currentUsdPrice(stockPriceFeedId)) / 1e18;
        uint256 usdcUsdValue = usdcAmount * 1e12;
        uint256 liquidityAmount = (stockUsdValue + usdcUsdValue);
        initialized = true;
        stockToken.safeTransferFrom(msg.sender, address(this), stockAmount);
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);
        _mint(msg.sender, liquidityAmount);
        emit LiquidityAdded(liquidityAmount, stockAmount, usdcAmount);
    }

    function addLiquidity(
        uint256 liquidityAmount
    ) public whenNotPaused nonReentrant {
        if (!initialized) {
            revert DclexPool__NotInitialized();
        }
        (uint256 stockReserve, uint256 usdcReserve) = getReserves();
        uint256 stocksTaken = (liquidityAmount * stockReserve) / totalSupply();
        uint256 usdcTaken = (liquidityAmount * usdcReserve) / totalSupply();
        stockToken.safeTransferFrom(msg.sender, address(this), stocksTaken);
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcTaken / 1e12);
        _mint(msg.sender, liquidityAmount);
        emit LiquidityAdded(liquidityAmount, stocksTaken, usdcTaken / 1e12);
    }

    function removeLiquidity(
        uint256 liquidityAmount
    ) public whenNotPaused nonReentrant {
        (uint256 stockReserve, uint256 usdcReserve) = getReserves();
        uint256 stocksToSend = (liquidityAmount * stockReserve) / totalSupply();
        uint256 usdcToSend = (liquidityAmount * usdcReserve) / totalSupply();
        _burn(msg.sender, liquidityAmount);
        stockToken.safeTransfer(msg.sender, stocksToSend);
        usdcToken.safeTransfer(msg.sender, usdcToSend / 1e12);
        emit LiquidityRemoved(liquidityAmount, stocksToSend, usdcToSend / 1e12);
    }

    function swapExactInput(
        bool usdcInput,
        uint256 exactInputAmount,
        address recipient,
        bytes memory callbackData,
        bytes[] memory priceUpdateData
    ) external payable whenNotPaused nonReentrant returns (uint256) {
        updatePriceFeeds(priceUpdateData);
        exactInputAmount *= (usdcInput ? 1e12 : 1);
        address inputToken = usdcInput
            ? address(usdcToken)
            : address(stockToken);
        address outputToken = usdcInput
            ? address(stockToken)
            : address(usdcToken);
        uint256 stockTokenPrice = getStockTokenPrice();
        uint256 usdcTokenPrice = 1e18;
        uint256 netOutputTokenAmount;
        {
            uint256 outputTokenPrice = usdcInput
                ? stockTokenPrice
                : usdcTokenPrice;
            uint256 inputTokenPrice = usdcInput
                ? usdcTokenPrice
                : stockTokenPrice;
            uint256 grossOutputTokenAmount = (exactInputAmount *
                inputTokenPrice) / outputTokenPrice;
            uint256 feeRate = usdcInput
                ? getBuyFeeRate(
                    grossOutputTokenAmount,
                    stockTokenPrice,
                    usdcTokenPrice
                )
                : getSellFeeRate(
                    exactInputAmount,
                    stockTokenPrice,
                    usdcTokenPrice
                );

            netOutputTokenAmount =
                (grossOutputTokenAmount * (1e18 - feeRate)) /
                1e18;
            if (usdcInput) {
                collectedProtocolFeesStock +=
                    ((grossOutputTokenAmount - netOutputTokenAmount) *
                        protocolFeeRate) /
                    1e18;
            } else {
                collectedProtocolFeesUsdc +=
                    ((grossOutputTokenAmount - netOutputTokenAmount) *
                        protocolFeeRate) /
                    1e18;
            }
        }

        if (usdcInput) {
            exactInputAmount /= 1e12;
        } else {
            netOutputTokenAmount /= 1e12;
        }

        if (netOutputTokenAmount == 0) {
            revert DclexPool__ZeroOutputAmount();
        }

        IERC20(outputToken).safeTransfer(recipient, netOutputTokenAmount);
        {
            uint256 inputBalanceBefore = IERC20(inputToken).balanceOf(
                address(this)
            );
            IDclexSwapCallback(msg.sender).dclexSwapCallback(
                inputToken,
                exactInputAmount,
                callbackData
            );
            uint256 inputBalanceAfter = IERC20(inputToken).balanceOf(
                address(this)
            );
            if (inputBalanceBefore + exactInputAmount > inputBalanceAfter) {
                revert DclexPool__InsufficientInputAmount();
            }
        }
        emit SwapExecuted(
            usdcInput,
            exactInputAmount,
            netOutputTokenAmount,
            stockTokenPrice,
            usdcTokenPrice,
            recipient
        );
        return netOutputTokenAmount;
    }

    function swapExactOutput(
        bool usdcInput,
        uint256 exactOutputAmount,
        address recipient,
        bytes memory callbackData,
        bytes[] memory priceUpdateData
    ) external payable whenNotPaused nonReentrant returns (uint256) {
        updatePriceFeeds(priceUpdateData);
        exactOutputAmount *= (usdcInput ? 1 : 1e12);
        address inputToken = usdcInput
            ? address(usdcToken)
            : address(stockToken);
        address outputToken = usdcInput
            ? address(stockToken)
            : address(usdcToken);
        uint256 stockTokenPrice = getStockTokenPrice();
        uint256 usdcTokenPrice = 1e18;
        uint256 grossInputTokenAmount;
        {
            uint256 outputTokenPrice = usdcInput
                ? stockTokenPrice
                : usdcTokenPrice;
            uint256 inputTokenPrice = usdcInput
                ? usdcTokenPrice
                : stockTokenPrice;
            uint256 netInputTokenAmount = (exactOutputAmount *
                outputTokenPrice) / inputTokenPrice;
            if ((exactOutputAmount * outputTokenPrice) % inputTokenPrice != 0) {
                netInputTokenAmount += 1;
            }
            uint256 feeRate = usdcInput
                ? getBuyFeeRate(
                    exactOutputAmount,
                    stockTokenPrice,
                    usdcTokenPrice
                )
                : getSellFeeRate(
                    netInputTokenAmount,
                    stockTokenPrice,
                    usdcTokenPrice
                );
            grossInputTokenAmount =
                (netInputTokenAmount * (1e18 + feeRate)) /
                1e18;
            if (usdcInput) {
                collectedProtocolFeesUsdc +=
                    ((grossInputTokenAmount - netInputTokenAmount) *
                        protocolFeeRate) /
                    1e18;
            } else {
                collectedProtocolFeesStock +=
                    ((grossInputTokenAmount - netInputTokenAmount) *
                        protocolFeeRate) /
                    1e18;
            }
        }

        if (usdcInput) {
            grossInputTokenAmount /= 1e12;
        } else {
            exactOutputAmount /= 1e12;
        }

        if (grossInputTokenAmount == 0) {
            revert DclexPool__ZeroOutputAmount();
        }

        IERC20(outputToken).safeTransfer(recipient, exactOutputAmount);
        {
            uint256 inputBalanceBefore = IERC20(inputToken).balanceOf(
                address(this)
            );
            IDclexSwapCallback(msg.sender).dclexSwapCallback(
                inputToken,
                grossInputTokenAmount,
                callbackData
            );
            uint256 inputBalanceAfter = IERC20(inputToken).balanceOf(
                address(this)
            );
            if (
                inputBalanceBefore + grossInputTokenAmount > inputBalanceAfter
            ) {
                revert DclexPool__InsufficientInputAmount();
            }
        }
        emit SwapExecuted(
            usdcInput,
            grossInputTokenAmount,
            exactOutputAmount,
            stockTokenPrice,
            usdcTokenPrice,
            recipient
        );
        return grossInputTokenAmount;
    }

    function getStockTokenPrice() private view returns (uint256 price) {
        uint256 stockSharePrice = currentUsdPrice(stockPriceFeedId);
        (uint256 numerator, uint256 denominator) = stockToken.multiplier();
        return (stockSharePrice * numerator) / denominator;
    }

    function currentUsdPrice(
        bytes32 priceFeedId
    ) private view returns (uint256) {
        IPriceOracle.Price memory p = oracle.getPriceNoOlderThan(
            priceFeedId,
            maxPriceStaleness
        );
        return _convertToUint(p.price, p.expo, DECIMALS);
    }

    function _convertToUint(
        int64 price,
        int32 expo,
        uint8 targetDecimals
    ) private pure returns (uint256) {
        if (price < 0 || expo > 0 || expo < -255) {
            revert DclexPool__InvalidPriceOrExponent();
        }
        uint8 priceDecimals = uint8(uint32(-1 * expo));
        if (targetDecimals >= priceDecimals) {
            return
                uint256(uint64(price)) *
                10 ** uint32(targetDecimals - priceDecimals);
        } else {
            return
                uint256(uint64(price)) /
                10 ** uint32(priceDecimals - targetDecimals);
        }
    }

    function getBuyFeeRate(
        uint256 stockOutputAmount,
        uint256 stockPrice,
        uint256 usdcPrice
    ) private view returns (uint256) {
        (
            uint256 stocksRatioBefore,
            uint256 totalValue
        ) = getStocksRatioTotalValue(stockPrice, usdcPrice);
        uint256 stocksRatioDelta = (stockOutputAmount * stockPrice) /
            totalValue;
        if (stocksRatioDelta >= stocksRatioBefore) {
            revert DclexPool__NotEnoughPoolLiquidity();
        }
        uint256 stocksRatioAfter = stocksRatioBefore - stocksRatioDelta;
        uint256 ratiosProduct = (stocksRatioBefore * stocksRatioAfter) / 1e18;
        uint256 inverseRatiosProduct = 1e36 / ratiosProduct;
        return feeCurveB + (feeCurveA * inverseRatiosProduct) / 1e18;
    }

    function getSellFeeRate(
        uint256 stockInputAmount,
        uint256 stockPrice,
        uint256 usdcPrice
    ) private view returns (uint256) {
        (
            uint256 stocksRatioBefore,
            uint256 totalValue
        ) = getStocksRatioTotalValue(stockPrice, usdcPrice);
        uint256 stocksRatioAfter = stocksRatioBefore +
            (stockInputAmount * stockPrice) /
            totalValue;
        if (stocksRatioAfter >= 1e18) {
            revert DclexPool__NotEnoughPoolLiquidity();
        }
        uint256 ratiosProduct = (stocksRatioBefore * stocksRatioAfter) / 1e18;
        uint256 inverseRatiosProduct = 1e36 /
            (1e18 + ratiosProduct - stocksRatioBefore - stocksRatioAfter);
        return feeCurveB + (feeCurveA * inverseRatiosProduct) / 1e18;
    }

    function getStocksRatioTotalValue(
        uint256 stockPrice,
        uint256 usdcPrice
    ) private view returns (uint256, uint256) {
        (uint256 stockReserve, uint256 usdcReserve) = getReserves();
        uint256 stocksValue = (stockReserve * stockPrice) / 1e18;
        uint256 usdcValue = (usdcReserve * usdcPrice) / 1e18;
        uint256 totalValue = stocksValue + usdcValue;
        uint256 stocksRatio = (1e18 * stocksValue) / totalValue;
        return (stocksRatio, totalValue);
    }

    function setProtocolFeeRate(
        uint256 _protocolFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_protocolFeeRate > MAX_PROTOCOL_FEE_RATE) {
            revert DclexPool__ProtocolFeeRateTooHigh();
        }
        protocolFeeRate = _protocolFeeRate;
        emit ProtocolFeeRateChanged(_protocolFeeRate);
    }

    function collectedProtocolFees() external view returns (uint256, uint256) {
        return (collectedProtocolFeesStock, collectedProtocolFeesUsdc);
    }

    function withdrawCollectedProtocolFees(
        address receiver
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        stockToken.safeTransfer(receiver, collectedProtocolFeesStock);
        usdcToken.safeTransfer(receiver, collectedProtocolFeesUsdc / 1e12);
        emit ProtocolFeeWithdrawn(
            collectedProtocolFeesStock,
            collectedProtocolFeesUsdc / 1e12,
            receiver
        );
        collectedProtocolFeesStock = 0;
        collectedProtocolFeesUsdc = 0;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function getReserves() private view returns (uint256, uint256) {
        uint256 stockReserve = stockToken.balanceOf(address(this)) -
            collectedProtocolFeesStock;
        uint256 usdcReserve = usdcToken.balanceOf(address(this)) *
            1e12 -
            collectedProtocolFeesUsdc;
        return (stockReserve, usdcReserve);
    }

    function transfer(
        address to,
        uint256 amount
    ) public override whenNotPaused nonReentrant returns (bool) {
        if (!stockToken.DID().verifyTransfer(msg.sender, to)) {
            revert InvalidDID();
        }
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override whenNotPaused nonReentrant returns (bool) {
        if (!stockToken.DID().verifyTransfer(from, to)) {
            revert InvalidDID();
        }
        return super.transferFrom(from, to, amount);
    }
}
