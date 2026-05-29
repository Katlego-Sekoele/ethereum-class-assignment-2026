// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PNPToken.sol";
import "./FNBToken.sol";

contract OrderBook {
    using SafeERC20 for IERC20;

    enum Side { Buy, Sell }

    // represents an order in the orderbook
    struct Order {
        address owner;
        Side side;
        uint256 amount;
        uint256 remaining;
        uint256 price;
        bool isOpen;
    }

    // next order to execute in the orderbook
    uint256 nextOrderId = 0;

    // orderId to Order mapping
    mapping(uint256 => Order) orders;

    IERC20 immutable baseToken; // base asset (the asset being traded)
    IERC20 immutable quoteToken; // quote asset (the "currency" being used)

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed user,
        Side side,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 price
    );

    event OrderMatched(
        uint256 buyOrderId, 
        uint256 sellOrderId, 
        uint256 fillAmount
    );

    event OrderCanceled(
        uint256 indexed orderId, 
        address indexed user
    );

    error InvalidAmount();

    error InvalidPrice();

    error PriceMismatch();

    error UnauthorizedCancellation();

    error InvalidTokenAddress();

    error OrderAlreadyClosed();

    error IncorrectOrderSide();

    constructor(address _tokenA, address _tokenB) {
        if (_tokenA == address(0)) revert InvalidTokenAddress();
        if (_tokenB == address(0)) revert InvalidTokenAddress();

        baseToken = IERC20(_tokenA);
        quoteToken = IERC20(_tokenB);
    }

    modifier requireValidAmount(uint256 amount) {
        if (amount <= 0) revert InvalidAmount();
        _;
    }

    modifier requireValidPrice(uint256 price) {
        if (price <= 0) revert InvalidPrice();
        _;
    }

    // places a buy order
    function placeBuyOrder(uint256 amount, uint256 price) external requireValidAmount(amount) requireValidPrice(price) returns (uint256 orderId) {
        uint256 cost = amount * price;
        quoteToken.transferFrom(msg.sender, address(this), cost);
        
        orderId = nextOrderId;
        orders[orderId] = Order({
            owner: msg.sender,
            side: Side.Buy,
            amount: amount,
            remaining: amount,
            price: price,
            isOpen: true
        });


        emit OrderPlaced(
            orderId,
            msg.sender,
            Side.Buy,
            address(quoteToken),
            address(baseToken),
            amount,
            price
        );

        nextOrderId++;
        return orderId;
    }

    // places a sell order
    function placeSellOrder(uint256 amount, uint256 price) external requireValidAmount(amount) requireValidPrice(price) returns (uint256 orderId) {
        baseToken.transferFrom(msg.sender, address(this), amount);
        
        orderId = nextOrderId;
        orders[orderId] = Order({
            owner: msg.sender,
            side: Side.Sell,
            amount: amount,
            remaining: amount,
            price: price,
            isOpen: true
        });


        emit OrderPlaced(
            orderId,
            msg.sender,
            Side.Sell,
            address(baseToken),
            address(quoteToken),
            amount,
            price
        );

        nextOrderId++;
        return orderId;
    }

    modifier requireOpenOrder(uint256 orderId) {
        if (!orders[orderId].isOpen) revert OrderAlreadyClosed();
        _;
    }

    modifier requirePricesMatch(uint256 buyOrderId, uint256 sellOrderId) {
        if (orders[buyOrderId].price != orders[sellOrderId].price) revert PriceMismatch();
        _;
    }

    modifier requireCorrectSide(uint256 buyOrderId, uint256 sellOrderId) {
        if (orders[buyOrderId].side != Side.Buy) revert IncorrectOrderSide();
        if (orders[sellOrderId].side != Side.Sell) revert IncorrectOrderSide();
        _;
    }

    // matches a buy and sell orders and settles the transfers
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) 
        external 
        requireOpenOrder(buyOrderId) 
        requireOpenOrder(sellOrderId) 
        requirePricesMatch(buyOrderId, sellOrderId) 
        requireCorrectSide(buyOrderId, sellOrderId) 
    {
        Order memory buyOrder = orders[buyOrderId];
        Order memory sellOrder = orders[sellOrderId];

        uint256 fillAmount = min(buyOrder.remaining, sellOrder.remaining);
        uint256 quotePayment = fillAmount * buyOrder.price;

        // settlement
        baseToken.safeTransfer(buyOrder.owner, fillAmount);
        quoteToken.safeTransfer(sellOrder.owner, quotePayment);

        // state update
        sellOrder.remaining -= fillAmount;
        buyOrder.remaining -= fillAmount;

        if (sellOrder.remaining == 0) {
            sellOrder.isOpen = false;
        }

        if (buyOrder.remaining == 0) {
            buyOrder.isOpen = false;
        }

        orders[buyOrderId] = buyOrder;
        orders[sellOrderId] = sellOrder;

        emit OrderMatched(buyOrderId, sellOrderId, fillAmount);
    }

    modifier requireOwnerForCancellation(uint256 orderId, address msgSender) {
        if (orders[orderId].owner != msgSender) revert UnauthorizedCancellation();
        _;
    }

    // cancels an order by closing it and setting the remaining amount to 0
    function cancelOrder(uint256 orderId) external requireOpenOrder(orderId) requireOwnerForCancellation(orderId, msg.sender) {
        Order memory order = orders[orderId];

        if (order.side == Side.Buy) {
            quoteToken.safeTransfer(msg.sender, order.remaining * order.price);
        } else {
            baseToken.safeTransfer(msg.sender, order.remaining);
        }
                
        order.remaining = 0;
        order.isOpen = false;

        orders[orderId] = order;
        emit OrderCanceled(orderId, msg.sender);
    }

    // returns the balance on an order
    function remaining(uint256 orderId) external view returns (uint256) {
        return orders[orderId].remaining;
    }

    // returns whether or not an order is still open
    function isOpen(uint256 orderId) external view returns (bool) {
        return orders[orderId].isOpen;
    }

    // min of two ints
    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }
}
