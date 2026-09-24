// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title LAFShareToken
 * @notice ERC20 share token representing investor stakes in the LAF vault.
 *
 * Minted on deposit (by the vault), burned on rage quit (by the rage-quit module).
 * Inherits ERC20Votes for snapshot-based quadratic governance voting.
 *
 * Holders must self-delegate to activate vote tracking (OZ ERC20Votes default).
 * The vault auto-delegates on mint to simplify the investor UX.
 */
contract LAFShareToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor(address admin)
        ERC20("LAF Share", "LAFS")
        ERC20Permit("LAF Share")
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mint shares to an investor. Only callable by the vault (MINTER_ROLE).
    ///         Auto-delegates to the investor so their voting power is immediately active.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
        // Auto-delegate if the investor hasn't delegated yet
        if (delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    /// @notice Burn shares from a holder. Only callable by the rage-quit module (BURNER_ROLE).
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    // ---- Required overrides for ERC20 + ERC20Votes ----

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
