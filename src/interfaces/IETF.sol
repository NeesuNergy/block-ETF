// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IETF {
    error LessThanMinMintAmount(uint256 mintAmount);
    error TokenNotFound();
    error TokenExists();
    error InvalidSwapPath(bytes swapPath);
    error InvalidArrayLength();
    error OverSlippage();
    error SafeTransferETHFailed();
    error DifferentArrayLength();
    error NotRebalanceTime();
    error InvalidTotalWeights();
    error Forbidden();
    error PriceFeedNotFound(address token);
    error NothingClaimable();

    event MinMintAmountUpdated(
        uint256 oldMinMintAmount,
        uint256 newMinMintAmount
    );

    event Invested(
        address to,
        uint256 mintAmount,
        uint256 investFee,
        uint256[] tokenAmounts
    );

    event InvestedWithETH(address to, uint256 mintAmount, uint256 paidAmount);

    event InvestedWithToken(
        address indexed srcToken,
        address to,
        uint256 mintAmount,
        uint256 totalPaid
    );

    event Redeemed(
        address sender,
        address to,
        uint256 burnAmount,
        uint256 redeemFee,
        uint256[] tokenAmounts
    );

    event RedeemedToETH(address to, uint256 burnAmount, uint256 receivedAmount);

    event RedeemedToToken(
        address indexed dstToken,
        address to,
        uint256 burnAmount,
        uint256 receivedAmount
    );

    event TokenAdded(address token, uint256 index);

    event TokenRemoved(address token, uint256 index);

    event Rebalanced(uint256[] reservesBefore, uint256[] reservesAfter);

    event SupplierIndexUpdated(
        address indexed supplier,
        uint256 deltaIndex,
        uint256 lastIndex
    );

    event RewardClaimed(address indexed supplier, uint256 claimedAmount);

    function feeTo() external view returns (address);

    function investFee() external view returns (uint24);

    function redeemFee() external view returns (uint24);

    function minMintAmount() external view returns (uint256);

    function swapRouter() external view returns (address);

    function weth() external view returns (address);

    function getTokens() external view returns (address[] memory);

    function getInitTokenAmountPerShares()
        external
        view
        returns (uint256[] memory);

    function getInvestTokenAmounts(
        uint256 mintAmount
    ) external view returns (uint256[] memory);

    function getRedeemTokenAmounts(
        uint256 burnAmount
    ) external view returns (uint256[] memory);

    function setFee(address feeTo, uint24 investFee, uint24 redeemFee) external;

    function updateMinMintAmount(uint256 newMinMintAmount) external;

    function invest(address to, uint256 mintAmount) external;

    function investWithETH(
        address to,
        uint256 mintAmount,
        bytes[] memory swapPaths
    ) external payable;

    function investWithToken(
        address srcToken,
        address to,
        uint256 mintAmount,
        uint256 maxSrcTokenAmount,
        bytes[] memory swapPaths
    ) external;

    function redeem(address to, uint256 burnAmount) external;

    function redeemToETH(
        address to,
        uint256 burnAmount,
        uint256 minETHAmount,
        bytes[] memory swapPaths
    ) external;

    function redeemToToken(
        address dstToken,
        address to,
        uint256 burnAmount,
        uint256 minDstTokenAmount,
        bytes[] memory swapPaths
    ) external;

    function lastRebalanceTime() external view returns (uint256);

    function rebalanceInterval() external view returns (uint256);

    function rebalanceDeviance() external view returns (uint24);

    function getPriceFeed(
        address token
    ) external view returns (address priceFeed);

    function getTokenTargetWeight(
        address token
    ) external view returns (uint24 targetWeight);

    function getTokenMarketValues()
        external
        view
        returns (
            address[] memory tokens,
            int256[] memory tokenPrices,
            uint256[] memory tokenMarketValues,
            uint256 totalValues
        );

    function addToken(address token) external;

    function removeToken(address token) external;

    function updateRebalanceInterval(uint256 newInterval) external;

    function updateRebalanceDeviance(uint24 newDeviance) external;

    function setPriceFeeds(
        address[] memory tokens,
        address[] memory priceFeeds
    ) external;

    function setTokenTargetWeights(
        address[] memory tokens,
        uint24[] memory targetWeights
    ) external;

    function rebalance() external;

    function updateMiningSpeedPerSecond(uint256 speed) external;

    function claimReward() external;

    function miningToken() external view returns (address);

    function INDEX_SCALE() external view returns (uint256);

    function miningSpeedPerSecond() external view returns (uint256);

    function miningLastIndex() external view returns (uint256);

    function lastIndexUpdateTime() external view returns (uint256);

    function supplierLastIndex(
        address supplier
    ) external view returns (uint256);

    function supplierRewardAccrued(
        address supplier
    ) external view returns (uint256);

    function getClaimableReward() external view returns (uint256);
}
