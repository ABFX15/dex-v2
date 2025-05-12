// SPDX-License-Identifier: MIT

pragma solidity 0.8.29;

import {IERC20} from "@solady/tokens/ERC20.sol";

contract Token is IERC20 {
    error Token__PermitDeadlineExpired();
    error Token__PermitNonceUsed(uint256 nonce);
    error Token__PermitZeroAddress();
    error Token__InvalidSignature();

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
    bytes32 public immutable i_DOMAIN_SEPARATOR;

    mapping(address => mapping(uint256 => bool)) public nonces;

    constructor(string memory name, string memory symbol) ERC20() {
        i_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name, string version, uint256 chainId, address verifyingContract)"
                ),
                name,
                "1.0",
                block.chainid,
                address(this)
            )
        );
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (deadline < block.timestamp) revert Token__PermitDeadlineExpired();
        if (nonces[owner][nonce]) revert Token__PermitNonceUsed(nonce);
        if (owner == address(0) || spender == address(0))
            revert Token__PermitZeroAddress();

        bytes32 message = keccak256(
            abi.encodePacked(
                "\x19\x01",
                i_DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonce,
                        deadline
                    )
                )
            )
        );

        address signedFrom = ecrecover(message, v, r, s);
        if (signedFrom != owner) revert Token__InvalidSignature();
        nonces[owner][nonce] = true;
        _approve(owner, spender, value);
    }
}
