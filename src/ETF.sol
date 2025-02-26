// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IETF} from "./interfaces/IETF.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Path} from "./libraries/Path.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IV3SwapRouter} from "./interfaces/IV3SwapRouter.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IETFQuoter} from "./interfaces/IETFQuoter.sol";

contract ETF is IETF, ERC20, Ownable {
    using SafeERC20 for IERC20;
    using FullMath for uint256;
    using Path for bytes;

    uint24 public constant HUNDRED_PERCENT = 1000000;
    uint256 public constant INDEX_SCALE = 1e36;

    address public feeTo;
    uint24 public investFee;
    uint24 public redeemFee;
    uint256 public minMintAmount;
    address public immutable swapRouter;
    address public immutable weth;
    address public etfQuoter;

    uint256 public lastRebalanceTime;
    uint256 public rebalanceInterval;
    uint24 public rebalanceDeviance;

    address public miningToken;
    uint256 public miningSpeedPerSecond;
    uint256 public miningLastIndex;
    uint256 public lastIndexUpdateTime;

    mapping(address token => address priceFeed) public getPriceFeed;
    mapping(address token => uint24 targetWeight) public getTokenTargetWeight;
    mapping(address => uint256) public supplierLastIndex;
    mapping(address => uint256) public supplierRewardAccrued;

    address[] private _tokens; // tokens list
    uint256[] private _initTokenAmountPerShares; // Token amount required per 1 ETF share，used in the first invest

    modifier _checkTotalWeights() {
        uint24 totalWeights;
        for (uint256 i = 0; i < _tokens.length; i++) {
            totalWeights += getTokenTargetWeight[_tokens[i]];
        }
        if (totalWeights != HUNDRED_PERCENT) revert InvalidTotalWeights();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 minMintAmount_,
        address[] memory tokens_,
        uint256[] memory initTokenAmountPerShares_,
        address swapRouter_,
        address weth_,
        address etfQuoter_,
        address miningToken_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        _tokens = tokens_;
        _initTokenAmountPerShares = initTokenAmountPerShares_;
        minMintAmount = minMintAmount_;
        swapRouter = swapRouter_;
        weth = weth_;
        etfQuoter = etfQuoter_;
        miningToken = miningToken_;
        miningLastIndex = 1e36;
    }

    receive() external payable {}

    function setFee(
        address feeTo_,
        uint24 investFee_,
        uint24 redeemFee_
    ) external onlyOwner {
        feeTo = feeTo_;
        investFee = investFee_;
        redeemFee = redeemFee_;
    }

    function updateMinMintAmount(uint256 newMinMintAmount_) external onlyOwner {
        emit MinMintAmountUpdated(minMintAmount, newMinMintAmount_);

        minMintAmount = newMinMintAmount_;
    }

    function getTokens() public view returns (address[] memory) {
        return _tokens;
    }

    function getInitTokenAmountPerShares()
        external
        view
        returns (uint256[] memory)
    {
        return _initTokenAmountPerShares;
    }

    // invest etf with all tokens ([weth, wbtc, usdc ......]  ->  etf)
    function invest(address to_, uint256 mintAmount_) external {
        uint256[] memory tokenAmounts = _invest(to_, mintAmount_);

        for (uint256 i = 0; i < _tokens.length; i++) {
            if (tokenAmounts[i] > 0) {
                IERC20(_tokens[i]).safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenAmounts[i]
                );
            }
        }
    }

    // invest etf with ETH (ETH  ->  etf)
    function investWithETH(
        address to_,
        uint256 mintAmount_,
        bytes[] memory swapPaths_
    ) external payable {
        if (swapPaths_.length != _tokens.length) revert InvalidArrayLength();

        uint256[] memory tokenAmounts = getInvestTokenAmounts(mintAmount_);
        uint256 maxETHAmount = msg.value;
        IWETH(weth).deposit{value: maxETHAmount}();
        _approveToSwapRouter(weth);

        uint256 totalPaid;
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (tokenAmounts[i] == 0) continue;
            if (!_checkSwapPath(_tokens[i], weth, swapPaths_[i]))
                revert InvalidSwapPath(swapPaths_[i]);
            if (_tokens[i] == weth) {
                totalPaid += tokenAmounts[i];
            } else {
                totalPaid += IV3SwapRouter(swapRouter).exactOutput(
                    IV3SwapRouter.ExactOutputParams({
                        path: swapPaths_[i],
                        recipient: address(this),
                        amountOut: tokenAmounts[i],
                        amountInMaximum: type(uint256).max
                    })
                );
            }
        }

        uint256 leftAfterPaid = maxETHAmount - totalPaid;
        IWETH(weth).withdraw(leftAfterPaid);
        payable(msg.sender).transfer(leftAfterPaid);

        _invest(to_, mintAmount_);

        emit InvestedWithETH(to_, mintAmount_, totalPaid);
    }

    // invest etf with single token (token  ->  etf)
    function investWithToken(
        address srcToken_,
        address to_,
        uint256 mintAmount_,
        uint256 maxSrcTokenAmount_,
        bytes[] memory swapPaths_
    ) external {
        if (swapPaths_.length != _tokens.length) revert InvalidArrayLength();

        uint256[] memory tokenAmounts = getInvestTokenAmounts(mintAmount_);
        IERC20(srcToken_).safeTransferFrom(
            msg.sender,
            address(this),
            maxSrcTokenAmount_
        );
        _approveToSwapRouter(srcToken_);

        uint256 totalPaid;
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (tokenAmounts[i] == 0) continue;
            if (!_checkSwapPath(_tokens[i], srcToken_, swapPaths_[i]))
                revert InvalidSwapPath(swapPaths_[i]);
            if (_tokens[i] == srcToken_) {
                totalPaid += tokenAmounts[i];
            } else {
                totalPaid += IV3SwapRouter(swapRouter).exactOutput(
                    IV3SwapRouter.ExactOutputParams({
                        path: swapPaths_[i],
                        recipient: address(this),
                        amountOut: tokenAmounts[i],
                        amountInMaximum: type(uint256).max
                    })
                );
            }
        }
        if (totalPaid > maxSrcTokenAmount_) revert OverSlippage();
        uint256 leftAfterPaid = maxSrcTokenAmount_ - totalPaid;
        IERC20(srcToken_).safeTransfer(msg.sender, leftAfterPaid);

        _invest(to_, mintAmount_);

        emit InvestedWithToken(srcToken_, to_, mintAmount_, totalPaid);
    }

    // redeem etf to all tokens (etf  ->  [weth, wbtc, usdc ......])
    function redeem(address to_, uint256 burnAmount_) external {
        _redeem(to_, burnAmount_);
    }

    // redeem etf to ETH (etf  ->  ETH)
    function redeemToETH(
        address to_,
        uint256 burnAmount_,
        uint256 minETHAmount_,
        bytes[] memory swapPaths_
    ) external {
        if (swapPaths_.length != _tokens.length) revert InvalidArrayLength();

        uint256[] memory tokenAmounts = _redeem(address(this), burnAmount_);
        uint256 totalReceived;
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (tokenAmounts[i] == 0) continue;
            if (!_checkSwapPath(_tokens[i], weth, swapPaths_[i]))
                revert InvalidSwapPath(swapPaths_[i]);
            if (_tokens[i] == weth) {
                totalReceived += tokenAmounts[i];
            } else {
                _approveToSwapRouter(_tokens[i]);
                totalReceived += IV3SwapRouter(swapRouter).exactInput(
                    IV3SwapRouter.ExactInputParams({
                        path: swapPaths_[i],
                        recipient: address(this),
                        amountIn: tokenAmounts[i],
                        amountOutMinimum: 1
                    })
                );
            }
        }

        if (totalReceived < minETHAmount_) revert OverSlippage();
        IWETH(weth).withdraw(totalReceived);
        _safeTransferETH(to_, totalReceived);

        emit RedeemedToETH(to_, burnAmount_, totalReceived);
    }

    // redeem etf to single token (etf  ->  token)
    function redeemToToken(
        address dstToken_,
        address to_,
        uint256 burnAmount_,
        uint256 minDstTokenAmount_,
        bytes[] memory swapPaths_
    ) external {
        if (swapPaths_.length != _tokens.length) revert InvalidArrayLength();
        uint256[] memory tokenAmounts = _redeem(address(this), burnAmount_);

        uint256 totalReceived;
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (tokenAmounts[i] == 0) continue;
            if (!_checkSwapPath(_tokens[i], dstToken_, swapPaths_[i]))
                revert InvalidSwapPath(swapPaths_[i]);
            if (_tokens[i] == dstToken_) {
                totalReceived += tokenAmounts[i];
            } else {
                _approveToSwapRouter(_tokens[i]);
                totalReceived += IV3SwapRouter(swapRouter).exactInput(
                    IV3SwapRouter.ExactInputParams({
                        path: swapPaths_[i],
                        recipient: address(this),
                        amountIn: tokenAmounts[i],
                        amountOutMinimum: 1
                    })
                );
            }
        }

        if (totalReceived < minDstTokenAmount_) revert OverSlippage();
        IERC20(dstToken_).safeTransfer(to_, totalReceived);

        emit RedeemedToToken(dstToken_, to_, burnAmount_, totalReceived);
    }

    function _invest(
        address to_,
        uint256 mintAmount_
    ) internal returns (uint256[] memory tokenAmounts) {
        if (mintAmount_ < minMintAmount)
            revert LessThanMinMintAmount(mintAmount_);

        tokenAmounts = getInvestTokenAmounts(mintAmount_);
        uint256 fee;
        if (investFee > 0) {
            fee = (mintAmount_ * investFee) / HUNDRED_PERCENT;
            _mint(feeTo, fee);
            _mint(to_, mintAmount_ - fee);
        } else {
            _mint(to_, mintAmount_);
        }

        emit Invested(to_, mintAmount_, fee, tokenAmounts);
    }

    function getInvestTokenAmounts(
        uint256 mintAmount_
    ) public view returns (uint256[] memory tokenAmounts) {
        uint256 totalSupply = totalSupply();
        tokenAmounts = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (totalSupply > 0) {
                uint256 tokenReserve = IERC20(_tokens[i]).balanceOf(
                    address(this)
                );
                // tokenAmount / tokenReserve = mintAmount / totalSupply
                tokenAmounts[i] = mintAmount_.mulDivRoundingUp(
                    tokenReserve,
                    totalSupply
                );
            } else {
                tokenAmounts[i] = mintAmount_.mulDivRoundingUp(
                    _initTokenAmountPerShares[i],
                    1e18
                );
            }
        }
    }

    function _redeem(
        address to_,
        uint256 burnAmount_
    ) internal returns (uint256[] memory tokenAmounts) {
        tokenAmounts = getRedeemTokenAmounts(burnAmount_);

        uint256 fee;
        if (redeemFee > 0) {
            fee = (burnAmount_ * redeemFee) / HUNDRED_PERCENT;
            _mint(feeTo, fee);
        }

        for (uint256 i = 0; i < _tokens.length; i++) {
            if (to_ != address(this) && tokenAmounts[i] > 0) {
                IERC20(_tokens[i]).safeTransfer(to_, tokenAmounts[i]);
            }
        }

        _burn(msg.sender, burnAmount_);

        emit Redeemed(msg.sender, to_, burnAmount_, fee, tokenAmounts);
    }

    function getRedeemTokenAmounts(
        uint256 burnAmount_
    ) public view returns (uint256[] memory tokenAmounts) {
        if (redeemFee > 0) {
            uint256 fee = (burnAmount_ * redeemFee) / HUNDRED_PERCENT;
            burnAmount_ -= fee;
        }

        uint256 totalSupply = totalSupply();
        tokenAmounts = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 tokenReserve = IERC20(_tokens[i]).balanceOf(address(this));
            // tokenAmount / tokenReserve = burnAmount / totalSupply
            tokenAmounts[i] = tokenReserve.mulDiv(burnAmount_, totalSupply);
        }
    }

    function _approveToSwapRouter(address token_) internal {
        if (
            IERC20(token_).allowance(address(this), swapRouter) <
            type(uint256).max
        ) {
            IERC20(token_).forceApprove(swapRouter, type(uint256).max);
        }
    }

    function _checkSwapPath(
        address tokenA_,
        address tokenB_,
        bytes memory path
    ) internal pure returns (bool) {
        (address firstToken, address secondToken, ) = path.decodeFirstPool();
        if (tokenA_ == tokenB_) {
            if (
                firstToken == tokenA_ &&
                secondToken == tokenA_ &&
                !path.hasMultiplePools()
            ) {
                return true;
            } else {
                return false;
            }
        } else {
            if (firstToken != tokenA_) return false;
            while (path.hasMultiplePools()) {
                path = path.skipToken();
            }
            (, secondToken, ) = path.decodeFirstPool();
            if (secondToken != tokenB_) return false;
            return true;
        }
    }

    function _safeTransferETH(address to_, uint256 value_) internal {
        (bool success, ) = to_.call{value: value_}(new bytes(0));
        if (!success) revert SafeTransferETHFailed();
    }

    function _addToken(address token_) internal returns (uint256 index) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] == token_) revert TokenExists();
        }
        index = _tokens.length;
        _tokens.push(token_);

        emit TokenAdded(token_, index);
    }

    function _removeToken(address token_) internal returns (uint256 index) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] == token_) {
                index = i;
                _tokens[i] = _tokens[_tokens.length - 1];
                _tokens.pop();

                emit TokenRemoved(token_, index);
                return index;
            }
        }
        revert TokenNotFound();
    }

    function setPriceFeeds(
        address[] memory tokens_,
        address[] memory priceFeeds_
    ) external onlyOwner {
        if (tokens_.length != priceFeeds_.length) revert DifferentArrayLength();
        for (uint256 i = 0; i < tokens_.length; i++) {
            getPriceFeed[tokens_[i]] = priceFeeds_[i];
        }
    }

    function setTokenTargetWeights(
        address[] memory tokens_,
        uint24[] memory targetWeights_
    ) external onlyOwner {
        if (tokens_.length != targetWeights_.length)
            revert DifferentArrayLength();
        for (uint256 i = 0; i < tokens_.length; i++) {
            getTokenTargetWeight[tokens_[i]] = targetWeights_[i];
        }
    }

    function updateRebalanceInterval(uint256 newInterval_) external onlyOwner {
        rebalanceInterval = newInterval_;
    }

    function updateRebalanceDeviance(uint24 newDeviance_) external onlyOwner {
        rebalanceDeviance = newDeviance_;
    }

    function addToken(address token_) external onlyOwner {
        _addToken(token_);
    }

    function removeToken(address token_) external onlyOwner {
        if (
            getTokenTargetWeight[token_] > 0 ||
            IERC20(token_).balanceOf(address(this)) > 0
        ) revert Forbidden();
        _removeToken(token_);
    }

    function getTokenMarketValues()
        public
        view
        returns (
            address[] memory tokens,
            int256[] memory tokenPrices,
            uint256[] memory tokenMarketValues,
            uint256 totalValues
        )
    {
        tokens = getTokens();
        tokenPrices = new int256[](tokens.length);
        tokenMarketValues = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            AggregatorV3Interface priceFeed = AggregatorV3Interface(
                getPriceFeed[tokens[i]]
            );
            if (address(priceFeed) == address(0)) {
                revert PriceFeedNotFound(tokens[i]);
            } else {
                (, tokenPrices[i], , , ) = priceFeed.latestRoundData();
            }

            uint8 decimals = IERC20Metadata(tokens[i]).decimals();
            uint256 reserve = IERC20(tokens[i]).balanceOf(address(this));
            tokenMarketValues[i] = reserve.mulDiv(
                uint256(tokenPrices[i]),
                10 ** decimals
            );
            totalValues += tokenMarketValues[i];
        }
    }

    function rebalance() external _checkTotalWeights {
        if (block.timestamp < lastRebalanceTime + rebalanceInterval)
            revert NotRebalanceTime();
        lastRebalanceTime = block.timestamp;

        (
            address[] memory tokens,
            int256[] memory tokenPrices,
            uint256[] memory tokenMarketValues,
            uint256 totalValues
        ) = getTokenMarketValues();

        int256[] memory tokenSwapAmounts = new int256[](tokens.length);
        uint256[] memory reservesBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            reservesBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
            uint24 tokenWeight = getTokenTargetWeight[tokens[i]];
            if (tokenWeight == 0) continue;
            uint256 weightedValue = (totalValues * tokenWeight) /
                HUNDRED_PERCENT;
            uint256 lowerValue = (weightedValue *
                (HUNDRED_PERCENT - rebalanceDeviance)) / HUNDRED_PERCENT;
            uint256 upperValue = (weightedValue *
                (HUNDRED_PERCENT + rebalanceDeviance)) / HUNDRED_PERCENT;
            if (
                tokenMarketValues[i] > upperValue ||
                tokenMarketValues[i] < lowerValue
            ) {
                int256 deltaValue = int256(tokenMarketValues[i]) -
                    int256(weightedValue);
                uint8 decimals = IERC20Metadata(tokens[i]).decimals();
                if (deltaValue < 0) {
                    tokenSwapAmounts[i] = int256(
                        uint256(deltaValue).mulDiv(
                            10 ** decimals,
                            uint256(tokenPrices[i])
                        )
                    );
                } else {
                    tokenSwapAmounts[i] = -int256(
                        uint256(-deltaValue).mulDiv(
                            10 ** decimals,
                            uint256(tokenPrices[i])
                        )
                    );
                }
            }
        }

        _swapTokens(tokens, tokenSwapAmounts);

        uint256[] memory reservesAfter = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            reservesAfter[i] = IERC20(tokens[i]).balanceOf(address(this));
        }

        emit Rebalanced(reservesBefore, reservesAfter);
    }

    function _swapTokens(
        address[] memory tokens,
        int256[] memory tokenSwapAmounts
    ) internal {
        //sells first, then get usdc to buy.
        address usdc = IETFQuoter(etfQuoter).usdc();
        uint256 usdcRemaining = _sellTokens(usdc, tokens, tokenSwapAmounts);

        usdcRemaining = _buyTokens(
            usdc,
            tokens,
            tokenSwapAmounts,
            usdcRemaining
        );

        if (usdcRemaining > 0) {
            uint256 usdcLeft = usdcRemaining;
            for (uint256 i = 0; i < tokens.length; i++) {
                uint256 amountIn = (usdcRemaining *
                    getTokenTargetWeight[tokens[i]]) / HUNDRED_PERCENT;
                if (amountIn == 0) continue;
                if (amountIn > usdcLeft) amountIn = usdcLeft;

                (bytes memory path, ) = IETFQuoter(etfQuoter).quoteExactIn(
                    usdc,
                    tokens[i],
                    amountIn
                );
                IV3SwapRouter(swapRouter).exactInput(
                    IV3SwapRouter.ExactInputParams({
                        path: path,
                        recipient: address(this),
                        amountIn: amountIn,
                        amountOutMinimum: 1
                    })
                );
                usdcLeft -= amountIn;
                if (usdcLeft == 0) break;
            }
        }
    }

    function _sellTokens(
        address usdc,
        address[] memory tokens,
        int256[] memory tokenSwapAmounts
    ) internal returns (uint256 usdcRemaining) {
        if (tokens.length != tokenSwapAmounts.length)
            revert DifferentArrayLength();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenSwapAmounts[i] < 0) {
                _approveToSwapRouter(tokens[i]);
                (bytes memory path, ) = IETFQuoter(etfQuoter).quoteExactIn(
                    tokens[i],
                    usdc,
                    uint256(-tokenSwapAmounts[i])
                );
                usdcRemaining += IV3SwapRouter(swapRouter).exactInput(
                    IV3SwapRouter.ExactInputParams({
                        path: path,
                        recipient: address(this),
                        amountIn: uint256(-tokenSwapAmounts[i]),
                        amountOutMinimum: 1
                    })
                );
            }
        }
    }

    function _buyTokens(
        address usdc,
        address[] memory tokens,
        int256[] memory tokenSwapAmounts,
        uint256 usdcAmount
    ) internal returns (uint256 usdcRemaining) {
        if (tokens.length != tokenSwapAmounts.length)
            revert DifferentArrayLength();
        usdcRemaining = usdcAmount;
        _approveToSwapRouter(usdc);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokenSwapAmounts[i] > 0) {
                (bytes memory path, uint256 amountIn) = IETFQuoter(etfQuoter)
                    .quoteExactOut(
                        usdc,
                        tokens[i],
                        uint256(tokenSwapAmounts[i])
                    );
                if (usdcRemaining >= amountIn) {
                    usdcRemaining -= IV3SwapRouter(swapRouter).exactOutput(
                        IV3SwapRouter.ExactOutputParams({
                            path: path,
                            recipient: address(this),
                            amountOut: uint256(tokenSwapAmounts[i]),
                            amountInMaximum: type(uint256).max
                        })
                    );
                } else if (usdcRemaining > 0) {
                    (path, ) = IETFQuoter(etfQuoter).quoteExactIn(
                        usdc,
                        tokens[i],
                        usdcRemaining
                    );
                    IV3SwapRouter(swapRouter).exactInput(
                        IV3SwapRouter.ExactInputParams({
                            path: path,
                            recipient: address(this),
                            amountIn: usdcRemaining,
                            amountOutMinimum: 1
                        })
                    );
                    usdcRemaining = 0;
                    break;
                }
            }
        }
    }

    function updateMiningSpeedPerSecond(uint256 newSpeed) external onlyOwner {
        _updateMiningIndex();
        miningSpeedPerSecond = newSpeed;
    }

    function withdrawMiningToken(address to, uint256 amount) external onlyOwner {
        IERC20(miningToken).safeTransfer(to, amount);
    }

    function claimReward() external {
        _updateMiningIndex();
        _updateSupplierIndex(msg.sender);

        uint256 claimable = supplierRewardAccrued[msg.sender];
        if(claimable == 0) revert NothingClaimable();

        supplierRewardAccrued[msg.sender] = 0;
        IERC20(miningToken).safeTransfer(msg.sender, claimable);

        emit RewardClaimed(msg.sender, claimable);
    }

    function getClaimableReward() external view returns(uint256 claimable) {
        claimable = supplierRewardAccrued[msg.sender];

        uint256 globalLastIndex = miningLastIndex;
        uint256 totalSupply = totalSupply();
        uint256 deltaTime = block.timestamp - lastIndexUpdateTime;
        if(totalSupply > 0 && deltaTime > 0 && miningSpeedPerSecond > 0) {
            uint256 deltaReward = miningSpeedPerSecond * deltaTime;
            uint256 deltaIndex = deltaReward.mulDiv(INDEX_SCALE, totalSupply);
            globalLastIndex += deltaIndex;
        }

        uint256 supplierIndex = supplierLastIndex[msg.sender];
        uint256 supplierSupply = balanceOf(msg.sender);
        uint256 supplierDeltaIndex;
        if(supplierIndex > 0 && supplierSupply > 0) {
            supplierDeltaIndex = globalLastIndex - supplierIndex;
            uint256 supplierDeltaReward = supplierSupply.mulDiv(supplierDeltaIndex, INDEX_SCALE);
            claimable += supplierDeltaReward;
        }

        return claimable;
    }

    function _updateMiningIndex() internal {
        if(miningLastIndex == 0) {
            miningLastIndex = INDEX_SCALE;
            lastIndexUpdateTime = block.timestamp;
        } else {
            uint256 totalSupply = totalSupply();
            uint256 deltaTime = block.timestamp - lastIndexUpdateTime;
            if(totalSupply > 0 && deltaTime > 0 && miningSpeedPerSecond > 0) {
                uint256 deltaReward = miningSpeedPerSecond * deltaTime;
                uint256 deltaIndex = deltaReward.mulDiv(INDEX_SCALE, totalSupply);
                miningLastIndex += deltaIndex;
                lastIndexUpdateTime = block.timestamp;
            } else if(deltaTime > 0) {
                lastIndexUpdateTime = block.timestamp;
            }
        }
    }

    function _updateSupplierIndex(address supplier) internal {
        uint256 supplierIndex = supplierLastIndex[supplier];
        uint256 supplierSupply = balanceOf(supplier);
        uint256 supplierDeltaIndex;
        if(supplierIndex > 0 && supplierSupply > 0) {
            supplierDeltaIndex = miningLastIndex - supplierIndex;
            uint256 supplierDeltaReward = supplierSupply.mulDiv(supplierDeltaIndex, INDEX_SCALE);
            supplierRewardAccrued[supplier] += supplierDeltaReward;
        }
        supplierLastIndex[supplier] = miningLastIndex;
        emit SupplierIndexUpdated(supplier, supplierDeltaIndex, supplierIndex);
    }

    function _update(address from, address to, uint256 value) internal override {
        _updateMiningIndex();
        if(from != address(0)) _updateSupplierIndex(from);
        if(to != address(0)) _updateSupplierIndex(to);
        super._update(from, to, value);
    }
}
