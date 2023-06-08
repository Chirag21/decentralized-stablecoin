// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IDSCEngine {
    function depositCollateralAndMintDsc() external;

    /**
     *
     * @param collateralTOkenAddress The address of the token to deposit as collateral
     * @param amount The amount of collateral to deposit
     */
    function depositCollateral(address collateralTOkenAddress, uint256 amount) external;

    function redeemCollateralForDsc() external;

    function redeemCollateral() external;

    function mintDsc() external;

    function burnDsc() external;

    function liquidate() external;

    function getHealthFactor() external;
}
