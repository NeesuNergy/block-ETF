// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IETFQuoter} from "./interfaces/IETFQuoter.sol";
import {IETF} from "./interfaces/IETF.sol";
import {IUniswapV3Quoter} from "./interfaces/IUniswapV3Quoter.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ETFQuoter is IETFQuoter {
    using FullMath for uint256;

    uint24 public constant HUNDRED_PERCENT = 1000000;

    uint24[] public fees; // fees of UniswapV3
    address public immutable weth;
    address public immutable usdc;

    IUniswapV3Quoter public immutable uniswapV3Quoter;

    constructor(address weth_, address usdc_, address uniswapV3Quoter_) {
        weth = weth_;
        usdc = usdc_;
        uniswapV3Quoter = IUniswapV3Quoter(uniswapV3Quoter_);
        fees = [100, 500, 3000, 10000];
    }

    function getAllPaths(
        address tokenA,
        address tokenB
    ) public view returns (bytes[] memory paths) {
        uint256 totalPaths = fees.length + (fees.length * fees.length * 2); // there are just two intermediaries(weth/usdc)
        paths = new bytes[](totalPaths);

        uint256 index = 0;

        // 1. tokenA -> fee -> tokenB
        for (uint256 i = 0; i < fees.length; i++) {
            paths[index] = bytes.concat(
                bytes20(tokenA),
                bytes3(fees[i]),
                bytes20(tokenB)
            );
            index++;
        }

        // 2. tokenA -> fee1 -> (weth/usdc) -> fee2 -> tokenB
        address[2] memory intermediaries = [weth, usdc];
        for (uint256 i = 0; i < intermediaries.length; i++) {
            for (uint256 j = 0; j < fees.length; j++) {
                for (uint256 k = 0; k < fees.length; k++) {
                    paths[index] = bytes.concat(
                        bytes20(tokenA),
                        bytes3(fees[j]),
                        bytes20(intermediaries[i]),
                        bytes3(fees[k]),
                        bytes20(tokenB)
                    );
                    index++;
                }
            }
        }
    }

    function quoteInvestWithToken(
        address etf,
        address srcToken,
        uint256 mintAmount
    )
        external
        view
        override
        returns (uint256 srcAmount, bytes[] memory swapPaths)
    {
        address[] memory tokens = IETF(etf).getTokens();
        uint256[] memory tokenAmounts = IETF(etf).getInvestTokenAmounts(
            mintAmount
        );

        swapPaths = new bytes[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == srcToken) {
                srcAmount += tokenAmounts[i];
                swapPaths[i] = bytes.concat(
                    bytes20(srcToken),
                    bytes3(fees[0]),
                    bytes20(srcToken)
                );
            } else {
                (bytes memory path, uint256 amountIn) = quoteExactOut(
                    srcToken,
                    tokens[i],
                    tokenAmounts[i]
                );
                srcAmount += amountIn;
                swapPaths[i] = path;
            }
        }
    }

    function quoteRedeemToToken(
        address etf,
        address dstToken,
        uint256 burnAmount
    )
        external
        view
        override
        returns (uint256 dstAmount, bytes[] memory swapPaths)
    {
        address[] memory tokens = IETF(etf).getTokens();
        uint256[] memory tokenAmounts = IETF(etf).getRedeemTokenAmounts(
            burnAmount
        );

        swapPaths = new bytes[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == dstToken) {
                dstAmount += tokenAmounts[i];
                swapPaths[i] = bytes.concat(
                    bytes20(dstToken),
                    bytes3(fees[0]),
                    bytes20(dstToken)
                );
            } else {
                (bytes memory path, uint256 amountOut) = quoteExactIn(
                    tokens[i],
                    dstToken,
                    tokenAmounts[i]
                );
                dstAmount += amountOut;
                swapPaths[i] = path;
            }
        }
    }

    function quoteExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    ) public view returns (bytes memory path, uint256 amountIn) {
        bytes[] memory allPaths = getAllPaths(tokenOut, tokenIn);

        for (uint256 i = 0; i < allPaths.length; i++) {
            try
                uniswapV3Quoter.quoteExactOutput(allPaths[i], amountOut)
            returns (
                uint256 amountIn_,
                uint160[] memory,
                uint32[] memory,
                uint256
            ) {
                if (amountIn_ > 0 && (amountIn == 0 || amountIn > amountIn_)) {
                    amountIn = amountIn_;
                    path = allPaths[i];
                }
            } catch {}
        }
    }

    function quoteExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public view returns (bytes memory path, uint256 amountOut) {
        bytes[] memory allPaths = getAllPaths(tokenIn, tokenOut);

        for (uint256 i = 0; i < allPaths.length; i++) {
            try uniswapV3Quoter.quoteExactInput(allPaths[i], amountIn) returns (
                uint256 amountOut_,
                uint160[] memory,
                uint32[] memory,
                uint256
            ) {
                if (
                    amountOut_ > 0 && (amountOut == 0 || amountOut < amountOut_)
                ) {
                    amountOut = amountOut_;
                    path = allPaths[i];
                }
            } catch {}
        }
    }

    function getTokenTargetValues(
        address etf_
    )
        external
        view
        returns (
            uint24[] memory tokenTargetWeights,
            uint256[] memory tokenTargetValues,
            uint256[] memory tokenReserves
        )
    {
        IETF etfContract = IETF(etf_);

        address[] memory tokens;
        int256[] memory tokenPrices;
        uint256[] memory tokenMarketValues;
        uint256 totalValues;
        (tokens, tokenPrices, tokenMarketValues, totalValues) = etfContract
            .getTokenMarketValues();

        tokenTargetWeights = new uint24[](tokens.length);
        tokenTargetValues = new uint256[](tokens.length);
        tokenReserves = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            tokenTargetWeights[i] = etfContract.getTokenTargetWeight(tokens[i]);
            tokenTargetValues[i] =
                (totalValues * tokenTargetWeights[i]) /
                HUNDRED_PERCENT;
            tokenReserves[i] = IERC20(tokens[i]).balanceOf(etf_);
        }
    }
}
