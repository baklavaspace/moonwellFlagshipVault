// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMoonwellFlagship} from "../interfaces/moonwell/IMoonwellFlagship.sol";
import {ISolidlyRouter} from "../interfaces/moonwell/ISolidlyRouter.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {IRewardDistributor} from "../interfaces/IRewardDistributor.sol";
import {IUniversalRewardsDistributor} from "../interfaces/moonwell/IUniversalRewardsDistributor.sol";

import {Types} from '../lib/Types.sol';
import {BaseVault} from "../vaults/BaseVault.sol";

// MoonwellFlagshipStrategyVault is the compoundVault of Moonwell flagship vault. It will autocompound user deposit tokens.
// Note that it's ownable and the owner wields tremendous power.

contract MoonwellFlagshipStrategyVault is
    Initializable,
    UUPSUpgradeable,
    BaseVault
{
    using SafeERC20 for IERC20;

    // ============ Constants ============
    
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    uint256 internal constant PRECISION = 1e30;

    // ============ Events ==============

    event Claim(address indexed account, uint256 tokenAmount);
    event ClaimReinvestReward(address indexed reward, uint256 claimable);
    event EmergencyWithdraw(address indexed owner, uint256 assets, uint256 shares);
    event EmergencyWithdrawVault(address indexed owner, bool disableDeposits);
    event DepositsEnabled(bool newValue);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /********************************* INITIAL SETUP *********************************/
    /**
     * @dev Init the vault.
     */
    function initVault(
        address _stakingContract,
        address _poolRewardToken,
        address _router,
        address _feeTreasury,
        address _distributor,
        ISolidlyRouter.Route[] calldata _outputToNativeRoute,
        ISolidlyRouter.Route[] calldata _outputToLpRoute
    ) external onlyRole(OWNER_ROLE) {
        require(_stakingContract != address(0), "MSV:0 Add");

        stakingContract = IMoonwellFlagship(_stakingContract);
        poolRewardToken = IERC20(_poolRewardToken);
        router = ISolidlyRouter(_router);
        feeTreasury = _feeTreasury;
        distributor = _distributor;

        for (uint i; i < _outputToNativeRoute.length; ++i) {
            outputToNativeRoute.push(_outputToNativeRoute[i]);
        }

        for (uint i; i < _outputToLpRoute.length; ++i) {
            outputToLpRoute.push(_outputToLpRoute[i]);
        }

        depositsEnabled = true;
    }

    /**
     * @dev Approve tokens for use in Strategy, Restricted to avoid griefing attacks
     */
    function approveAllowances(uint256 _amount) external onlyRole(GOVERNOR_ROLE) {
        if (address(router) != address(0)) {
            IERC20(WETH).approve(address(router), _amount);
            poolRewardToken.approve(address(router), _amount);

            uint256 rewardLength = bonusRewardTokens.length;
            uint256 i = 0;
            for (i; i < rewardLength; i++) {
                IERC20(bonusRewardTokens[i]).approve(address(router), _amount);
            }
        }
    }

    function approveSwapper(uint256 _amount) external onlyRole(GOVERNOR_ROLE) {
        if (swapper != address(0)) {
            IERC20(WETH).approve(swapper, _amount);
            poolRewardToken.approve(swapper, _amount);

            uint256 rewardLength = bonusRewardTokens.length;
            uint256 i = 0;
            for (i; i < rewardLength; i++) {
                IERC20(bonusRewardTokens[i]).approve(swapper, _amount);
            }
        }
    }

    /****************************************** FARMING CORE FUNCTION ******************************************/
    /**
     * @dev Deposit LP tokens to staking farm.
     */
    function deposit(uint256 _assets, address _receiver) public nonReentrant override returns (uint256) {
        require(depositsEnabled == true, "MSV:Deposit !enabled");
        require(_assets > 0, "MSV:#>0");
        address sender = _msgSender();

        _claim(sender, sender);

        uint256 _pool = totalAssets();
        IERC20(asset()).safeTransferFrom(sender, address(this), _assets);
        _depositTokens(_assets);
        uint256 _after = totalAssets();
        _assets = _after - _pool;       // Additional check for actual increase in asset balance

        uint256 shares = 0;
        if (totalSupply() == 0) {
            shares = _assets;
        } else {
            shares = (_assets * totalSupply()) / _pool;
        }

        _mint(sender, shares);
        emit Deposit(sender, sender, _assets, shares);

        // Check if any asset inside contract, stake all to 3rd party pool/vault
        uint256 balanceInPool = available();
        if(balanceInPool > 0) {
            _depositTokens(balanceInPool);
        }

        return shares;
    }

    /**
     * @dev Withdraw LP tokens from staking moonwell vault.
     * @param _shares receipt amount
     * @param _receiver receiver address(Not Used to prevent ui bug)
     * @param _owner owner address
     */
    function redeem(uint256 _shares, address _receiver, address _owner) public nonReentrant override returns (uint256) {
        address sender = _msgSender();
        _claim(sender, sender);
        uint256 _assets = previewRedeem(_shares);
        
        if (_assets > 0) {
            _withdrawTokens(_assets);
        }
        _withdraw(sender, sender, _owner, _assets, _shares);

        // Check if any asset inside contract, stake to 3rd party farm/vault
        uint256 remainingAmount = available();
        if(remainingAmount > 0) {
            _depositTokens(remainingAmount);
        }

        return _assets;
    }

    // EMERGENCY ONLY. Withdraw without caring about rewards.
    // This has the 25% fee withdrawals fees and user receipt record set to 0 to prevent abuse of thisfunction.
    function emergencyRedeem() external nonReentrant {
        address sender = _msgSender();
        Types.UserInfo storage user = userInfo[sender];
        uint256 userBRTAmount = balanceOf(sender);

        require(userBRTAmount > 0, "MSV:#>0");

        _updateRewards(sender);
        user.claimableReward = 0;

        // Reordered from Sushi function to prevent risk of reentrancy
        uint256 assets = _convertToAssets(userBRTAmount, Math.Rounding.Floor);
        assets -= (assets * 2500 / BIPS_DIVISOR);

        if (assets > 0) {
            _withdrawTokens(assets);
        }
        _withdraw(sender, sender, sender, assets, userBRTAmount);

        emit EmergencyWithdraw(sender, assets, userBRTAmount);
    }

    /**
     * @dev Compound the reward token back to vault. Restrict to governor role to prevent user attack vault.
     */
    function compound() external nonReentrant onlyRole(GOVERNOR_ROLE) {
        _compound();

        if (depositsEnabled == true) {
            uint256 balanceInPool = available();
            if(balanceInPool > 0) {
                _depositTokens(balanceInPool);
            }
        }
    }

    // Update reward variables of the given vault to be up-to-date.
    function claimReward(address receiver) external nonReentrant returns (uint256) {
        return _claim(_msgSender(), receiver);
    }

    function updateRewards() external nonReentrant {
        _updateRewards(address(0));
    }

    /**************************************** Internal FUNCTIONS ****************************************/
    // Deposit asset() token to 3rd party restaking farm
    function _depositTokens(uint256 amount) internal {
        IERC20(asset()).approve(address(stakingContract), amount);
        stakingContract.deposit(
            amount,
            address(this)
        );
    }

    // Withdraw LP token to 3rd party restaking farm
    function _withdrawTokens(uint256 amount) internal {
        stakingContract.withdraw(amount, address(this), address(this));
    }

    // Claim LP restaking reward from 3rd party restaking contract
    function _claimReinvestReward(address distributor, address reward, uint256 _claimable, bytes32[] calldata proof) private {
        IUniversalRewardsDistributor(distributor).claim(
            address(this), reward, _claimable, proof
        );
    }

    // Claim bonus reward from Baklava
    function _claim(address account, address receiver) private returns (uint256) {
        _updateRewards(account);
        Types.UserInfo storage user = userInfo[account];
        uint256 tokenAmount = user.claimableReward;
        user.claimableReward = 0;

        if (tokenAmount > 0) {
            IERC20(rewardToken()).safeTransfer(receiver, tokenAmount);
            emit Claim(account, tokenAmount);
        }

        return tokenAmount;
    }

    function _updateRewards(address account) private {
        uint256 blockReward = IRewardDistributor(distributor).distribute(address(this));

        uint256 supply = totalSupply();
        uint256 _cumulativeRewardPerToken = cumulativeRewardPerToken;
        if (supply > 0 && blockReward > 0) {
            _cumulativeRewardPerToken = _cumulativeRewardPerToken + (blockReward * (PRECISION) / (supply));
            cumulativeRewardPerToken = _cumulativeRewardPerToken;
        }

        // cumulativeRewardPerToken can only increase
        // so if cumulativeRewardPerToken is zero, it means there are no rewards yet
        if (_cumulativeRewardPerToken == 0) {
            return;
        }

        if (account != address(0)) {
            Types.UserInfo storage user = userInfo[account];
            uint256 stakedAmount = balanceOf(account);
            uint256 accountReward = stakedAmount * (_cumulativeRewardPerToken - (user.previousCumulatedRewardPerToken)) / (PRECISION);
            uint256 _claimableReward = user.claimableReward + (accountReward);

            user.claimableReward = _claimableReward;
            user.previousCumulatedRewardPerToken = _cumulativeRewardPerToken;
        }
    }

    /**************************************** VIEW FUNCTIONS ****************************************/
    function rewardToken() public view returns (address) {
        return IRewardDistributor(distributor).rewardToken();
    }

    // View function to see pending Bavas on frontend.
    function claimable(address account) public view returns (uint256) {
        Types.UserInfo memory user = userInfo[account];
        uint256 stakedAmount = balanceOf(account);
        if (stakedAmount == 0) {
            return user.claimableReward;
        }
        uint256 supply = totalSupply();
        uint256 pendingRewards = IRewardDistributor(distributor).pendingRewards(address(this)) * (PRECISION);
        uint256 nextCumulativeRewardPerToken = cumulativeRewardPerToken + (pendingRewards / (supply));
        return user.claimableReward + (
            stakedAmount * (nextCumulativeRewardPerToken - (user.previousCumulatedRewardPerToken)) / (PRECISION));
    }

    // View function to see pending 3rd party reward. Ignore bonus reward view to reduce code error due to 3rd party contract changes
    function checkReward() public pure returns (uint256) {
        return 0;
    }

    // View function to see pending 3rd party reward. Ignore bonus reward view to reduce code error due to 3rd party contract changes
    function getFeesInfo() public view returns (uint256, uint256, uint256) {
        return (feeOnReward, feeOnCompounder, feeOnWithdrawal);
    }

    /**************************************** ONLY OWNER FUNCTIONS ****************************************/

    // @dev Rescue any token function, just in case if any user not able to withdraw token from the smart contract.
    function rescueDeployedFunds(
        address token,
        uint256 amount,
        address _to
    ) external onlyRole(OWNER_ROLE) {
        require(_to != address(0), "MSV:0Addr");
        IERC20(token).safeTransfer(_to, amount);
    }

    // @dev Emergency withdraw all LP tokens from staking farm contract, set true if want to disable deposit
    function emergencyWithdrawVault(bool disableDeposits)
        external
        onlyRole(OWNER_ROLE)
    {
        uint256 depositAmount = balanceOfPool();
        if(depositAmount > 0) {
            stakingContract.redeem(depositAmount, address(this), address(this));
        }

        if (depositsEnabled == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
        emit EmergencyWithdrawVault(_msgSender(), disableDeposits);
    }

    // @dev Enable/disable deposits
    function updateDepositsEnabled(bool _depositEnable) public onlyRole(OWNER_ROLE) {
        require(depositsEnabled != _depositEnable, "MSV:!valid");
        depositsEnabled = _depositEnable;
        emit DepositsEnabled(_depositEnable);
    }

    /**************************************** ONLY AUTHORIZED FUNCTIONS ****************************************/

    function claimReinvestReward(address distributor, address reward, uint256 _claimable, bytes32[] calldata proof) public onlyRole(GOVERNOR_ROLE) {
        _claimReinvestReward(distributor, reward, _claimable, proof);
        emit ClaimReinvestReward(reward, _claimable);
    }

    function updateStakingGauge(address _stakingContract)
        public
        onlyRole(GOVERNOR_ROLE)
    {
        stakingContract = IMoonwellFlagship(_stakingContract);
    }

    function updateFeeBips(Types.StrategySettings memory _strategySettings)
        public
        onlyRole(GOVERNOR_ROLE)
    {
        minTokensToReinvest = _strategySettings.minTokensToReinvest;
        feeOnReward = _strategySettings.feeOnReward;
        feeOnCompounder = _strategySettings.feeOnCompounder;
        feeOnWithdrawal = _strategySettings.feeOnWithdrawal;
    }

    function updateFeeTreasury(address _feeTreasury)
        public
        onlyRole(GOVERNOR_ROLE)
    {
        feeTreasury = _feeTreasury;
    }
    
    function updateDistributor(address _distributor)
        public
        onlyRole(GOVERNOR_ROLE)
    {
        distributor = _distributor;
    }

    function updateSwapper(address _swapper)
        public
        onlyRole(GOVERNOR_ROLE)
    {
        swapper = _swapper;
    }

    function updateBonusReward(address _bonusRewardTokens, ISolidlyRouter.Route[] calldata _bonusToAssetRoute, bool _clearBonusToken)
        public
        onlyRole(GOVERNOR_ROLE)
    {
        if (_clearBonusToken == true) {
            delete bonusRewardTokens;
        }
        
        bonusRewardTokens.push(_bonusRewardTokens);
        
        delete bonusToLpRoutes[address(_bonusRewardTokens)];
        for (uint i; i < _bonusToAssetRoute.length; ++i) {
            bonusToLpRoutes[address(_bonusRewardTokens)].push(_bonusToAssetRoute[i]);
        }
    }

    function updateRoute(
        ISolidlyRouter.Route[] calldata _outputToNativeRoute,
        ISolidlyRouter.Route[] calldata _outputToLpRoute
    )
        public
        onlyRole(GOVERNOR_ROLE)
    {
        delete outputToNativeRoute;
        delete outputToLpRoute;

        for (uint i; i < _outputToNativeRoute.length; ++i) {
            outputToNativeRoute.push(_outputToNativeRoute[i]);
        }

        for (uint i; i < _outputToLpRoute.length; ++i) {
            outputToLpRoute.push(_outputToLpRoute[i]);
        }
    }


    /*********************** Compound Strategy ***************************************
     * Swap all reward tokens to WETH and swap WETH token to deposit(asset) token
     *********************************************************************************/

    function _compound() private returns (uint256) {
        uint256 swapWeth = _convertRewardIntoWETH();
        uint256 swapWeth2 = _convertBonusRewardIntoWETH();

        // uint256 wethAmount = IERC20(WETH).balanceOf(address(this));
        uint256 wethAmount = swapWeth + swapWeth2;
        uint256 protocolFee = (wethAmount * feeOnReward) / (BIPS_DIVISOR);
        uint256 reinvestFee = (wethAmount * feeOnCompounder) / (BIPS_DIVISOR);

        IERC20(WETH).safeTransfer(feeTreasury, protocolFee);
        IERC20(WETH).safeTransfer(_msgSender(), reinvestFee);
        uint256 liquidity = _convertWETHToDepositToken(wethAmount - reinvestFee - protocolFee);

        return liquidity;
    }

    function _convertRewardIntoWETH() private returns (uint256) {
        // Variable reward Super farm strategy
        uint256 rewardBal;
        uint256 swapWeth;

        if (address(poolRewardToken) != address(WETH)) {
            rewardBal = poolRewardToken.balanceOf(address(this));
            if (rewardBal > 0) {
                uint256 amountOut = ISwapper(swapper).getAmountsOut(address(poolRewardToken), WETH, rewardBal);
                swapWeth = ISwapper(swapper).swap(address(poolRewardToken), WETH, rewardBal, amountOut);
            }
        }
        return swapWeth;
    }

    // Need to upgrade contract to change bonus route
    function _convertBonusRewardIntoWETH() private returns (uint256) {
        uint256 rewardLength = bonusRewardTokens.length;
        uint256 swapWeth;

        // Variable reward Super farm strategy
        if (rewardLength > 0) {
            for (uint256 i; i < rewardLength; i++) {
                uint256 rewardBal = 0;

                if (address(bonusRewardTokens[i]) != address(WETH)) {
                    rewardBal = IERC20(bonusRewardTokens[i]).balanceOf(address(this));

                    if (rewardBal > 0) {
                        uint256 amountOut = ISwapper(swapper).getAmountsOut(bonusRewardTokens[i], WETH, rewardBal);
                        swapWeth += ISwapper(swapper).swap(bonusRewardTokens[i], WETH, rewardBal, amountOut);
                    }
                }
            }
        }
        return swapWeth;
    }

    function _convertWETHToDepositToken(uint256 amount)
        private
        returns (uint256)
    {
        require(amount > 0, "MSV:#<0");
        uint256 amountIn = amount;

        address assetToken0 = asset();
        uint256 amountOutToken;

        // swap to assetToken
        // Check if assetToken equal to WETH
        if (assetToken0 != (WETH)) {
            uint256 amountOut = ISwapper(swapper).getAmountsOut(WETH, assetToken0, amountIn);
            amountOutToken = ISwapper(swapper).swap(WETH, assetToken0, amountIn, amountOut);
        }

        return amountOutToken;
    }

    function _convertExactTokentoToken(ISolidlyRouter.Route[] memory route, uint256 amount)
        private
        returns (uint256)
    {
        uint256[] memory amountsOutToken = router.getAmountsOut(amount, route);
        uint256 amountOutToken = amountsOutToken[amountsOutToken.length - 1];
        uint256[] memory amountOut = router.swapExactTokensForTokens(amount, amountOutToken, route, address(this), block.timestamp + 1200);

        uint256 swapAmount = amountOut[amountOut.length - 1];

        return swapAmount;
    }

    /*********************** Openzeppelin inherited functions *********************************/
    // The following functions are overrides required by Solidity.
    function _update(address from, address to, uint256 value)
        internal
        virtual
        override
    {
        _updateRewards(from);
        _updateRewards(to);
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address) internal override onlyRole(OWNER_ROLE) {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     * @param symbol: BRT2LPSYMBOL
     *************************************************************/
    function initialize(
        address _asset,
        address _owner,
        address _governor,
        string memory name_,
        string memory symbol_
    ) public initializer {
        __BaseVaultInit(
            _asset,
            name_,
            symbol_,
            _owner,
            _governor
        );
        __UUPSUpgradeable_init();
    }
}