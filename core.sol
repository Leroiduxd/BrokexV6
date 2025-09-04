// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBrokexStorage {
    function createOrder(
        address trader,
        uint256 assetIndex,
        bool isLong,
        uint256 sizeInAsset,   // = lots (même sémantique)
        uint256 leverage,
        uint256 liquidationPrice,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 margin,        // USD 6 déc.
        uint256 commission,    // USD 6 déc.
        uint256 targetPrice    // 0 = market
    ) external;

    function cancelOrder(uint256 orderId) external;

    function updateStopLoss(uint256 positionId, uint256 newPrice) external;
}

interface ISupraSValueFeedMinimal {
    struct priceFeed {
        uint256 round;
        uint256 decimals;
        uint256 time;
        uint256 price;
    }

    function getSvalue(uint256 _pairIndex) external view returns (priceFeed memory);
}

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract BrokexCalculator is Ownable {
    using Math for uint256;

    IBrokexStorage public brokexStorage;
    ISupraSValueFeedMinimal public supraPush;

    uint256 constant WAD = 1e18;       // interne x18
    uint256 constant USD_SCALE = 1e12; // conversion x18 -> x6
    uint256 public constant LIQ_LOSS_OF_MARGIN_WAD = 8e17; // 0.8 en x1e18


    struct LotConfig {
        uint256 num; // multiplicateur
        uint256 den; // diviseur
    }

    // ----------------------
    // Stockage
    // ----------------------
    mapping(uint256 => LotConfig) public lotConfig;     // assetIndex -> lot fraction
    mapping(uint8 => uint256) public commissionRateWad; // marketId -> commission (x18)
    mapping(uint256 => int256) public fundingRateWad;   // assetIndex -> funding rate/h (x18 signé)
    mapping(uint256 => uint8) public marketOfAsset;     // assetIndex -> marketId
    mapping(uint8 => bool) public marketOpen;
    mapping(uint8 => uint32) public maxLeverage;



    function setMarketStatus(uint8 marketId, bool isOpen) external onlyOwner {
        marketOpen[marketId] = isOpen;
    }

    function setBrokexStorage(address _storage) external onlyOwner {
        require(_storage != address(0), "storage=0");
        brokexStorage = IBrokexStorage(_storage);
    }


    // ----------------------
    // Constructor
    // ----------------------
    constructor(address supraPushAddress) Ownable(msg.sender) {
        require(supraPushAddress != address(0), "ORACLE_ADDR_0");
        supraPush = ISupraSValueFeedMinimal(supraPushAddress);
    }

    // ----------------------
    // Admin
    // ----------------------

    function listAsset(uint256 assetIndex, uint8 marketId, uint256 num, uint256 den) external onlyOwner {
        require(num > 0 && den > 0, "BAD_LOT");
        lotConfig[assetIndex] = LotConfig(num, den);
        marketOfAsset[assetIndex] = marketId;
    }

    function setCommissionRate(uint8 marketId, uint256 rateWad) external onlyOwner {
        commissionRateWad[marketId] = rateWad;
    }

    function setFundingRate(uint256 assetIndex, int256 rateWad) external onlyOwner {
        fundingRateWad[assetIndex] = rateWad;
    }

    function setMaxLeverage(uint8 marketId, uint32 leverageX) external onlyOwner {
        require(leverageX > 0, "BAD_LEVERAGE");
        maxLeverage[marketId] = leverageX;
    }

    // ----------------------
    // Internes
    // ----------------------

    function _qty1e18(uint256 assetIndex, uint256 lots) internal view returns (uint256) {
        LotConfig memory cfg = lotConfig[assetIndex];
        require(cfg.num > 0 && cfg.den > 0, "ASSET_NOT_LISTED");
        return Math.mulDiv(lots * WAD, cfg.num, cfg.den);
    }

    function _notional1e18(uint256 qty1e18, uint256 price1e18) internal pure returns (uint256) {
        return Math.mulDiv(qty1e18, price1e18, WAD);
    }

    function _toUsd6(uint256 amount1e18, bool ceil) internal pure returns (uint256) {
        return ceil ? Math.ceilDiv(amount1e18, USD_SCALE) : amount1e18 / USD_SCALE;
    }

    function _price1e18FromPair(uint256 pairIndex) internal view returns (uint256) {
        ISupraSValueFeedMinimal.priceFeed memory pf = supraPush.getSvalue(pairIndex);
        require(pf.price > 0, "NO_PRICE");
        uint256 dec = pf.decimals;
        if (dec == 18) return pf.price;
        if (dec > 18) return pf.price / (10 ** (dec - 18));
        return pf.price * (10 ** (18 - dec));
    }

    // ----------------------
    // Lecture / Calculs (entrée prix x1e18)
    // ----------------------

    function getMarginUsd6(uint256 assetIndex, uint256 price1e18, uint256 lots, uint32 leverageX)
        external
        view
        returns (uint256)
    {
        uint256 qty1e18 = _qty1e18(assetIndex, lots);
        uint256 notional1e18 = _notional1e18(qty1e18, price1e18);
        uint256 margin1e18 = Math.ceilDiv(notional1e18, leverageX);
        return _toUsd6(margin1e18, true);
    }

    function getCommissionUsd6(uint256 assetIndex, uint256 price1e18, uint256 lots)
        external
        view
        returns (uint256)
    {
        uint256 qty1e18 = _qty1e18(assetIndex, lots);
        uint256 notional1e18 = _notional1e18(qty1e18, price1e18);

        uint8 marketId = marketOfAsset[assetIndex];
        uint256 rateWad = commissionRateWad[marketId];

        uint256 fee1e18 = Math.mulDiv(notional1e18, rateWad, WAD);
        return _toUsd6(fee1e18, true);
    }

    function getFundingUsd6(uint256 assetIndex, uint256 price1e18, uint256 lots, uint256 hoursHeld)
        external
        view
        returns (int256)
    {
        uint256 qty1e18 = _qty1e18(assetIndex, lots);
        uint256 notional1e18 = _notional1e18(qty1e18, price1e18);

        int256 rateWad = fundingRateWad[assetIndex];
        if (rateWad == 0) return 0;

        int256 funding1e18 = (int256(notional1e18) * rateWad * int256(hoursHeld)) / int256(WAD);
        if (funding1e18 >= 0) {
            return int256(_toUsd6(uint256(funding1e18), true));
        } else {
            return -int256(_toUsd6(uint256(-funding1e18), false));
        }
    }

    // ----------------------
    // Lecture / Calculs (prix récupéré via Supra Push)
    // ----------------------

    function getMarginUsd6ByPair(uint256 assetIndex, uint256 pairIndex, uint256 lots, uint32 leverageX)
        external
        view
        returns (uint256)
    {
        uint256 price1e18 = _price1e18FromPair(pairIndex);
        uint256 qty1e18 = _qty1e18(assetIndex, lots);
        uint256 notional1e18 = _notional1e18(qty1e18, price1e18);
        uint256 margin1e18 = Math.ceilDiv(notional1e18, leverageX);
        return _toUsd6(margin1e18, true);
    }

    function getCommissionUsd6ByPair(uint256 assetIndex, uint256 pairIndex, uint256 lots)
        external
        view
        returns (uint256)
    {
        uint256 price1e18 = _price1e18FromPair(pairIndex);
        uint256 qty1e18 = _qty1e18(assetIndex, lots);
        uint256 notional1e18 = _notional1e18(qty1e18, price1e18);

        uint8 marketId = marketOfAsset[assetIndex];
        uint256 rateWad = commissionRateWad[marketId];

        uint256 fee1e18 = Math.mulDiv(notional1e18, rateWad, WAD);
        return _toUsd6(fee1e18, true);
    }

    function getFundingUsd6ByPair(uint256 assetIndex, uint256 pairIndex, uint256 lots, uint256 hoursHeld)
        external
        view
        returns (int256)
    {
        uint256 price1e18 = _price1e18FromPair(pairIndex);
        uint256 qty1e18 = _qty1e18(assetIndex, lots);
        uint256 notional1e18 = _notional1e18(qty1e18, price1e18);

        int256 rateWad = fundingRateWad[assetIndex];
        if (rateWad == 0) return 0;

        int256 funding1e18 = (int256(notional1e18) * rateWad * int256(hoursHeld)) / int256(WAD);
        if (funding1e18 >= 0) {
            return int256(_toUsd6(uint256(funding1e18), true));
        } else {
            return -int256(_toUsd6(uint256(-funding1e18), false));
        }
    }

    function previewOrder(
        uint256 assetIndex,
        uint256 prixArg1e18,
        uint256 lots,
        uint32  leverageX
    ) external view returns (uint256 commissionUsd6, uint256 marginUsd6) {
        require(leverageX > 0, "BAD_LEVERAGE");

        // Prix: si non fourni (0), on va le chercher via l'oracle push Supra (getSvalue)
        uint256 price1e18 = prixArg1e18 == 0 ? _price1e18FromPair(assetIndex) : prixArg1e18;
        require(price1e18 > 0, "PRICE_0");

        // Quantite (1e18) et notionnel (1e18)
        uint256 qty1e18 = _qty1e18(assetIndex, lots);
        uint256 notional1e18 = _notional1e18(qty1e18, price1e18);

        // Commission (x18 -> USD6) selon le marketId de l'actif
        uint8 marketId = marketOfAsset[assetIndex];
        uint256 rateWad = commissionRateWad[marketId];
        uint256 fee1e18 = Math.mulDiv(notional1e18, rateWad, WAD);
        commissionUsd6 = _toUsd6(fee1e18, true);

        // Marge (x18 -> USD6)
        uint256 margin1e18 = Math.ceilDiv(notional1e18, leverageX);
        marginUsd6 = _toUsd6(margin1e18, true);
    }

    function getLiquidationPrice(
        uint256 openPrice1e18,
        uint32  leverageX,
        bool    isLong
    ) external pure returns (uint256 liqPrice1e18) {
        require(openPrice1e18 > 0, "BAD_PRICE");
        require(leverageX > 0, "BAD_LEVERAGE");

        // Δ% prix = (perte tolérée / marge) / levier = 0.8 / leverageX (en WAD)
        uint256 deltaWad = LIQ_LOSS_OF_MARGIN_WAD / leverageX; // x1e18

        if (isLong) {
            // Long: liquidation sur baisse de prix
            liqPrice1e18 = Math.mulDiv(openPrice1e18, (WAD - deltaWad), WAD);
        } else {
            // Short: liquidation sur hausse de prix
            liqPrice1e18 = Math.mulDiv(openPrice1e18, (WAD + deltaWad), WAD);
        }
    }

    function createOrder(
        uint256 assetIndex,
        bool isLong,
        uint256 lots,             // = sizeInAsset
        uint32 leverageX,
        uint256 liquidationPrice,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 targetPrice1e18   // 0 = market, sinon prix en 1e18
    ) external {
        require(address(brokexStorage) != address(0), "storage not set");
        require(lotConfig[assetIndex].num > 0 && lotConfig[assetIndex].den > 0, "ASSET_NOT_LISTED");
        require(leverageX > 0, "BAD_LEVERAGE");

        // prix utilisé : soit celui passé en paramètre, soit celui de l’oracle
        uint256 price1e18 = targetPrice1e18 == 0
            ? _price1e18FromPair(assetIndex)  // oracle Supra
            : targetPrice1e18;

        // calculer commission et marge via previewOrder
        (uint256 commissionUsd6, uint256 marginUsd6) =
            this.previewOrder(assetIndex, price1e18, lots, leverageX);

        // forward vers le Storage avec msg.sender comme trader
        brokexStorage.createOrder(
            msg.sender,          // trader
            assetIndex,
            isLong,
            lots,                // sizeInAsset = lots
            leverageX,           // leverage
            liquidationPrice,
            stopLoss,
            takeProfit,
            marginUsd6,
            commissionUsd6,
            price1e18            // targetPrice
        );
    }



}

