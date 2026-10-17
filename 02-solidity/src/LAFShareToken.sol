// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IProtocolModuleConfig} from "./interfaces/IProtocolModuleConfig.sol";

/**
 * @title LAFShareToken
 * @notice ERC20 share token representing investor stakes in the LAF vault.
 *
 * Minted on deposit (by the vault), burned on rage quit (by the rage-quit module).
 * Inherits ERC20Votes for share-weighted snapshot governance voting.
 *
 * New holders are auto-delegated on mint or transfer so their shares count
 * toward snapshot voting without a separate transaction.
 */
contract LAFShareToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    // No account is ever assigned this role. It makes token-supply roles
    // permanently non-administerable through AccessControl after setup.
    bytes32 public constant LOCKED_ROLE_ADMIN = keccak256("LOCKED_ROLE_ADMIN");
    // LAFVault.RAGEQUIT_ROLE; the burner must be the module the vault pays.
    bytes32 private constant VAULT_RAGEQUIT_ROLE = keccak256("RAGEQUIT_ROLE");

    error ZeroAddress();
    error ModulesAlreadyConfigured();
    error InvalidModule();

    bool public modulesConfigured;

    constructor(address admin)
        ERC20("LAF Share", "LAFS")
        ERC20Permit("LAF Share")
    {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(LOCKED_ROLE_ADMIN, LOCKED_ROLE_ADMIN);
        _setRoleAdmin(MINTER_ROLE, LOCKED_ROLE_ADMIN);
        _setRoleAdmin(BURNER_ROLE, LOCKED_ROLE_ADMIN);
    }

    /// @notice One-time installation of the vault minter and rage-quit burner.
    /// @dev The external admin cannot mint or burn shares by granting itself a
    ///      token role after this configuration.
    function configureModules(address vault, address rageQuitModule) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (modulesConfigured) revert ModulesAlreadyConfigured();
        if (
            vault == address(0) || rageQuitModule == address(0) ||
            vault == rageQuitModule || vault.code.length == 0 || rageQuitModule.code.length == 0
        ) revert InvalidModule();
        if (
            IProtocolModuleConfig(vault).shareToken() != address(this) ||
            IProtocolModuleConfig(rageQuitModule).vault() != vault ||
            IProtocolModuleConfig(rageQuitModule).shareToken() != address(this)
        ) revert InvalidModule();
        // Configure the vault first: a burner the vault does not pay would
        // make rage quit revert permanently once these roles are locked.
        if (!IAccessControl(vault).hasRole(VAULT_RAGEQUIT_ROLE, rageQuitModule)) revert InvalidModule();

        modulesConfigured = true;
        _grantRole(MINTER_ROLE, vault);
        _grantRole(BURNER_ROLE, rageQuitModule);
    }

    /// @notice Mint shares to an investor. Only callable by the vault (MINTER_ROLE).
    ///         The _update hook activates voting for a new recipient.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
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
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
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
