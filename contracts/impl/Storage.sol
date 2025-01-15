// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.2;
pragma abicoder v2;


import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Types} from "../lib/Types.sol";
import {ISolidlyRouter} from "../interfaces/moonwell/ISolidlyRouter.sol";
import {IMoonwellFlagship} from "../interfaces/moonwell/IMoonwellFlagship.sol";
import {IUniversalRewardsDistributor} from "../interfaces/moonwell/IUniversalRewardsDistributor.sol";

/**
 * @title LS1Storage
 * @author Baklava Space
 *
 * @dev Storage contract. Contains or inherits from all contract with storage.
 */
abstract contract Storage {
    // ============ Rewards Accounting ============

    /// @dev The fee treasury contract address.
    address public feeTreasury;

    /// @dev The reward distributor contract address.
    address public distributor;

    /// @dev The cumulative rewards earned per staked token.
    uint256 public cumulativeRewardPerToken;

    /// @dev The user's rewards info
    mapping(address => Types.UserInfo) public userInfo;
    

    // ============ Staking Strategy setting ============
    
    /// @dev The staking farm contract 
    IMoonwellFlagship public stakingContract;

    /// @dev The swap router
    ISolidlyRouter public router;

    /// @dev The staking farm reward token.
    IERC20 public poolRewardToken;

    /// @dev The staking farm pool's bonus reward token.
    address[] public bonusRewardTokens;

    /// @dev The staking farm poolId
    // uint256 public stakingFarmID;

    /// @dev The minimum reward tokens to reinvest.
    uint256 public minTokensToReinvest;

    /// @dev Indicates whether a deposit is restricted.
    bool public depositsEnabled;

    /// @dev Indicates whether a restaking to farm is restricted. Deprecated
    // bool public restakingEnabled;


    // ============ Fee setting ============

    /// @dev The protocol fee for rewards.
    uint256 internal feeOnReward;

    /// @dev The compounder fee for rewards.
    uint256 internal feeOnCompounder;

    /// @dev The withdrawal fee for rewards.
    uint256 internal feeOnWithdrawal;

    // ============ Compound Strategy setting ============

    ISolidlyRouter.Route[] public outputToNativeRoute;

    ISolidlyRouter.Route[] public outputToLpRoute;

    // Should be bonusToNativeRoutes;
    mapping(address => ISolidlyRouter.Route[]) public bonusToLpRoutes;

    // ISolidlyRouter.Route[] public outputToLp1Route;

    // bool public stable;
    address public swapper;
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[48] private __gap;
}