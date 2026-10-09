// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A venue that quotes USD prices and fills swaps at them.
interface IPriceVenue {
    /// @return USD price of one whole token, scaled to 1e18.
    function priceOf(address token) external view returns (uint256);

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut);
}
