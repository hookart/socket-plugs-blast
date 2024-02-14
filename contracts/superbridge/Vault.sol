pragma solidity 0.8.13;

import "solmate/utils/SafeTransferLib.sol";
import "../common/Ownable.sol";
import {Gauge} from "../common/Gauge.sol";
import {IConnector, IHub} from "./ConnectorPlug.sol";
import {RescueFundsLib} from "../libraries/RescueFundsLib.sol";
import {IERC20Rebasing} from "../interfaces/IERC20Rebasing.sol";

struct SubstantialYieldRecipient {
    address recipient;
    uint256 shares;
}

// @todo: separate our connecter plugs
contract Vault is Gauge, IHub, Ownable(msg.sender) {
    using SafeTransferLib for ERC20;
    ERC20 public immutable token__;

    struct UpdateLimitParams {
        bool isLock;
        address connector;
        uint256 maxLimit;
        uint256 ratePerSecond;
    }

    // connector => receiver => pendingUnlock
    mapping(address => mapping(address => uint256)) public pendingUnlocks;

    // connector => amount
    mapping(address => uint256) public connectorPendingUnlocks;

    // connector => lockLimitParams
    mapping(address => LimitParams) _lockLimitParams;

    // connector => unlockLimitParams
    mapping(address => LimitParams) _unlockLimitParams;

    error ConnectorUnavailable();
    error ZeroAmount();

    event LimitParamsUpdated(UpdateLimitParams[] updates);
    event TokensDeposited(
        address connector,
        address depositor,
        address receiver,
        uint256 depositAmount
    );
    event PendingTokensTransferred(
        address connector,
        address receiver,
        uint256 unlockedAmount,
        uint256 pendingAmount
    );
    event TokensPending(
        address connector,
        address receiver,
        uint256 pendingAmount,
        uint256 totalPendingAmount
    );
    event TokensUnlocked(
        address connector,
        address receiver,
        uint256 unlockedAmount
    );
    event PacmanDesignated(address pacman);

    constructor(address token_) {
        token__ = ERC20(token_);
    }

    function updateLimitParams(
        UpdateLimitParams[] calldata updates_
    ) external onlyOwner {
        for (uint256 i; i < updates_.length; i++) {
            if (updates_[i].isLock) {
                _consumePartLimit(0, _lockLimitParams[updates_[i].connector]); // to keep current limit in sync
                _lockLimitParams[updates_[i].connector].maxLimit = updates_[i]
                    .maxLimit;
                _lockLimitParams[updates_[i].connector]
                    .ratePerSecond = updates_[i].ratePerSecond;
            } else {
                _consumePartLimit(0, _unlockLimitParams[updates_[i].connector]); // to keep current limit in sync
                _unlockLimitParams[updates_[i].connector].maxLimit = updates_[i]
                    .maxLimit;
                _unlockLimitParams[updates_[i].connector]
                    .ratePerSecond = updates_[i].ratePerSecond;
            }
        }

        emit LimitParamsUpdated(updates_);
    }

    function depositToAppChain(
        address receiver_,
        uint256 amount_,
        uint256 msgGasLimit_,
        address connector_
    ) external payable {
        if (amount_ == 0) revert ZeroAmount();

        if (_lockLimitParams[connector_].maxLimit == 0)
            revert ConnectorUnavailable();

        _consumeFullLimit(amount_, _lockLimitParams[connector_]); // reverts on limit hit

        token__.safeTransferFrom(msg.sender, address(this), amount_);

        IConnector(connector_).outbound{value: msg.value}(
            msgGasLimit_,
            abi.encode(receiver_, amount_)
        );

        emit TokensDeposited(connector_, msg.sender, receiver_, amount_);
    }

    function unlockPendingFor(address receiver_, address connector_) external {
        if (_unlockLimitParams[connector_].maxLimit == 0)
            revert ConnectorUnavailable();

        uint256 pendingUnlock = pendingUnlocks[connector_][receiver_];
        (uint256 consumedAmount, uint256 pendingAmount) = _consumePartLimit(
            pendingUnlock,
            _unlockLimitParams[connector_]
        );

        pendingUnlocks[connector_][receiver_] = pendingAmount;
        connectorPendingUnlocks[connector_] -= consumedAmount;

        token__.safeTransfer(receiver_, consumedAmount);

        emit PendingTokensTransferred(
            connector_,
            receiver_,
            consumedAmount,
            pendingAmount
        );
    }

    // receive inbound assuming connector called
    function receiveInbound(bytes memory payload_) external override {
        if (_unlockLimitParams[msg.sender].maxLimit == 0)
            revert ConnectorUnavailable();

        (address receiver, uint256 unlockAmount) = abi.decode(
            payload_,
            (address, uint256)
        );

        (uint256 consumedAmount, uint256 pendingAmount) = _consumePartLimit(
            unlockAmount,
            _unlockLimitParams[msg.sender]
        );

        if (pendingAmount > 0) {
            // add instead of overwrite to handle case where already pending amount is left
            pendingUnlocks[msg.sender][receiver] += pendingAmount;
            connectorPendingUnlocks[msg.sender] += pendingAmount;
            emit TokensPending(
                msg.sender,
                receiver,
                pendingAmount,
                pendingUnlocks[msg.sender][receiver]
            );
        }
        token__.safeTransfer(receiver, consumedAmount);

        emit TokensUnlocked(msg.sender, receiver, consumedAmount);
    }

    function getMinFees(
        address connector_,
        uint256 msgGasLimit_
    ) external view returns (uint256 totalFees) {
        return IConnector(connector_).getMinFees(msgGasLimit_);
    }

    function getCurrentLockLimit(
        address connector_
    ) external view returns (uint256) {
        return _getCurrentLimit(_lockLimitParams[connector_]);
    }

    function getCurrentUnlockLimit(
        address connector_
    ) external view returns (uint256) {
        return _getCurrentLimit(_unlockLimitParams[connector_]);
    }

    function getLockLimitParams(
        address connector_
    ) external view returns (LimitParams memory) {
        return _lockLimitParams[connector_];
    }

    function getUnlockLimitParams(
        address connector_
    ) external view returns (LimitParams memory) {
        return _unlockLimitParams[connector_];
    }

    /**
     * @notice Rescues funds from the contract if they are locked by mistake.
     * @param token_ The address of the token contract.
     * @param rescueTo_ The address where rescued tokens need to be sent.
     * @param amount_ The amount of tokens to be rescued.
     */
    function rescueFunds(
        address token_,
        address rescueTo_,
        uint256 amount_
    ) external onlyOwner {
        RescueFundsLib.rescueFunds(token_, rescueTo_, amount_);
    }

    /**
     * Configures the yield mode of the token
     * @param mode_ The yield mode to set
     */
    function setYieldMode(IERC20Rebasing.YieldMode mode_) external onlyOwner {
        require(
            mode_ <= IERC20Rebasing.YieldMode.CLAIMABLE,
            "SUBSTANTIAL YIELD only allowed possible in CLAIMABLE mode"
        );
        IERC20Rebasing(token__).configure(mode_);
    }

    /**
     * Designates the pacman. The pacman gives users yield from on high.
     * @param pacman_ The address of the pacman
     */
    function designatePacman(address pacman_) external onlyOwner {
        _designatePacman(pacman_);
    }

    function _designatePacman(address pacman_) internal {
        _pacman = pacman_;
        emit PacmanDesignated(pacman_);
    }

    modifier onlyPacman() {
        require(
            msg.sender == _pacman,
            "ONLY PACMAN can create a chain with YIELD"
        );
        _;
    }

    /**
     * Claims the substantial yield and distributes it to the recipients
     * @param recipients_ The recipients to distribute the yield to
     * @param minAmount The minimum amount of yield to claim
     * @param totalShares The total shares of the recipients
     */
    function claimAndDistributeSubstantialYield(
        SubstantialYieldRecipient[] calldata recipients_,
        uint256 minAmount,
        uint256 totalShares
    ) external onlyPacman {
        uint256 amountToClaim = IERC20Rebasing(token__).getClaimableAmount(
            address(this)
        );
        require(amountToClaim >= minAmount, "YIELD NOT SUBSTANTIAL ENOUGH");
        uint256 remainingShares = totalShares;
        for (uint256 i; i < recipients_.length; i++) {
            IERC20Rebasing(token__).claim(
                recipients_[i].recipient,
                (amountToClaim * recipients_[i].shares) / totalShares
            );
            remainingShares -= recipients_[i].shares;
        }
        require(remainingShares == 0, "INSUFFICIENT YEILD DISTRIBUTED");
    }
}
