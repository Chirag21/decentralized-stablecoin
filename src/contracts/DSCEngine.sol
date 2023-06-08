// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IDSCEngine} from "./interfaces/IDSCEngine.sol";
import {DecentralizedStablecoin} from "./DecentralizedStablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Chirag
 * Simple and minimal system for stablecoin, tha helps tokens maintain 1 tpekn == 1 USD peg.
 * The stablecoin has properties :
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * DSC system should always be overcollaterized. At no point, should the value of all collateral <= the value of all DSC($ backed)
 *
 * It is similar to DAI without Governance, fees and only backed by WETH and WBTC.
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC and depositing and withdrawing of collateral.
 * @notice Loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard, IDSCEngine {
    error DSCEngine_MustBeMoreThanZero();
    error DSCEngine_TokenNotAllowed();
    error DSCEngine_TokenAndPriceFeedsLengthMustBeSame();
    error DSCEngine_TransferFailed();
    error DSCEngine_BreaksHealthFactor(uint256 brokenHealthFactor);
    error DSCEngine_MintFailed();

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // need to be 200% overcollaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MINIMUM_HEALTH_FACTOR = 1;

    DecentralizedStablecoin private immutable dsc;
    mapping(address token => address priceFeed) private priceFeeds; // rename to tokenToPriceFeeds
    mapping(address user => mapping(address token => uint256 amount)) private collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private dscMinted;
    address[] private collateralTokens;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert DSCEngine_MustBeMoreThanZero();
        _;
    }

    modifier isAllowedToken(address token) {
        if (priceFeeds[token] == address(0)) revert DSCEngine_TokenNotAllowed();
        _;
    }

    /**
     *
     * @param tokenAddresses Token addresses than can be used as collateral
     * @param priceFeedAddresses Token/USD price feed addresses
     * @param dscAddress DSC token address
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        uint256 tokenArrayLength = tokenAddresses.length;
        if (tokenArrayLength != priceFeedAddresses.length) {
            revert DSCEngine_TokenAndPriceFeedsLengthMustBeSame();
        }

        for (uint256 i; i < tokenArrayLength;) {
            priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            collateralTokens.push(tokenAddresses[i]);
            unchecked {
                i = i + 1;
            }
        }

        dsc = DecentralizedStablecoin(dscAddress);
    }

    /**
     *  @notice follows CEI pattern
     * @param collateralTokenAddress The address of the token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit
     */
    function depositCollateral(address collateralTokenAddress, uint256 collateralAmount)
        external
        moreThanZero(collateralAmount)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
    {
        collateralDeposited[msg.sender][collateralTokenAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);
        bool success = IERC20(dsc).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) revert DSCEngine_TransferFailed();
    }

    function depositCollateralAndMintDsc() external override {}

    function redeemCollateralForDsc() external override {}

    function redeemCollateral() external override {}

    /**
     * @notice follows CEI pattern
     * @notice must have more collateral value than the minimum threshold
     * @param amountToMint The amount of DSC to mint
     */
    function mintDsc(uint256 amountToMint) external moreThanZero(amountToMint) nonReentrant {
        dscMinted[msg.sender] += amountToMint;

        // revert if user minted too much DSC
        _revertIfHealthFactorIsBroken(msg.sender);

        try dsc.mint(msg.sender, amountToMint) {}
        catch {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc() external override {}

    function liquidate() external override {}

    function getHealthFactor() external override {}

    function mintDsc() external override {}

    /**
     *
     * @param user address of the user trying to mint DSC
     * @return healthFactor returns how close the user is to liquidation
     */
    function _healthFactor(address user) private view returns (uint256 healthFactor) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInfo(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;

        // 1000 ETH * 50 = 50,000 /100 = 500
        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _getAccountInfo(address user)
        private
        view
        returns (uint256 totalDscMInted, uint256 collateralValueInUsd)
    {
        uint256 accountCollateralValueInUsd = getAccountCollateralValueInUsd(user);
        return (dscMinted[user], accountCollateralValueInUsd);
    }

    // does the user have enough collateral
    // revert if health factor is below 1
    function _revertIfHealthFactorIsBroken(address user) private view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MINIMUM_HEALTH_FACTOR) revert DSCEngine_BreaksHealthFactor(userHealthFactor);
    }

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 collateralValueInUsd) {
        uint256 collateralTokensLength = collateralTokens.length;

        // loop through each token, get the amount deposited and calculate the equivalent
        // USD value using Chainlink datafeeds
        for (uint256 i; i < collateralTokensLength;) {
            address token = collateralTokens[i];
            uint256 amountOfTokensDeposited = collateralDeposited[user][token];
            collateralValueInUsd += getValueInUsd(token, amountOfTokensDeposited);
            unchecked {
                i = i + 1;
            }
        }
        return collateralValueInUsd;
    }

    function getValueInUsd(address token, uint256 amount) public view returns (uint256 valueInUsd) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeeds[token]);
        (
            /* uint80 roundID */
            ,
            int256 answer,
            /*uint startedAt*/
            ,
            /*uint timeStamp*/
            ,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();

        // Both ETH and BTC price feed return data with 8 decimals
        // Convert to same precision by multiplying by 1e10
        // convert answer from int to uint
        return ((uint256(answer) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000 * 1e10) / 1e18
    }
}
