// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IBrokexVault {
    function depositForOrder(
        uint256 orderId,
        address trader,
        uint256 margin,
        uint256 commission
    ) external;

    function refundOrder(uint256 orderId) external;

    function convertOrderToPosition(
        uint256 orderId,
        uint256 positionId
    ) external;
}

contract Storage is Ownable {
    // ---- Events ----
    event NewOrder(
        uint256 indexed clOrdId,
        uint256 indexed assetIndex,
        bool isLong,
        uint256 size
    );
    event CancelOrder(uint256 indexed clOrdId);

    // ---- Structs ----
    struct Order {
        address trader;
        uint256 assetIndex;
        bool isLong;
        uint256 sizeInAsset;
        uint256 leverage;
        uint256 liquidationPrice;
        uint256 stopLoss;
        uint256 takeProfit;
        uint256 margin;
        uint256 commission;
        uint256 targetPrice;
    }

    struct Position {
        address trader;
        uint256 assetIndex;
        bool isLong;
        uint256 sizeInAsset;
        uint256 leverage;
        uint256 margin;
        uint256 openPrice;
        uint256 openTimestamp;
    }

    IBrokexVault public vault;

    // ✅ Constructeur compatible v5.x - DOIT RECEVOIR L'ADRESSE DU OWNER
    constructor(address initialOwner) Ownable(initialOwner) {
        // rien d'autre - Ownable v5.x gère l'owner
    }

    // ---- Storage ----
    uint256 public nextOrderId;
    uint256 public nextClOrdId;
    uint256 public nextPositionId;

    mapping(uint256 => Order) public orders;        
    mapping(uint256 => uint256) public clOrdToOrder; 
    mapping(uint256 => uint256) public orderToClOrd; 
    mapping(uint256 => uint8) public clOrdType;      

    mapping(address => uint256[]) private traderOrders;   

    mapping(uint256 => Position) public positions;   
    mapping(address => uint256[]) private traderPositions; 

    mapping(uint256 => uint256) public clOrdToPosition; 
    mapping(uint256 => uint256) public positionSL;
    mapping(uint256 => uint256) public positionTP;
    mapping(uint256 => uint256) public positionLIQ;

    mapping(uint256 => uint256) public slPrice;   
    mapping(uint256 => uint256) public tpPrice;   
    mapping(uint256 => uint256) public liqPrice;  
    mapping(uint256 => bool) public closeRequested;

    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "vault=0");
        vault = IBrokexVault(_vault);
    }

    // ---- Internal helpers ----
    function _removeTraderOrder(address trader, uint256 orderId) internal {
        uint256[] storage list = traderOrders[trader];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == orderId) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    function _removeTraderPosition(address trader, uint256 positionId) internal {
        uint256[] storage list = traderPositions[trader];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == positionId) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    // ---- Orders ----
    function createOrder(
        address trader,               // 👈 nouvelle variable en argument
        uint256 assetIndex,
        bool isLong,
        uint256 sizeInAsset,
        uint256 leverage,
        uint256 liquidationPrice,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 margin,
        uint256 commission,
        uint256 targetPrice
    ) external {
        nextOrderId++;
        nextClOrdId++;

        orders[nextOrderId] = Order({
            trader: trader,            // 👈 utilisation du paramètre
            assetIndex: assetIndex,
            isLong: isLong,
            sizeInAsset: sizeInAsset,
            leverage: leverage,
            liquidationPrice: liquidationPrice,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            margin: margin,
            commission: commission,
            targetPrice: targetPrice
        });

        clOrdToOrder[nextClOrdId] = nextOrderId;
        orderToClOrd[nextOrderId] = nextClOrdId;
        clOrdType[nextClOrdId] = 0; // 0=open

        traderOrders[trader].push(nextOrderId); // 👈 remplacé msg.sender

        // 🔹 Appel au Vault pour bloquer marge + commission
        vault.depositForOrder(nextOrderId, trader, margin, commission); // 👈 remplacé msg.sender

        emit NewOrder(nextClOrdId, assetIndex, isLong, sizeInAsset);
    }


    function cancelOrder(uint256 orderId) external {
        Order memory o = orders[orderId];
        require(o.trader != address(0), "ORDER_NOT_FOUND");
        require(o.trader == msg.sender, "NOT_OWNER");

        uint256 clOrdId = orderToClOrd[orderId];

        // 🔹 Appel au Vault pour rembourser marge + commission
        vault.refundOrder(orderId);

        // Nettoyage local
        delete orders[orderId];
        delete clOrdToOrder[clOrdId];
        delete orderToClOrd[orderId];
        delete clOrdType[clOrdId];
        _removeTraderOrder(msg.sender, orderId);

        emit CancelOrder(clOrdId);
    }

    // ---- Orders -> Position ----
    function convertOrderToPosition(uint256 orderId, uint256 execPrice) external {
        Order memory o = orders[orderId];
        require(o.trader != address(0), "ORDER_NOT_FOUND");

        // 1) Réserver le prochain positionId
        nextPositionId++;

        // 2) Appeler le Vault pour convertir l'ordre en position (transfert des fonds/commissions côté vault)
        vault.convertOrderToPosition(orderId, nextPositionId);

        // 3) Écrire l'état local de la position
        positions[nextPositionId] = Position({
            trader: o.trader,
            assetIndex: o.assetIndex,
            isLong: o.isLong,
            sizeInAsset: o.sizeInAsset,
            leverage: o.leverage,
            margin: o.margin,
            openPrice: execPrice,
            openTimestamp: block.timestamp
        });

        traderPositions[o.trader].push(nextPositionId);

        // 4) Créer les triggers (SL/TP/LIQ) si présents sur l'ordre
        if (o.stopLoss > 0) {
            nextClOrdId++;
            positionSL[nextPositionId] = nextClOrdId;
            slPrice[nextPositionId] = o.stopLoss;
            clOrdToPosition[nextClOrdId] = nextPositionId;
            clOrdType[nextClOrdId] = 2; // SL
            emit NewOrder(nextClOrdId, o.assetIndex, !o.isLong, o.sizeInAsset);
        }

        if (o.takeProfit > 0) {
            nextClOrdId++;
            positionTP[nextPositionId] = nextClOrdId;
            tpPrice[nextPositionId] = o.takeProfit;
            clOrdToPosition[nextClOrdId] = nextPositionId;
            clOrdType[nextClOrdId] = 1; // TP
            emit NewOrder(nextClOrdId, o.assetIndex, !o.isLong, o.sizeInAsset);
        }

        if (o.liquidationPrice > 0) {
            nextClOrdId++;
            positionLIQ[nextPositionId] = nextClOrdId;
            liqPrice[nextPositionId] = o.liquidationPrice;
            clOrdToPosition[nextClOrdId] = nextPositionId;
            clOrdType[nextClOrdId] = 3; // LIQ
            emit NewOrder(nextClOrdId, o.assetIndex, !o.isLong, o.sizeInAsset);
        }

        // 5) Nettoyage de l'ordre local
        uint256 clOrdId = orderToClOrd[orderId];
        delete orders[orderId];
        delete clOrdToOrder[clOrdId];
        delete orderToClOrd[orderId];
        delete clOrdType[clOrdId];
        _removeTraderOrder(o.trader, orderId);
    }

    // ---- Update SL / TP ----
    function updateStopLoss(uint256 positionId, uint256 newPrice) external {
        Position memory p = positions[positionId];
        require(p.trader == msg.sender, "NOT_OWNER");

        uint256 oldCl = positionSL[positionId];
        if (oldCl != 0) {
            emit CancelOrder(oldCl);
            delete clOrdToPosition[oldCl];
            delete clOrdType[oldCl];
            delete positionSL[positionId];
            delete slPrice[positionId];
        }

        if (newPrice > 0) {
            nextClOrdId++;
            positionSL[positionId] = nextClOrdId;
            slPrice[positionId] = newPrice;
            clOrdToPosition[nextClOrdId] = positionId;
            clOrdType[nextClOrdId] = 2; // SL
            emit NewOrder(nextClOrdId, p.assetIndex, !p.isLong, p.sizeInAsset);
        }
    }

    function updateTakeProfit(uint256 positionId, uint256 newPrice) external {
        Position memory p = positions[positionId];
        require(p.trader == msg.sender, "NOT_OWNER");

        uint256 oldCl = positionTP[positionId];
        if (oldCl != 0) {
            emit CancelOrder(oldCl);
            delete clOrdToPosition[oldCl];
            delete clOrdType[oldCl];
            delete positionTP[positionId];
            delete tpPrice[positionId];
        }

        if (newPrice > 0) {
            nextClOrdId++;
            positionTP[positionId] = nextClOrdId;
            tpPrice[positionId] = newPrice;
            clOrdToPosition[nextClOrdId] = positionId;
            clOrdType[nextClOrdId] = 1; // TP
            emit NewOrder(nextClOrdId, p.assetIndex, !p.isLong, p.sizeInAsset);
        }
    }

    // ---- Delete Position ----
    function deletePosition(uint256 positionId) external {
        Position memory p = positions[positionId];
        require(p.trader == msg.sender, "NOT_OWNER");

        // cancel SL
        uint256 sl = positionSL[positionId];
        if (sl != 0) {
            emit CancelOrder(sl);
            delete clOrdToPosition[sl];
            delete clOrdType[sl];
            delete positionSL[positionId];
            delete slPrice[positionId];
        }

        // cancel TP
        uint256 tp = positionTP[positionId];
        if (tp != 0) {
            emit CancelOrder(tp);
            delete clOrdToPosition[tp];
            delete clOrdType[tp];
            delete positionTP[positionId];
            delete tpPrice[positionId];
        }

        // cancel LIQ
        uint256 liq = positionLIQ[positionId];
        if (liq != 0) {
            emit CancelOrder(liq);
            delete clOrdToPosition[liq];
            delete clOrdType[liq];
            delete positionLIQ[positionId];
            delete liqPrice[positionId];
        }

        // remove position
        delete positions[positionId];
        _removeTraderPosition(p.trader, positionId);
    }

    // ---- Getters enrichis ----
    function getTraderPositions(address trader) external view returns (uint256[] memory) {
        return traderPositions[trader];
    }

    function getTraderOrders(address trader) external view returns (uint256[] memory) {
        return traderOrders[trader];
    }

    function getPositionById(uint256 positionId) 
        external 
        view 
        returns (
            Position memory pos,
            uint256 stopLoss,
            uint256 takeProfit,
            uint256 liquidation
        ) 
    {
        pos = positions[positionId];
        stopLoss = slPrice[positionId];
        takeProfit = tpPrice[positionId];
        liquidation = liqPrice[positionId];
    }

    function getPositionTriggers(uint256 positionId) 
        external 
        view 
        returns (uint256 stopLoss, uint256 takeProfit, uint256 liquidation) 
    {
        return (
            slPrice[positionId],
            tpPrice[positionId],
            liqPrice[positionId]
        );
    }

    // ---- Fonction : demander une fermeture au marché ----
    function requestCloseOnMarket(uint256 positionId) external {
        Position memory p = positions[positionId];
        require(p.trader == msg.sender, "NOT_OWNER");
        require(!closeRequested[positionId], "ALREADY_REQUESTED");

        nextClOrdId++;

        // marquer la position comme "close demandé"
        closeRequested[positionId] = true;

        // ordre antagoniste : inverse du sens initial
        bool opposite = !p.isLong;

        // émettre l'ordre au marché (targetPrice = 0)
        emit NewOrder(nextClOrdId, p.assetIndex, opposite, p.sizeInAsset);

        // marquer ce clOrd comme un close market
        clOrdToPosition[nextClOrdId] = positionId;
        clOrdType[nextClOrdId] = 4; // 4 = close market
    }

    // --- Get clOrd type code (0=open, 1=TP, 2=SL, 3=LIQ, 4=close market) ---
    function getClOrdType(uint256 clOrdId) external view returns (uint8) {
        return clOrdType[clOrdId];
    }
    
    // --- From a positionId, return the three child clOrdIds (SL, TP, LIQ) ---
    function getPositionClOrdIds(uint256 positionId)
        external
        view
        returns (uint256 slClOrdId, uint256 tpClOrdId, uint256 liqClOrdId)
    {
        return (positionSL[positionId], positionTP[positionId], positionLIQ[positionId]);
    }
    
    // --- From a clOrdId, return its linked orderId (0 if none) ---
    function getOrderIdByClOrd(uint256 clOrdId) external view returns (uint256) {
        return clOrdToOrder[clOrdId];
    }
    
    // --- Triggers (prices) for a given positionId (alias of existing getter) ---
    function getTriggersForPosition(uint256 positionId)
        external
        view
        returns (uint256 stopLoss, uint256 takeProfit, uint256 liquidation)
    {
        return (slPrice[positionId], tpPrice[positionId], liqPrice[positionId]);
    }
    
    // --- From a clOrdId, go back to the parent positionId (0 if none) ---
    function getPositionIdByClOrd(uint256 clOrdId) external view returns (uint256) {
        return clOrdToPosition[clOrdId];
    }

}

/*
📝 DEPLOYMENT NOTES pour OpenZeppelin v5.x:

Pour déployer avec cette version, vous devez passer l'adresse du owner:

// Exemple avec Hardhat:
const Storage = await ethers.getContractFactory("Storage");
const storage = await Storage.deploy(deployer.address); // ou toute autre adresse

// Exemple avec Remix:
// Dans le champ "Deploy", entrer: "0xVotreAdresseCommeOwner"
*/
