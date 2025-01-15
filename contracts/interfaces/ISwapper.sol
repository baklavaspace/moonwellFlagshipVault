// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ISwapper {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256);

    function getAmountsOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256);

}