pragma solidity ^0.5.16;

import "./CErc20.sol";
import "./CToken.sol";
import "./PriceOracle.sol";
import "./Exponential.sol";
import "./EIP20Interface.sol";

interface KLendPriceOracleInterface {
    function assetPrices(address asset) external view returns (uint);
}

interface AggregatorInterface {
  function latestAnswer() external view returns (int256);
  function latestTimestamp() external view returns (uint256);
  function latestRound() external view returns (uint256);
  function getAnswer(uint256 roundId) external view returns (int256);
  function getTimestamp(uint256 roundId) external view returns (uint256);

  event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 timestamp);
  event NewRound(uint256 indexed roundId, address indexed startedBy);
}

contract PriceOracleProxy is PriceOracle, Exponential {
    address public admin;

    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /// @notice The ant price oracle, which will continue to serve prices for ant assets
    KLendPriceOracleInterface public klendPriceOracle;

    /// @notice Chainlink Aggregators
    mapping(address => AggregatorInterface) public aggregators;

    address public cEthAddress;

    /**
     * @param admin_ The address of admin to set aggregators
     * @param cEthAddress_ The address of cETH, which will return a constant 1e18, since all prices relative to ether
     */
    constructor(address admin_, address cEthAddress_) public {
        admin = admin_;
        cEthAddress = cEthAddress_;
    }

    /**
     * @notice Get the underlying price of a listed cToken asset
     * @param cToken The cToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18)
     */
    function getUnderlyingPrice(CToken cToken) public view returns (uint) {
        address cTokenAddress = address(cToken);
        if (cTokenAddress == cEthAddress) {
            // ether always worth 1
            return 1e18;
        }
        AggregatorInterface aggregator = aggregators[cTokenAddress];
        if (address(aggregator) != address(0)) {
            MathError mathErr;
            Exp memory price;
            (mathErr, price) = getPriceFromChainlink(aggregator);
            if (mathErr != MathError.NO_ERROR) {
                // Fallback to v1 PriceOracle
                return getPriceFromOracle(cTokenAddress);
            }

            if (price.mantissa == 0) {
                return getPriceFromOracle(cTokenAddress);
            }

            uint underlyingDecimals;
            underlyingDecimals = EIP20Interface(CErc20(cTokenAddress).underlying()).decimals();
            (mathErr, price) = mulScalar(price, 10**(18 - underlyingDecimals));
            if (mathErr != MathError.NO_ERROR ) {
                // Fallback to v1 PriceOracle
                return getPriceFromOracle(cTokenAddress);
            }

            return price.mantissa;
        }

        return getPriceFromOracle(cTokenAddress);
    }

    function getPriceFromChainlink(AggregatorInterface aggregator) internal view returns (MathError, Exp memory) {
        int256 chainLinkPrice = aggregator.latestAnswer();
        if (chainLinkPrice <= 0) {
            return (MathError.INTEGER_OVERFLOW, Exp({mantissa: 0}));
        }
        return (MathError.NO_ERROR, Exp({mantissa: uint(chainLinkPrice)}));
    }

    function getPriceFromOracle(address cTokenAddress) internal view returns (uint) {
        address underlying = CErc20(cTokenAddress).underlying();
        uint oraclePrice = klendPriceOracle.assetPrices(underlying);
        if(oraclePrice <= 0) {
            return 0;
        }
        MathError mathErr;
        Exp memory price = Exp({mantissa: oraclePrice});
        uint underlyingDecimals;
        underlyingDecimals = EIP20Interface(underlying).decimals();
        (mathErr, price) = mulScalar(price, 10**(18 - underlyingDecimals));
        if (mathErr == MathError.NO_ERROR ) {
            return price.mantissa;
        }
        return 0;
    }

    event AggregatorUpdated(address cTokenAddress, address source);

    function _setAggregators(address[] calldata cTokenAddresses, address[] calldata sources) external {
        require(msg.sender == admin, "only the admin may set the aggregators");
        for (uint i = 0; i < cTokenAddresses.length; i++) {
            aggregators[cTokenAddresses[i]] = AggregatorInterface(sources[i]);
            emit AggregatorUpdated(cTokenAddresses[i], sources[i]);
        }
    }

    function _setPriceOracle(address oracle) external {
        require(msg.sender == admin, "only the admin may set the price oracle");
        klendPriceOracle = KLendPriceOracleInterface(oracle);
    }
}
