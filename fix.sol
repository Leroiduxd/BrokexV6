// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/*//////////////////////////////////////////////////////////////
//                       EXTERNAL INTERFACES
//////////////////////////////////////////////////////////////*/

interface ISupraSValueFeedMinimal {
    struct priceFeed {
        uint256 round;
        uint256 decimals;
        uint256 time;
        uint256 price;
    }
    function getSvalue(uint256 _pairIndex) external view returns (priceFeed memory);
}

interface IBrokexCore {
    // renvoie commission et marge en USD 6 décimales
    function previewOrder(
        uint256 assetIndex,
        uint256 prixArg1e18,
        uint256 lots,
        uint32  leverageX
    ) external view returns (uint256 commissionUsd6, uint256 marginUsd6);

    // renvoie le funding (positif ou négatif) en USD 6 décimales
    function getFunding(
        uint256 assetIndex,
        uint256 price1e18,
        uint256 lots,
        uint256 hoursHeld
    ) external view returns (int256 fundingUsd6);
}

interface IBrokexStorage {
    function convertOrderToPosition(uint256 orderId, uint256 execPrice) external;
    function deletePosition(uint256 positionId) external;

    function getClOrdType(uint256 clOrdId) external view returns (uint8);

    // (SL, TP, LIQ) par positionId
    function getPositionClOrdIds(uint256 positionId)
        external
        view
        returns (uint256 slClOrdId, uint256 tpClOrdId, uint256 liqClOrdId);

    // orderId lié à un clOrdId (0 si aucun)
    function getOrderIdByClOrd(uint256 clOrdId) external view returns (uint256);

    // (stopLoss, takeProfit, liquidation) d'une position
    function getTriggersForPosition(uint256 positionId)
        external
        view
        returns (uint256 stopLoss, uint256 takeProfit, uint256 liquidation);

    // positionId lié à un clOrdId (0 si aucun)
    function getPositionIdByClOrd(uint256 clOrdId) external view returns (uint256);
}

interface IBrokexVault {
    // (modifiers retirés, interdits dans une interface)
    function closePosition(
        uint256 positionId,
        int256 pnl,
        uint256 closingCommission
    ) external;
}

/*//////////////////////////////////////////////////////////////
//                    MAIN CONTRACT (UNCHANGED + wiring)
//////////////////////////////////////////////////////////////*/

contract MiniFillVerifier is EIP712, Ownable {
    using ECDSA for bytes32;

    // ---------- External contracts ----------
    ISupraSValueFeedMinimal public supraFeed;
    IBrokexCore public brokexCore;
    IBrokexStorage public brokexStorage;
    IBrokexVault public vault;

    // ---------- Existing state ----------
    address public authorizedSigner;
    mapping(uint256 => bool) public usedOrderId;

    bytes32 private constant MINIFILL_TYPEHASH =
        keccak256("MiniFill(uint256 orderId,uint256 execPriceX8,uint8 side)");

    // ---------- Events ----------
    event SignerChanged(address indexed oldSigner, address indexed newSigner);

    event FillValidated(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side,
        address indexed recovered
    );

    event SupraFeedChanged(address indexed oldFeed, address indexed newFeed);
    event BrokexCoreChanged(address indexed oldCore, address indexed newCore);
    event BrokexStorageChanged(address indexed oldStorage, address indexed newStorage);
    event VaultChanged(address indexed oldVault, address indexed newVault);

    // ---------- Constructor ----------
    constructor(address _supraFeed)
        EIP712("BrokexMiniProof", "1")
        Ownable(msg.sender)
    {
        require(_supraFeed != address(0), "supra=0");
        supraFeed = ISupraSValueFeedMinimal(_supraFeed);
        emit SupraFeedChanged(address(0), _supraFeed);

        authorizedSigner = msg.sender; // Par défaut: toi
        emit SignerChanged(address(0), msg.sender);
    }

    // ---------- Owner setters ----------
    function setAuthorizedSigner(address newSigner) external onlyOwner {
        require(newSigner != address(0), "signer=0");
        emit SignerChanged(authorizedSigner, newSigner);
        authorizedSigner = newSigner;
    }

    function setSupraFeed(address _supraFeed) external onlyOwner {
        require(_supraFeed != address(0), "supra=0");
        emit SupraFeedChanged(address(supraFeed), _supraFeed);
        supraFeed = ISupraSValueFeedMinimal(_supraFeed);
    }

    function setBrokexCore(address _core) external onlyOwner {
        require(_core != address(0), "core=0");
        emit BrokexCoreChanged(address(brokexCore), _core);
        brokexCore = IBrokexCore(_core);
    }

    function setBrokexStorage(address _storage) external onlyOwner {
        require(_storage != address(0), "storage=0");
        emit BrokexStorageChanged(address(brokexStorage), _storage);
        brokexStorage = IBrokexStorage(_storage);
    }

    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "vault=0");
        emit VaultChanged(address(vault), _vault);
        vault = IBrokexVault(_vault);
    }

    // ---------- EIP-712 helpers ----------
    function _hashMiniFill(uint256 orderId, uint256 execPriceX8, uint8 side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(MINIFILL_TYPEHASH, orderId, execPriceX8, side));
    }

    function _digestMiniFill(uint256 orderId, uint256 execPriceX8, uint8 side)
        internal
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(_hashMiniFill(orderId, execPriceX8, side));
    }

    // ---------- Public verification ----------
    function verifyFill(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side,
        bytes calldata signature
    ) external view returns (bool) {
        bytes32 digest = _digestMiniFill(orderId, execPriceX8, side);
        address recovered = ECDSA.recover(digest, signature);
        return recovered != address(0) && recovered == authorizedSigner;
    }

    function recoveredSigner(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side,
        bytes calldata signature
    ) external view returns (address) {
        return ECDSA.recover(_digestMiniFill(orderId, execPriceX8, side), signature);
    }

    function validateFill(
        uint256 orderId,
        uint256 execPriceX8,
        uint8 side,
        bytes calldata signature
    )
        external
        returns (uint256 _orderId, uint256 _execPriceX8, uint8 _side)
    {
        require(!usedOrderId[orderId], "orderId used");
        usedOrderId[orderId] = true;

        address recovered = ECDSA.recover(_digestMiniFill(orderId, execPriceX8, side), signature);
        require(recovered == authorizedSigner, "bad signer");

        emit FillValidated(orderId, execPriceX8, side, recovered);
        return (orderId, execPriceX8, side);
    }

    /*//////////////////////////////////////////////////////////////
    //        (Optionnel) Petites aides de lecture externes
    //////////////////////////////////////////////////////////////*/
    function readSupra(uint256 pairIndex) external view returns (ISupraSValueFeedMinimal.priceFeed memory) {
        return supraFeed.getSvalue(pairIndex);
    }
}
