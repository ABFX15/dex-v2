// SPDX-License-Identifier: MIT

pragma solidity 0.8.29;

interface ISwapCall {
    function swapCall(address sender, uint amount0, uint amount1, bytes calldata data) external;
}