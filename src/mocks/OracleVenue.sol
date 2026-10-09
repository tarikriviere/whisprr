// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceVenue} from "../IPriceVenue.sol";

/// @notice Inventory-backed venue that fills swaps at owner-set prices.
/// Testnet stand-in for an RWA market; prices can later be pushed from Pyth.
contract OracleVenue is IPriceVenue, Ownable {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public priceOf;

    event PriceSet(address indexed token, uint256 price);
    event Swapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    error UnknownToken(address token);
    error Slippage(uint256 amountOut, uint256 minAmountOut);

    constructor(address owner_) Ownable(owner_) {}

    function setPrice(address token, uint256 price) external onlyOwner {
        priceOf[token] = price;
        emit PriceSet(token, price);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 pIn = priceOf[tokenIn];
        uint256 pOut = priceOf[tokenOut];
        if (pIn == 0) revert UnknownToken(tokenIn);
        if (pOut == 0) revert UnknownToken(tokenOut);
        uint256 usd = amountIn * pIn / 10 ** IERC20Metadata(tokenIn).decimals();
        return usd * 10 ** IERC20Metadata(tokenOut).decimals() / pOut;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut)
    {
        amountOut = quote(tokenIn, tokenOut, amountIn);
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
}
