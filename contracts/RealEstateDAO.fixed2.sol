// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import "./FractionTokenLite.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Governor } from "@openzeppelin/contracts/governance/Governor.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { GovernorCountingSimple } from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import { GovernorVotes } from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import { GovernorVotesQuorumFraction } from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import { GovernorTimelockControl } from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

interface IFractionTokenLite {
  function setDistributor(address distributor) external;
  function setWhitelist(address account, bool allowed) external;

  function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
  function PAUSER_ROLE() external view returns (bytes32);
  function WHITELIST_ADMIN_ROLE() external view returns (bytes32);

  function grantRole(bytes32 role, address account) external;
  function revokeRole(bytes32 role, address account) external;
}



interface IRentDistributorHook {
  function onTokenTransfer(address from, address to, uint256 amount) external;
}

interface IRentAccounting {
  function totalDividendsAccrued() external view returns (uint256);
  function totalDividendsClaimed() external view returns (uint256);
}

interface IRentAccountingFull is IRentAccounting {
  function pendingUndistributed() external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
                        FRACTION TOKEN
//////////////////////////////////////////////////////////////*/
contract FractionToken is ERC20, ERC20Permit, ERC20Votes, AccessControl, Pausable {
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

  bool public transfersRestricted;
  mapping(address => bool) public isWhitelisted;

  address public distributor;

  error DistributorAlreadySet();
  error TransfersRestricted();
  error ZeroAddress();

  event DistributorSet(address indexed distributor);
  event TransfersRestrictionSet(bool restricted);
  event WhitelistSet(address indexed account, bool allowed);

  constructor(
    string memory name_,
    string memory symbol_,
    address admin_,
    address initialHolder_,
    uint256 initialSupply_
  ) ERC20(name_, symbol_) ERC20Permit(name_) {
    if (admin_ == address(0) || initialHolder_ == address(0)) revert ZeroAddress();

    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    _grantRole(PAUSER_ROLE, admin_);
    _grantRole(WHITELIST_ADMIN_ROLE, admin_);

    transfersRestricted = false;

    isWhitelisted[admin_] = true;
    isWhitelisted[initialHolder_] = true;

    _mint(initialHolder_, initialSupply_);
  }

  function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
  function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

  function setTransfersRestricted(bool restricted) external onlyRole(WHITELIST_ADMIN_ROLE) {
    transfersRestricted = restricted;
    emit TransfersRestrictionSet(restricted);
  }

  function setWhitelist(address account, bool allowed) external onlyRole(WHITELIST_ADMIN_ROLE) {
    if (account == address(0)) revert ZeroAddress();
    isWhitelisted[account] = allowed;
    emit WhitelistSet(account, allowed);
  }

  function setDistributor(address distributor_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (distributor_ == address(0)) revert ZeroAddress();
    if (distributor != address(0)) revert DistributorAlreadySet();
    distributor = distributor_;
    emit DistributorSet(distributor_);
  }

  function _update(address from, address to, uint256 value)
    internal
    override(ERC20, ERC20Votes)
    whenNotPaused
  {
    if (transfersRestricted) {
      if (from == address(0)) {
        if (!isWhitelisted[to]) revert TransfersRestricted();
      } else if (to == address(0)) {
        if (!isWhitelisted[from]) revert TransfersRestricted();
      } else {
        if (!isWhitelisted[from] || !isWhitelisted[to]) revert TransfersRestricted();
      }
    }

    super._update(from, to, value);

    if (distributor != address(0)) {
      IRentDistributorHook(distributor).onTokenTransfer(from, to, value);
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

/*//////////////////////////////////////////////////////////////
                          PROPERTY VAULT (ETH)
//////////////////////////////////////////////////////////////*/
contract PropertyVault is AccessControl, Pausable, ReentrancyGuard {
  bytes32 public constant PROPERTY_MANAGER_ROLE = keccak256("PROPERTY_MANAGER_ROLE");
  bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");

  address public distributor;
  uint16 public reserveBps;

  error DistributorAlreadySet();
  error ZeroAddress();
  error InvalidBps();
  error InsufficientUnencumberedBalance();
  error EthTransferFailed();

  event DistributorSet(address indexed distributor);
  event ReserveBpsSet(uint16 bps);
  event IncomeDeposited(address indexed from, uint256 amount, uint256 reserved, uint256 distributed);
  event GovernancePayment(address indexed to, uint256 amount, string memo);
  event DividendPaid(address indexed to, uint256 amount);

  constructor(address admin_, address propertyManager_) {
    if (admin_ == address(0) || propertyManager_ == address(0)) revert ZeroAddress();

    _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    _grantRole(PROPERTY_MANAGER_ROLE, propertyManager_);
    _grantRole(GOVERNANCE_ROLE, admin_);

    reserveBps = 0;
  }

  function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
  function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

  function setDistributor(address distributor_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (distributor_ == address(0)) revert ZeroAddress();
    if (distributor != address(0)) revert DistributorAlreadySet();
    distributor = distributor_;
    emit DistributorSet(distributor_);
  }

  function setReserveBps(uint16 bps) external onlyRole(GOVERNANCE_ROLE) {
    if (bps > 10_000) revert InvalidBps();
    reserveBps = bps;
    emit ReserveBpsSet(bps);
  }

  function depositIncome() external payable onlyRole(PROPERTY_MANAGER_ROLE) whenNotPaused nonReentrant {
    require(distributor != address(0), "Distributor not set");
    uint256 amount = msg.value;
    require(amount > 0, "amount=0");

    uint256 reserved = Math.mulDiv(amount, reserveBps, 10_000);
    uint256 distributed = amount - reserved;
    RentDistributor(distributor).notifyRent(distributed);

    emit IncomeDeposited(msg.sender, amount, reserved, distributed);
  }

  function payDividend(address payable to, uint256 amount) external whenNotPaused nonReentrant {
    require(msg.sender == distributor, "only distributor");
    if (amount == 0) return;

    (bool ok, ) = to.call{value: amount}("");
    if (!ok) revert EthTransferFailed();

    emit DividendPaid(to, amount);
  }

  function executeGovernancePayment(address payable to, uint256 amount, string calldata memo)
    external
    onlyRole(GOVERNANCE_ROLE)
    whenNotPaused
    nonReentrant
  {
    if (to == address(0)) revert ZeroAddress();
    require(distributor != address(0), "Distributor not set");
    require(amount > 0, "amount=0");

    uint256 balance = address(this).balance;

    uint256 accrued = IRentAccounting(distributor).totalDividendsAccrued();
    uint256 claimed = IRentAccounting(distributor).totalDividendsClaimed();
    uint256 pending = IRentAccountingFull(distributor).pendingUndistributed();
    uint256 owed = (accrued + pending) - claimed;

    if (balance < owed) revert InsufficientUnencumberedBalance();
    uint256 available = balance - owed;

    if (amount > available) revert InsufficientUnencumberedBalance();

    (bool ok, ) = to.call{value: amount}("");
    if (!ok) revert EthTransferFailed();

    emit GovernancePayment(to, amount, memo);
  }
}

/*//////////////////////////////////////////////////////////////
                        RENT DISTRIBUTOR (ETH)
//////////////////////////////////////////////////////////////*/
contract RentDistributor is IRentDistributorHook, IRentAccounting, ReentrancyGuard {
  using SafeCast for int256;
  uint256 private constant MAGNIFICATION = 2 ** 128;

  FractionToken public immutable sharesToken;
  PropertyVault public immutable vault;

  uint256 public magnifiedDividendPerShare;
  mapping(address => int256) public magnifiedDividendCorrections;
  mapping(address => uint256) public withdrawnDividends;

  uint256 public pendingUndistributed;
  uint256 public override totalDividendsAccrued;
  uint256 public override totalDividendsClaimed;

  error OnlyVault();
  error OnlySharesToken();

  event RentNotified(uint256 amountDistributed, uint256 newMagnifiedDividendPerShare);
  event DividendClaimed(address indexed account, uint256 amount);

  constructor(address sharesToken_, address vault_) {
    require(sharesToken_ != address(0) && vault_ != address(0), "zero");
    sharesToken = FractionToken(sharesToken_);
    vault = PropertyVault(vault_);
  }

  modifier onlyVault() {
    if (msg.sender != address(vault)) revert OnlyVault();
    _;
  }

  modifier onlySharesToken() {
    if (msg.sender != address(sharesToken)) revert OnlySharesToken();
    _;
  }

  function notifyRent(uint256 amount) external onlyVault {
    if (amount == 0) return;

    uint256 supply = sharesToken.totalSupply();
    if (supply == 0) {
      pendingUndistributed += amount;
      return;
    }

    uint256 distributable = amount + pendingUndistributed;
    pendingUndistributed = 0;

    magnifiedDividendPerShare += (distributable * MAGNIFICATION) / supply;
    totalDividendsAccrued += distributable;

    emit RentNotified(distributable, magnifiedDividendPerShare);
  }

  function onTokenTransfer(address from, address to, uint256 amount) external onlySharesToken {
    if (amount == 0) return;
    int256 magCorrection = SafeCast.toInt256(magnifiedDividendPerShare * amount);

    if (from == address(0)) {
      magnifiedDividendCorrections[to] -= magCorrection;
    } else if (to == address(0)) {
      magnifiedDividendCorrections[from] += magCorrection;
    } else {
      magnifiedDividendCorrections[from] += magCorrection;
      magnifiedDividendCorrections[to] -= magCorrection;
    }
  }

  function withdrawableDividendOf(address account) public view returns (uint256) {
    uint256 accumulative = accumulativeDividendOf(account);
    uint256 alreadyWithdrawn = withdrawnDividends[account];
    if (accumulative <= alreadyWithdrawn) return 0;
    return accumulative - alreadyWithdrawn;
  }

  function accumulativeDividendOf(address account) public view returns (uint256) {
    uint256 bal = sharesToken.balanceOf(account);
    int256 magnified = SafeCast.toInt256(magnifiedDividendPerShare * bal);
    int256 corrected = magnified + magnifiedDividendCorrections[account];

    if (corrected <= 0) return 0;
    return uint256(corrected) / MAGNIFICATION;
  }

  function claim() external nonReentrant {
    uint256 withdrawable = withdrawableDividendOf(msg.sender);
    if (withdrawable == 0) return;

    withdrawnDividends[msg.sender] += withdrawable;
    totalDividendsClaimed += withdrawable;

    vault.payDividend(payable(msg.sender), withdrawable);

    emit DividendClaimed(msg.sender, withdrawable);
  }
}

/*//////////////////////////////////////////////////////////////
                      PROPERTY GOVERNOR
//////////////////////////////////////////////////////////////*/
contract PropertyGovernor is
  Governor,
  GovernorSettings,
  GovernorCountingSimple,
  GovernorVotes,
  GovernorVotesQuorumFraction,
  GovernorTimelockControl
{
  constructor(
    IVotes token_,
    TimelockController timelock_,
    uint48 votingDelayBlocks_,
    uint32 votingPeriodBlocks_,
    uint256 proposalThresholdTokens_,
    uint256 quorumPercent_
  )
    Governor("PropertyGovernor")
    GovernorSettings(votingDelayBlocks_, votingPeriodBlocks_, proposalThresholdTokens_)
    GovernorVotes(token_)
    GovernorVotesQuorumFraction(quorumPercent_)
    GovernorTimelockControl(timelock_)
  {}

  function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
    return super.votingDelay();
  }

  function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
    return super.votingPeriod();
  }

  function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
    return super.proposalThreshold();
  }

  function state(uint256 proposalId)
    public
    view
    override(Governor, GovernorTimelockControl)
    returns (ProposalState)
  {
    return super.state(proposalId);
  }

  function proposalNeedsQueuing(uint256 proposalId)
    public
    view
    override(Governor, GovernorTimelockControl)
    returns (bool)
  {
    return super.proposalNeedsQueuing(proposalId);
  }

  function _queueOperations(
    uint256 proposalId,
    address[] memory targets,
    uint256[] memory values,
    bytes[] memory calldatas,
    bytes32 descriptionHash
  )
    internal
    override(Governor, GovernorTimelockControl)
    returns (uint48)
  {
    return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
  }

  function _executeOperations(
    uint256 proposalId,
    address[] memory targets,
    uint256[] memory values,
    bytes[] memory calldatas,
    bytes32 descriptionHash
  )
    internal
    override(Governor, GovernorTimelockControl)
  {
    super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
  }

  function _cancel(
    address[] memory targets,
    uint256[] memory values,
    bytes[] memory calldatas,
    bytes32 descriptionHash
  )
    internal
    override(Governor, GovernorTimelockControl)
    returns (uint256)
  {
    return super._cancel(targets, values, calldatas, descriptionHash);
  }

  function _executor()
    internal
    view
    override(Governor, GovernorTimelockControl)
    returns (address)
  {
    return super._executor();
  }
}

/*//////////////////////////////////////////////////////////////
                       REAL ESTATE DAO (Factory)
//////////////////////////////////////////////////////////////*/
contract RealEstateDAO {
  struct CreatePropertyArgs {
    string name;
    string symbol;
    address admin;
    address initialHolder;
    uint256 initialSupply;
    address propertyManager;
    uint16 reserveBps;
    uint256 timelockDelaySeconds;
    uint48 votingDelayBlocks;
    uint32 votingPeriodBlocks;
    uint256 proposalThresholdTokens;
    uint256 quorumPercent;
  }

  struct CreatePropertyLiteArgs {
    string name;
    string symbol;
    address admin;
    address initialHolder;
    uint256 initialSupply;
    address propertyManager;
    uint16 reserveBps;
  }


  event PropertyCreated(
    address indexed token,
    address indexed vault,
    address indexed distributor,
    address timelock,
    address governor
  );

  // تم التصحيح: يجب تحديد الحجم عند إنشاء مصفوفة في الذاكرة
  function _emptyAddressArray() internal pure returns (address[] memory) {
    return new address[](0); // Correct: array of size 0
  }

  function _anyoneExecutors() internal pure returns (address[] memory arr) {
    arr = new address[](1); // Correct: array of size 1
    arr[0] = address(0);
  }

  function createProperty(CreatePropertyArgs calldata a)
    external
    returns (address token, address vault, address distributor, address timelock, address governor)
  {
    return _createProperty(a);
  }


  function _createProperty(CreatePropertyArgs memory a)
    internal
    returns (address token, address vault, address distributor, address timelock, address governor)
  {
    require(
      a.admin != address(0) &&
      a.initialHolder != address(0) &&
      a.propertyManager != address(0),
      "zero"
    );

    FractionToken t = new FractionToken(a.name, a.symbol, address(this), a.initialHolder, a.initialSupply);
    PropertyVault v = new PropertyVault(address(this), a.propertyManager);
    RentDistributor d = new RentDistributor(address(t), address(v));

    t.setDistributor(address(d));
    v.setDistributor(address(d));

    t.setWhitelist(a.admin, true);
    v.setReserveBps(a.reserveBps);

    TimelockController tl = new TimelockController(
      a.timelockDelaySeconds,
      _emptyAddressArray(),
      _anyoneExecutors(),
      address(this)
    );

    PropertyGovernor g = new PropertyGovernor(
      IVotes(address(t)),
      tl,
      a.votingDelayBlocks,
      a.votingPeriodBlocks,
      a.proposalThresholdTokens,
      a.quorumPercent
    );

    tl.grantRole(tl.PROPOSER_ROLE(), address(g));
    tl.grantRole(tl.CANCELLER_ROLE(), a.admin);

    tl.grantRole(tl.DEFAULT_ADMIN_ROLE(), a.admin);
    tl.revokeRole(tl.DEFAULT_ADMIN_ROLE(), address(this));

    v.grantRole(v.GOVERNANCE_ROLE(), address(tl));
    v.revokeRole(v.GOVERNANCE_ROLE(), address(this));

    t.grantRole(t.DEFAULT_ADMIN_ROLE(), a.admin);
    t.grantRole(t.PAUSER_ROLE(), a.admin);
    t.grantRole(t.WHITELIST_ADMIN_ROLE(), a.admin);

    t.revokeRole(t.PAUSER_ROLE(), address(this));
    t.revokeRole(t.WHITELIST_ADMIN_ROLE(), address(this));
    t.revokeRole(t.DEFAULT_ADMIN_ROLE(), address(this));

    v.grantRole(v.DEFAULT_ADMIN_ROLE(), a.admin);
    v.revokeRole(v.DEFAULT_ADMIN_ROLE(), address(this));

    emit PropertyCreated(address(t), address(v), address(d), address(tl), address(g));

    return (address(t), address(v), address(d), address(tl), address(g));
  }

  function createPropertyLite(CreatePropertyLiteArgs calldata a)
    external
    returns (address token, address vault, address distributor)
  {
    return _createPropertyLite(a);
  }


  function _createPropertyLite(CreatePropertyLiteArgs memory a)
    internal
    returns (address token, address vault, address distributor)
  {
    require(
      a.admin != address(0) &&
      a.initialHolder != address(0) &&
      a.propertyManager != address(0),
      "zero"
    );

    FractionToken t = new FractionToken(a.name, a.symbol, address(this), a.initialHolder, a.initialSupply);
    PropertyVault v = new PropertyVault(address(this), a.propertyManager);
    RentDistributor d = new RentDistributor(address(t), address(v));

    t.setDistributor(address(d));
    v.setDistributor(address(d));

    t.setWhitelist(a.admin, true);
    v.setReserveBps(a.reserveBps);

    // Governance handled by admin directly (no timelock/governor)
    v.grantRole(v.GOVERNANCE_ROLE(), a.admin);
    v.revokeRole(v.GOVERNANCE_ROLE(), address(this));

    t.grantRole(t.DEFAULT_ADMIN_ROLE(), a.admin);
    t.grantRole(t.PAUSER_ROLE(), a.admin);
    t.grantRole(t.WHITELIST_ADMIN_ROLE(), a.admin);

    t.revokeRole(t.PAUSER_ROLE(), address(this));
    t.revokeRole(t.WHITELIST_ADMIN_ROLE(), address(this));
    t.revokeRole(t.DEFAULT_ADMIN_ROLE(), address(this));

    v.grantRole(v.DEFAULT_ADMIN_ROLE(), a.admin);
    v.revokeRole(v.DEFAULT_ADMIN_ROLE(), address(this));

    emit PropertyCreated(address(t), address(v), address(d), address(0), address(0));

    return (address(t), address(v), address(d));
  }


  /// @notice Finalize a "lite" property after deploying the child contracts (token/vault/distributor)
  ///         with `admin_ = address(this)` (the DAO) so the DAO can wire roles and settings.
  /// @dev This avoids deploying 3 contracts inside one tx, which can hit gas / initcode limits on dev chains.
  function finalizePropertyLite(
    address token,
    address vault,
    address distributor,
    address admin,
    uint16 reserveBps
  ) external returns (address tokenOut, address vaultOut, address distributorOut) {
    require(msg.sender == admin, "only admin");
    require(token != address(0) && vault != address(0) && distributor != address(0) && admin != address(0), "zero addr");

    IFractionTokenLite t = IFractionTokenLite(token);
    PropertyVault v = PropertyVault(vault);

    // Wire distributor
    t.setDistributor(distributor);
    v.setDistributor(distributor);

    // Allow admin to receive/transfer even when transfers are restricted
    t.setWhitelist(admin, true);

    // Reserve / governance
    v.setReserveBps(reserveBps);

    // Hand over vault governance to the admin
    v.grantRole(v.GOVERNANCE_ROLE(), admin);
    v.revokeRole(v.GOVERNANCE_ROLE(), address(this));

    // Hand over token admin roles to the admin
    t.grantRole(t.DEFAULT_ADMIN_ROLE(), admin);
    t.grantRole(t.PAUSER_ROLE(), admin);
    t.grantRole(t.WHITELIST_ADMIN_ROLE(), admin);

    // Optional: drop DAO roles on the token
    t.revokeRole(t.PAUSER_ROLE(), address(this));
    t.revokeRole(t.WHITELIST_ADMIN_ROLE(), address(this));
    t.revokeRole(t.DEFAULT_ADMIN_ROLE(), address(this));

    emit PropertyCreated(token, vault, distributor, address(0), address(0));
    return (token, vault, distributor);
  }


}