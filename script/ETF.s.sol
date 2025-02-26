// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ETF} from "../src/ETF.sol";

contract ETFScript is Script {
    string name;
    string symbol;
    address[] tokens;
    uint256[] initTokenAmountPerShares;
    uint256 minMintAmount;
    address swapRouter;
    address weth9;
    address etfQuoter;

    address feeTo;
    uint24 investFee;
    uint24 redeemFee;

    address[] priceFeeds;
    uint24[] targetWeights;

    uint256 rebalanceInterval;
    uint24 rebalanceDeviance;

    function setUp() public {
        name = "ETF";
        symbol = "sETF";

        address wbtc = 0x2e67186298e9B87D6822f02F103B11F5cb5e450C;
        address weth = 0x51C6De85b859D24c705AbC4d1fdCc3eD613b203c;
        address link = 0x7826216Cd2917f12B67880Ef513e6cDAa09dC042;
        address aud = 0xbbdb08AdB8Dc86B3D02860eD281139CD6Be453A5;
        tokens = [wbtc, weth, link, aud];

        // btc 77000, eth 3100, link 14, aud 0.6
        // weights: btc 40%, eth 30%, link 20%, aud 10%
        // 1 Share = 100U
        // btcAmountPerShare = 100 * 40% / 77000 * 1e8 = 51,948
        // ethAmountPerShare = 100 * 30% / 3100 * 1e18 = 9,677,419,354,838,710
        // linkAmountPerShare = 100 * 20% / 14 * 1e18 = 1,428,571,428,571,428,600
        // audAmountPerShare = 100 * 10% / 0.6 * 1e18 = 16,666,666,666,666,668,000
        initTokenAmountPerShares = [
            51948,
            9677419354838710,
            1428571428571428600,
            16666666666666668000
        ];

        minMintAmount = 1e18;
        swapRouter = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
        weth9 = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        etfQuoter = 0x0c3E8403cCa75dAE02FCC5C3272dCB3d01d946c4;

        feeTo = 0x1956b2c4C511FDDd9443f50b36C4597D10cD9985;
        investFee = 1000; // 0.1%
        redeemFee = 1000; // 0.1%

        address btcPriceFeed = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
        address ethPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        address linkPriceFeed = 0xc59E3633BAAC79493d908e63626716e204A45EdF;
        address audPriceFeed = 0xB0C712f98daE15264c8E26132BCC91C40aD4d5F9;
        priceFeeds = [btcPriceFeed, ethPriceFeed, linkPriceFeed, audPriceFeed];

        targetWeights = [400000, 300000, 200000, 100000];

        rebalanceInterval = 7 * 24 * 3600;
        rebalanceDeviance = 50000;
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ETF etf = new ETF(
            name,
            symbol,
            minMintAmount,
            tokens,
            initTokenAmountPerShares,
            swapRouter,
            weth9,
            etfQuoter
        );
        console.log("ETF:", address(etf));

        etf.setFee(feeTo, investFee, redeemFee);
        etf.setPriceFeeds(tokens, priceFeeds);
        etf.setTokenTargetWeights(tokens, targetWeights);

        etf.updateRebalanceInterval(rebalanceInterval);
        etf.updateRebalanceDeviance(rebalanceDeviance);

        vm.stopBroadcast();
    }
}