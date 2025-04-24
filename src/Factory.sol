// SPDX-License-Identifier: MIT

pragma solidity 0.8.29;

import {ERC20} from "@solady/tokens/ERC20.sol";
import {Pair} from "./Pair.sol";



contract Factory {
    error Factory__TokensMustBeDifferent();
    error Factory__InvalidZeroAddress();
    error Factory__PairAlreadyExists();
    error Factory__NotAuthorized();

    mapping(address => mapping(address => address)) public getPair;
    address[] public pairs;

    address public feeTo;
    address public feeToSetter;

    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    event FeeToSet(address indexed feeTo);
    event FeeToSetterSet(address indexed feeToSetter);

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        if (tokenA == tokenB) {
            revert Factory__TokensMustBeDifferent();
        }

        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        if (token0 == address(0)) {
            revert Factory__InvalidZeroAddress();
        }
        if (getPair[token0][token1] != address(0)) {
            revert Factory__PairAlreadyExists();
        }

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        pairs.push(pair);
        // encode pair.bytecode + (name & symbol)
        string memory pairName = string.concat(
            "ABSwap-",
            string.concat(ERC20(token0).name(), ERC20(token1).name())
        );
        string memory pairSymbol = string.concat(
            "AB-",
            string.concat(ERC20(token0).symbol(), ERC20(token1).symbol())
        );

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        pair = address(new Pair{salt: salt}(token0, token1));


        emit PairCreated(token0, token1, pair, pairs.length);
    }

    function getAllPairs() external view returns (uint256) {
        return pairs.length;
    }

    function setFeeTo(address _feeTo) external {
        if (msg.sender != feeToSetter) {
            revert Factory__NotAuthorized();
        }
        if (_feeTo == address(0)) {
            revert Factory__InvalidZeroAddress();
        }
        feeTo = _feeTo;

        emit FeeToSet(feeTo);
    }

    function setFeeToSetter(address _feeToSetter) external {
        if (msg.sender != feeToSetter) {
            revert Factory__NotAuthorized();
        }
        if (_feeToSetter == address(0)) {
            revert Factory__InvalidZeroAddress();
        }
        feeToSetter = _feeToSetter;

        emit FeeToSetterSet(feeToSetter);
    }

    
}
