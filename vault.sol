// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Vault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    address public brokexStorage;
    address public commissionReceiver;
    address public pnlBank;

    struct LockedOrder {
        address trader;
        uint256 margin;
        uint256 commission;
    }

    struct Position {
        address trader;
        uint256 margin;
    }

    mapping(uint256 => LockedOrder) private orders;
    mapping(uint256 => Position) private positions;

    mapping(address => uint256) public accruedCommission;
    mapping(address => uint256) public pnlBankBalance;

    event OrderCreated(uint256 indexed orderId);
    event OrderCanceled(uint256 indexed orderId);
    event PositionCreated(uint256 indexed positionId);
    event PositionClosed(uint256 indexed positionId);

    modifier onlyStorage() {
        require(msg.sender == brokexStorage, "BrokexVault: only storage");
        _;
    }

    constructor(
        address _asset,
        address _brokexStorage,
        address _commissionReceiver,
        address _pnlBank
    ) Ownable(msg.sender) {
        require(_asset != address(0), "asset=0");
        require(_brokexStorage != address(0), "storage=0");
        require(_commissionReceiver != address(0), "commissionReceiver=0");
        require(_pnlBank != address(0), "pnlBank=0");
        asset = IERC20(_asset);
        brokexStorage = _brokexStorage;
        commissionReceiver = _commissionReceiver;
        pnlBank = _pnlBank;
    }

    function setBrokexStorage(address _storage) external onlyOwner {
        require(_storage != address(0), "storage=0");
        brokexStorage = _storage;
    }

    function setCommissionReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), "receiver=0");
        commissionReceiver = _receiver;
    }

    function setPnlBank(address _pnlBank) external onlyOwner {
        require(_pnlBank != address(0), "pnlBank=0");
        pnlBank = _pnlBank;
    }

    function pnlBankReplenish(uint256 amount) external nonReentrant {
        require(msg.sender == pnlBank, "only pnlBank");
        require(amount > 0, "amount=0");
        asset.safeTransferFrom(msg.sender, address(this), amount);
        pnlBankBalance[pnlBank] += amount;
    }

    function pnlBankWithdraw(uint256 amount) external nonReentrant {
        require(msg.sender == pnlBank, "only pnlBank");
        require(amount > 0, "amount=0");
        require(pnlBankBalance[pnlBank] >= amount, "pnl reserve insufficient");
        pnlBankBalance[pnlBank] -= amount;
        asset.safeTransfer(pnlBank, amount);
    }

    function withdrawCommission(uint256 amount) external nonReentrant {
        address receiver = msg.sender;
        require(accruedCommission[receiver] >= amount, "insufficient commission");
        accruedCommission[receiver] -= amount;
        asset.safeTransfer(receiver, amount);
    }

    function depositForOrder(
        uint256 orderId,
        address trader,
        uint256 margin,
        uint256 commission
    ) external onlyStorage nonReentrant {
        require(trader != address(0), "trader=0");
        require(margin > 0, "margin=0");
        require(orders[orderId].trader == address(0), "order exists");
        require(positions[orderId].trader == address(0), "id collision");
        uint256 total = margin + commission;
        asset.safeTransferFrom(trader, address(this), total);
        orders[orderId] = LockedOrder({ trader: trader, margin: margin, commission: commission });
        emit OrderCreated(orderId);
    }

    function refundOrder(uint256 orderId) external onlyStorage nonReentrant {
        LockedOrder memory o = orders[orderId];
        require(o.trader != address(0), "order not found");
        delete orders[orderId];
        uint256 refundAmount = o.margin + o.commission;
        asset.safeTransfer(o.trader, refundAmount);
        emit OrderCanceled(orderId);
    }

    function convertOrderToPosition(uint256 orderId, uint256 positionId) external onlyStorage nonReentrant {
        LockedOrder memory o = orders[orderId];
        require(o.trader != address(0), "order not found");
        require(positions[positionId].trader == address(0), "position exists");
        delete orders[orderId];
        positions[positionId] = Position({ trader: o.trader, margin: o.margin });
        accruedCommission[commissionReceiver] += o.commission;
        emit PositionCreated(positionId);
    }

    function closePosition(
        uint256 positionId,
        int256 pnl,
        uint256 closingCommission
    ) external onlyStorage nonReentrant {
        Position memory p = positions[positionId];
        require(p.trader != address(0), "position not found");
        delete positions[positionId];
        require(p.margin >= closingCommission, "closing fee > margin");
        uint256 marginAfterFee = p.margin - closingCommission;
        accruedCommission[commissionReceiver] += closingCommission;
        uint256 traderPayout = 0;
        if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            uint256 toBank = loss > marginAfterFee ? marginAfterFee : loss;
            if (toBank > 0) {
                pnlBankBalance[pnlBank] += toBank;
                marginAfterFee -= toBank;
            }
            if (marginAfterFee > 0) {
                traderPayout = marginAfterFee;
                asset.safeTransfer(p.trader, traderPayout);
            }
        } else if (pnl > 0) {
            uint256 profit = uint256(pnl);
            require(pnlBankBalance[pnlBank] >= profit, "pnl bank insufficient");
            traderPayout = marginAfterFee + profit;
            pnlBankBalance[pnlBank] -= profit;
            asset.safeTransfer(p.trader, traderPayout);
        } else {
            if (marginAfterFee > 0) {
                traderPayout = marginAfterFee;
                asset.safeTransfer(p.trader, traderPayout);
            }
        }
        emit PositionClosed(positionId);
    }

    function getOrder(uint256 orderId) external view returns (LockedOrder memory) {
        return orders[orderId];
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }
}
