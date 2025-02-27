// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ETFProtocolToken} from "../src/ETFProtocolToken.sol";
import {ETFQuoter} from "../src/ETFQuoter.sol";
import {ETF} from "../src/ETF.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

contract DeployScript is Script {
    address deployer;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        deployer = vm.addr(deployerPrivateKey);

        address ept = deployProtocolToken();
        address quoter = deployQuoter();
        address proxy = deployETF(quoter, ept);
        console.log("Proxy", proxy);

        vm.stopBroadcast();
    }

    function deployProtocolToken() public returns (address ept) {
        address defaultAdmin = deployer;
        address minter = deployer;
        ept = address(new ETFProtocolToken(defaultAdmin, minter));
    }

    function deployQuoter() public returns (address quoter) {
        address uniswapV3Quoter = 0x419D1c2331faAFDbdf9144C64a3E07f19D217ebD;
        address weth9 = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        address usdc = 0x22e18Fc2C061f2A500B193E5dBABA175be7cdD7f;
        quoter = address(new ETFQuoter(weth9, usdc, uniswapV3Quoter));
    }

    function deployETF(
        address etfQuoter,
        address ept
    ) public returns (address proxy) {
        string memory name = "ETF";
        string memory symbol = "ETF";

        address[] memory tokens = new address[](4);
        address weth9 = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        {
            address BTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
            address ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            address BNB = 0xB8c77482e45F1F44dE1745F52C74426C631bDD52;
            address SOL = 0xd1D82d3Ab815E0B47e38EC2d666c5b8AA05Ae501;
            tokens[0] = BTC;
            tokens[1] = ETH;
            tokens[2] = BNB;
            tokens[3] = SOL;
        }

        address[] memory priceFeeds = new address[](4);
        {
            address btcPriceFeed = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
            address ethPriceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
            address bnbPriceFeed = 0x14e613AC84a31f709eadbdF89C6CC390fDc9540A;
            address solPriceFeed = 0x4ffC43a60e009B551865A93d232E33Fce9f01507;
            priceFeeds[0] = btcPriceFeed;
            priceFeeds[1] = ethPriceFeed;
            priceFeeds[2] = bnbPriceFeed;
            priceFeeds[3] = solPriceFeed;
        }

        uint256[] memory initTokenAmountPerShares = new uint256[](
            tokens.length
        );
        uint24[] memory targetWeights = new uint24[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            targetWeights[i] = 125000;
            uint8 tokenDecimals = IERC20Metadata(tokens[i]).decimals();
            AggregatorV3Interface priceFeed = AggregatorV3Interface(
                priceFeeds[i]
            );
            uint8 priceDecimals = priceFeed.decimals();
            (, int256 price, , , ) = priceFeed.latestRoundData();

            // 1USD per Share
            initTokenAmountPerShares[i] =
                ((10 ** (tokenDecimals + priceDecimals)) * 125000) /
                (uint256(price) * 1000000);
        }

        {
            uint256 minMintAmount = 1e16;
            address swapRouter = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

            ETF.InitializeParams memory params = ETF
                .InitializeParams(
                    deployer,
                    name,
                    symbol,
                    minMintAmount,
                    tokens,
                    initTokenAmountPerShares,
                    swapRouter,
                    weth9,
                    etfQuoter,
                    ept
                );

            proxy = Upgrades.deployTransparentProxy(
                "ETF.sol",
                deployer,
                abi.encodeCall(ETF.initialize, (params))
            );
        }

        ETF etf = ETF(payable(proxy));

        {
            address feeTo = 0x4e8Ebaa604a9c1f64b9a6EA2b0633f4B96723029;
            uint24 investFee = 1000; // 0.1%
            uint24 redeemFee = 1000; // 0.1%
            etf.setFee(feeTo, investFee, redeemFee);
        }

        etf.setPriceFeeds(tokens, priceFeeds);

        etf.setTokenTargetWeights(tokens, targetWeights);

        uint256 rebalanceInterval = 30 * 24 * 3600;
        uint24 rebalanceDeviance = 100000;
        etf.updateRebalanceInterval(rebalanceInterval);
        etf.updateRebalanceDeviance(rebalanceDeviance);

        uint256 miningSpeedPerSecond = 1e14;
        etf.updateMiningSpeedPerSecond(miningSpeedPerSecond);

        uint256 totalSupply = IERC20(ept).totalSupply();
        IERC20(ept).transfer(address(etf), totalSupply);
    }
}
