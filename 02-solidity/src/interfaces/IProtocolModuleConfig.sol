// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Common read-only wiring exposed by LAF system modules.
/// @dev Used during one-time role setup to reject modules attached to a
///      different vault/share token.
interface IProtocolModuleConfig {
    function vault() external view returns (address);
    function shareToken() external view returns (address);
}
