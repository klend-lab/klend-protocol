pragma solidity ^0.5.16;

import "./Exponential.sol";
import "./ErrorReporter.sol";

contract KLendPriceOracle is Exponential, ComptrollerErrorReporter {

    /**
      * @dev flag for whether or not contract is paused
      *
      */
    bool public paused;

    uint public constant numBlocksPerPeriod = 947; // approximately 1 hour: 60 seconds/minute * 60 minutes/hour * 1 block/3.8 seconds

    uint public constant maxSwingMantissa = (10 ** 17); // 0.1

    /**
      * @dev Mapping of asset addresses and their corresponding price in terms of Eth-Wei
      *      which is simply equal to AssetWeiPrice * 10e18. For instance, if OMG token was
      *      worth 5x Eth then the price for OMG would be 5*10e18 or Exp({mantissa: 5000000000000000000}).
      * map: assetAddress -> Exp
      */
    mapping(address => Exp) public _assetPrices;

    constructor(address _poster) public {
        anchorAdmin = msg.sender;
        poster = _poster;
        maxSwing = Exp({mantissa : maxSwingMantissa});
    }

    /**
      * @notice Do not pay into PriceOracle
      */
    function() payable external {
        revert();
    }

    enum OracleError {
        NO_ERROR,
        UNAUTHORIZED,
        FAILED_TO_SET_PRICE
    }

    enum OracleFailureInfo {
        ACCEPT_ANCHOR_ADMIN_PENDING_ANCHOR_ADMIN_CHECK,
        SET_PAUSED_OWNER_CHECK,
        SET_PENDING_ANCHOR_ADMIN_OWNER_CHECK,
        SET_PENDING_ANCHOR_PERMISSION_CHECK,
        SET_PRICE_CALCULATE_SWING,
        SET_PRICE_CAP_TO_MAX,
        SET_PRICE_MAX_SWING_CHECK,
        SET_PRICE_NO_ANCHOR_PRICE_OR_INITIAL_PRICE_ZERO,
        SET_PRICE_PERMISSION_CHECK,
        SET_PRICE_ZERO_PRICE,
        SET_PRICES_PARAM_VALIDATION
    }

    /**
      * @dev `msgSender` is msg.sender; `error` corresponds to enum OracleError; `info` corresponds to enum OracleFailureInfo, and `detail` is an arbitrary
      * contract-specific code that enables us to report opaque error codes from upgradeable contracts.
      **/
    event OracleFailure(address msgSender, address asset, uint error, uint info, uint detail);

    /**
      * @dev use this when reporting a known error from the price oracle or a non-upgradeable collaborator
      *      Using Oracle in name because we already inherit a `fail` function from ErrorReporter.sol via Exponential.sol
      */
    function failOracle(address asset, OracleError err, OracleFailureInfo info) internal returns (uint) {
        emit OracleFailure(msg.sender, asset, uint(err), uint(info), 0);

        return uint(err);
    }

    /**
      * @dev Use this when reporting an error from the money market. Give the money market result as `details`
      */
    function failOracleWithDetails(address asset, OracleError err, OracleFailureInfo info, uint details) internal returns (uint) {
        emit OracleFailure(msg.sender, asset, uint(err), uint(info), details);

        return uint(err);
    }

    /**
      * @dev An administrator who can set the pending anchor value for assets.
      *      Set in the constructor.
      */
    address public anchorAdmin;

    /**
      * @dev pending anchor administrator for this contract.
      */
    address public pendingAnchorAdmin;

    /**
      * @dev Address of the price poster.
      *      Set in the constructor.
      */
    address public poster;

    /**
      * @dev maxSwing the maximum allowed percentage difference between a new price and the anchor's price
      *      Set only in the constructor
      */
    Exp public maxSwing;

    struct Anchor {
        // floor(block.number / numBlocksPerPeriod) + 1
        uint period;

        // Price in ETH, scaled by 10**18
        uint priceMantissa;
    }

    /**
      * @dev anchors by asset
      */
    mapping(address => Anchor) public anchors;

    /**
      * @dev pending anchor prices by asset
      */
    mapping(address => uint) public pendingAnchors;

    /**
      * @dev emitted when a pending anchor is set
      * @param asset Asset for which to set a pending anchor
      * @param oldScaledPrice if an unused pending anchor was present, its value; otherwise 0.
      * @param newScaledPrice the new scaled pending anchor price
      */
    event NewPendingAnchor(address anchorAdmin, address asset, uint oldScaledPrice, uint newScaledPrice);

    /**
      * @notice provides ability to override the anchor price for an asset
      * @dev Admin function to set the anchor price for an asset
      * @param asset Asset for which to override the anchor price
      * @param newScaledPrice New anchor price
      * @return uint 0=success, otherwise a failure (see enum OracleError for details)
      */
    function _setPendingAnchor(address asset, uint newScaledPrice) public returns (uint) {
        // Check caller = anchorAdmin. Note: Deliberately not allowing admin. They can just change anchorAdmin if desired.
        if (msg.sender != anchorAdmin) {
            return failOracle(asset, OracleError.UNAUTHORIZED, OracleFailureInfo.SET_PENDING_ANCHOR_PERMISSION_CHECK);
        }

        uint oldScaledPrice = pendingAnchors[asset];
        pendingAnchors[asset] = newScaledPrice;

        emit NewPendingAnchor(msg.sender, asset, oldScaledPrice, newScaledPrice);

        return uint(OracleError.NO_ERROR);
    }

    /**
      * @dev emitted for all price changes
      */
    event PricePosted(address asset, uint previousPriceMantissa, uint requestedPriceMantissa, uint newPriceMantissa);

    /**
      * @dev emitted if this contract successfully posts a capped-to-max price to the money market
      */
    event CappedPricePosted(address asset, uint requestedPriceMantissa, uint anchorPriceMantissa, uint cappedPriceMantissa);

    /**
      * @dev emitted when admin either pauses or resumes the contract; newState is the resulting state
      */
    event SetPaused(bool newState);

    /**
      * @dev emitted when pendingAnchorAdmin is changed
      */
    event NewPendingAnchorAdmin(address oldPendingAnchorAdmin, address newPendingAnchorAdmin);

    /**
      * @dev emitted when pendingAnchorAdmin is accepted, which means anchor admin is updated
      */
    event NewAnchorAdmin(address oldAnchorAdmin, address newAnchorAdmin);

    /**
      * @notice set `paused` to the specified state
      * @dev Admin function to pause or resume the market
      * @param requestedState value to assign to `paused`
      * @return uint 0=success, otherwise a failure
      */
    function _setPaused(bool requestedState) public returns (uint) {
        // Check caller = anchorAdmin
        if (msg.sender != anchorAdmin) {
            return failOracle(address(0), OracleError.UNAUTHORIZED, OracleFailureInfo.SET_PAUSED_OWNER_CHECK);
        }

        paused = requestedState;
        emit SetPaused(requestedState);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Begins transfer of anchor admin rights. The newPendingAnchorAdmin must call `_acceptAnchorAdmin` to finalize the transfer.
      * @dev Admin function to begin change of anchor admin. The newPendingAnchorAdmin must call `_acceptAnchorAdmin` to finalize the transfer.
      * @param newPendingAnchorAdmin New pending anchor admin.
      * @return uint 0=success, otherwise a failure
      *
      * TODO: Should we add a second arg to verify, like a checksum of `newAnchorAdmin` address?
      */
    function _setPendingAnchorAdmin(address newPendingAnchorAdmin) public returns (uint) {
        // Check caller = anchorAdmin
        if (msg.sender != anchorAdmin) {
            return failOracle(address(0), OracleError.UNAUTHORIZED, OracleFailureInfo.SET_PENDING_ANCHOR_ADMIN_OWNER_CHECK);
        }

        // save current value, if any, for inclusion in log
        address oldPendingAnchorAdmin = pendingAnchorAdmin;
        // Store pendingAdmin = newPendingAdmin
        pendingAnchorAdmin = newPendingAnchorAdmin;

        emit NewPendingAnchorAdmin(oldPendingAnchorAdmin, newPendingAnchorAdmin);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Accepts transfer of anchor admin rights. msg.sender must be pendingAnchorAdmin
      * @dev Admin function for pending anchor admin to accept role and update anchor admin
      * @return uint 0=success, otherwise a failure
      */
    function _acceptAnchorAdmin() public returns (uint) {
        // Check caller = pendingAnchorAdmin
        // msg.sender can't be zero
        if (msg.sender != pendingAnchorAdmin) {
            return failOracle(address(0), OracleError.UNAUTHORIZED, OracleFailureInfo.ACCEPT_ANCHOR_ADMIN_PENDING_ANCHOR_ADMIN_CHECK);
        }

        // Save current value for inclusion in log
        address oldAnchorAdmin = anchorAdmin;
        // Store admin = pendingAnchorAdmin
        anchorAdmin = pendingAnchorAdmin;
        // Clear the pending value
        pendingAnchorAdmin = address(0);

        emit NewAnchorAdmin(oldAnchorAdmin, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice retrieves price of an asset
      * @dev function to get price for an asset
      * @param asset Asset for which to get the price
      * @return uint mantissa of asset price (scaled by 1e18) or zero if unset or contract paused
      */
    function assetPrices(address asset) public view returns (uint) {
        // Note: zero is treated by the money market as an invalid
        //       price and will cease operations with that asset
        //       when zero.
        //
        // We get the price as:
        //
        //  1. If the contract is paused, return 0.
        //  2. Return price in `_assetPrices`, which may be zero.

        if (paused) {
            return 0;
        }
        return _assetPrices[asset].mantissa;
    }

    /**
      * @notice retrieves price of an asset
      * @dev function to get price for an asset
      * @param asset Asset for which to get the price
      * @return uint mantissa of asset price (scaled by 1e18) or zero if unset or contract paused
      */
    function getPrice(address asset) public view returns (uint) {
        return assetPrices(asset);
    }

    struct SetPriceLocalVars {
        Exp price;
        Exp swing;
        Exp anchorPrice;
        uint anchorPeriod;
        uint currentPeriod;
        bool priceCapped;
        uint cappingAnchorPriceMantissa;
        uint pendingAnchorMantissa;
    }

    /**
      * @notice entry point for updating prices
      * @dev function to set price for an asset
      * @param asset Asset for which to set the price
      * @param requestedPriceMantissa requested new price, scaled by 10**18
      * @return uint 0=success, otherwise a failure (see enum OracleError for details)
      */
    function setPrice(address asset, uint requestedPriceMantissa) public returns (uint) {
        // Fail when msg.sender is not poster
        if (msg.sender != poster) {
            return failOracle(asset, OracleError.UNAUTHORIZED, OracleFailureInfo.SET_PRICE_PERMISSION_CHECK);
        }

        return setPriceInternal(asset, requestedPriceMantissa);
    }

    function setPriceInternal(address asset, uint requestedPriceMantissa) internal returns (uint) {
        // re-used for intermediate errors
        MathError err;
        SetPriceLocalVars memory localVars;
        // We add 1 for currentPeriod so that it can never be zero and there's no ambiguity about an unset value.
        // (It can be a problem in tests with low block numbers.)
        localVars.currentPeriod = (block.number / numBlocksPerPeriod) + 1;
        localVars.pendingAnchorMantissa = pendingAnchors[asset];
        localVars.price = Exp({mantissa : requestedPriceMantissa});

        if (localVars.pendingAnchorMantissa != 0) {
            // let's explicitly set to 0 rather than relying on default of declaration
            localVars.anchorPeriod = 0;
            localVars.anchorPrice = Exp({mantissa : localVars.pendingAnchorMantissa});

            // Verify movement is within max swing of pending anchor (currently: 10%)
            (err, localVars.swing) = calculateSwing(localVars.anchorPrice, localVars.price);
            if (err != MathError.NO_ERROR) {
                return failOracleWithDetails(asset, OracleError.FAILED_TO_SET_PRICE, OracleFailureInfo.SET_PRICE_CALCULATE_SWING, uint(err));
            }

            // Fail when swing > maxSwing
            if (greaterThanExp(localVars.swing, maxSwing)) {
                return failOracleWithDetails(asset, OracleError.FAILED_TO_SET_PRICE, OracleFailureInfo.SET_PRICE_MAX_SWING_CHECK, localVars.swing.mantissa);
            }
        } else {
            localVars.anchorPeriod = anchors[asset].period;
            localVars.anchorPrice = Exp({mantissa : anchors[asset].priceMantissa});

            if (localVars.anchorPeriod != 0) {
                (err, localVars.priceCapped, localVars.price) = capToMax(localVars.anchorPrice, localVars.price);
                if (err != MathError.NO_ERROR) {
                    return failOracleWithDetails(asset, OracleError.FAILED_TO_SET_PRICE, OracleFailureInfo.SET_PRICE_CAP_TO_MAX, uint(err));
                }
                if (localVars.priceCapped) {
                    // save for use in log
                    localVars.cappingAnchorPriceMantissa = localVars.anchorPrice.mantissa;
                }
            } else {
                // Setting first price. Accept as is (already assigned above from requestedPriceMantissa) and use as anchor
                localVars.anchorPrice = Exp({mantissa : requestedPriceMantissa});
            }
        }

        // Fail if anchorPrice or price is zero.
        // zero anchor represents an unexpected situation likely due to a problem in this contract
        // zero price is more likely as the result of bad input from the caller of this function
        if (isZeroExp(localVars.anchorPrice)) {
            // If we get here price could also be zero, but it does not seem worthwhile to distinguish the 3rd case
            return failOracle(asset, OracleError.FAILED_TO_SET_PRICE, OracleFailureInfo.SET_PRICE_NO_ANCHOR_PRICE_OR_INITIAL_PRICE_ZERO);
        }

        if (isZeroExp(localVars.price)) {
            return failOracle(asset, OracleError.FAILED_TO_SET_PRICE, OracleFailureInfo.SET_PRICE_ZERO_PRICE);
        }

        // BEGIN SIDE EFFECTS

        // Set pendingAnchor = Nothing
        // Pending anchor is only used once.
        if (pendingAnchors[asset] != 0) {
            pendingAnchors[asset] = 0;
        }

        // If currentPeriod > anchorPeriod:
        //  Set anchors[asset] = (currentPeriod, price)
        //  The new anchor is if we're in a new period or we had a pending anchor, then we become the new anchor
        if (localVars.currentPeriod > localVars.anchorPeriod) {
            anchors[asset] = Anchor({period : localVars.currentPeriod, priceMantissa : localVars.price.mantissa});
        }

        uint previousPrice = _assetPrices[asset].mantissa;

        setPriceStorageInternal(asset, localVars.price.mantissa);

        emit PricePosted(asset, previousPrice, requestedPriceMantissa, localVars.price.mantissa);

        if (localVars.priceCapped) {
            // We have set a capped price. Log it so we can detect the situation and investigate.
            emit CappedPricePosted(asset, requestedPriceMantissa, localVars.cappingAnchorPriceMantissa, localVars.price.mantissa);
        }

        return uint(OracleError.NO_ERROR);
    }

    // As a function to allow harness overrides
    function setPriceStorageInternal(address asset, uint256 priceMantissa) internal {
        _assetPrices[asset] = Exp({mantissa: priceMantissa});
    }

    // abs(price - anchorPrice) / anchorPrice
    function calculateSwing(Exp memory anchorPrice, Exp memory price) pure internal returns (MathError, Exp memory) {
        Exp memory numerator;
        MathError err;

        if (greaterThanExp(anchorPrice, price)) {
            (err, numerator) = subExp(anchorPrice, price);
            // can't underflow
            assert(err == MathError.NO_ERROR);
        } else {
            (err, numerator) = subExp(price, anchorPrice);
            // Given greaterThan check above, price >= anchorPrice so can't underflow.
            assert(err == MathError.NO_ERROR);
        }

        return divExp(numerator, anchorPrice);
    }

    function capToMax(Exp memory anchorPrice, Exp memory price) view internal returns (MathError, bool, Exp memory) {
        Exp memory one = Exp({mantissa : mantissaOne});
        Exp memory onePlusMaxSwing;
        Exp memory oneMinusMaxSwing;
        Exp memory max;
        Exp memory min;
        // re-used for intermediate errors
        MathError err;

        (err, onePlusMaxSwing) = addExp(one, maxSwing);
        if (err != MathError.NO_ERROR) {
            return (err, false, Exp({mantissa : 0}));
        }

        // max = anchorPrice * (1 + maxSwing)
        (err, max) = mulExp(anchorPrice, onePlusMaxSwing);
        if (err != MathError.NO_ERROR) {
            return (err, false, Exp({mantissa : 0}));
        }

        // If price > anchorPrice * (1 + maxSwing)
        // Set price = anchorPrice * (1 + maxSwing)
        if (greaterThanExp(price, max)) {
            return (MathError.NO_ERROR, true, max);
        }

        (err, oneMinusMaxSwing) = subExp(one, maxSwing);
        if (err != MathError.NO_ERROR) {
            return (err, false, Exp({mantissa : 0}));
        }

        // min = anchorPrice * (1 - maxSwing)
        (err, min) = mulExp(anchorPrice, oneMinusMaxSwing);
        // We can't overflow here or we would have already overflowed above when calculating `max`
        assert(err == MathError.NO_ERROR);

        // If  price < anchorPrice * (1 - maxSwing)
        // Set price = anchorPrice * (1 - maxSwing)
        if (lessThanExp(price, min)) {
            return (MathError.NO_ERROR, true, min);
        }

        return (MathError.NO_ERROR, false, price);
    }

    /**
      * @notice entry point for updating multiple prices
      * @dev function to set prices for a variable number of assets.
      * @param assets a list of up to assets for which to set a price. required: 0 < assets.length == requestedPriceMantissas.length
      * @param requestedPriceMantissas requested new prices for the assets, scaled by 10**18. required: 0 < assets.length == requestedPriceMantissas.length
      * @return uint values in same order as inputs. For each: 0=success, otherwise a failure (see enum OracleError for details)
      */
    function setPrices(address[] memory assets, uint[] memory requestedPriceMantissas) public returns (uint[] memory) {
        uint numAssets = assets.length;
        uint numPrices = requestedPriceMantissas.length;
        uint[] memory result;

        // Fail when msg.sender is not poster
        if (msg.sender != poster) {
            result = new uint[](1);
            result[0] = failOracle(address(0), OracleError.UNAUTHORIZED, OracleFailureInfo.SET_PRICE_PERMISSION_CHECK);
            return result;
        }

        if ((numAssets == 0) || (numPrices != numAssets)) {
            result = new uint[](1);
            result[0] = failOracle(address(0), OracleError.FAILED_TO_SET_PRICE, OracleFailureInfo.SET_PRICES_PARAM_VALIDATION);
            return result;
        }

        result = new uint[](numAssets);

        for (uint i = 0; i < numAssets; i++) {
            result[i] = setPriceInternal(assets[i], requestedPriceMantissas[i]);
        }

        return result;
    }
}