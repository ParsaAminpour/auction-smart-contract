// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Mock} from "./mocks/ERC721Mock.sol";
import {Auction} from "../src/Auction.sol";


contract AuctionTest is Test {
    // From Auction smart contract.
    uint256 public constant DECAY_FACTOR = 2 * 1e18; // 2.0
    uint256 public constant INCREMENT_RATIO_PER_BID = 5 * 1e16; // 5%
    uint256 public constant PROTOCOL_INTEREST = 2 * 1e16; // 2%
    uint32 public constant MINIMUM_AUCTION_TIME_PERIOD = 3600; // 1 day

    uint256 public constant UNIX_START_AUCTION_TIME = 1727728201; // Oct 01 2024 00:00:01

    Auction public auction;
    ERC20Mock public mock_token;
    ERC721Mock public mock_nft;
    address public factory_addr;

    // roles
    address public auction_owner;
    address public invalid_caller;
    address public first_bidder;
    address public second_bidder;
    address public third_bidder;
    address public forth_bidder;
    address public fifth_bidder;

    uint256 public init_price;
    uint256 public auction_token_prize_amount;
    function setUp() public {
        factory_addr = makeAddr("factory_addr"); // 0xF002aAa653348bBa3A37b25598d28DA99fAff0aA
        // roles
        auction_owner = makeAddr("auction_owner"); // 0xF114a6A8b3865069b48f1049c68257B44829Fe26
        invalid_caller = makeAddr("invalid_caller");
        first_bidder = makeAddr("first_bidder");
        second_bidder = makeAddr("second_bidder");
        third_bidder = makeAddr("third_bidder");
        forth_bidder = makeAddr("forth_bidder");
        fifth_bidder = makeAddr("fifth_bidder");

        init_price = 1e18; // 1 ETH
        auction_token_prize_amount = 1e17; // assume 0.1 ETH as prize

        mock_token = new ERC20Mock();
        mock_nft = new ERC721Mock();

        vm.startPrank(auction_owner);
        // 0x4881AFD14A3A467dc0A33a3A3eE7Bd52633206fd
        auction = new Auction(
            mock_token, mock_nft, factory_addr, auction_owner, init_price, UNIX_START_AUCTION_TIME + 3600
        );
        vm.stopPrank();

        // funding the ERC20 token to the Auction contract and ERC721 to the auction owner.
        vm.startPrank(auction_owner);
        mock_nft.mint(auction_owner, 0);
        vm.stopPrank();

        mock_token.mint(address(auction), auction_token_prize_amount);
        vm.deal(first_bidder, 1 ether);

        console.log("Auction Address: ", address(auction));        
        console.log("Factory Address: ", factory_addr);
        console.log("Auction Owner: ", auction_owner);
        console.log("First Bidder: ", first_bidder);
        console.log("ERC20 token: ", address(mock_token));
        console.log("mock NFT: ", address(mock_nft));
    }

    modifier AuctionStarted() {
        vm.startPrank(auction_owner);
        mock_nft.approve(address(auction), 0);

        vm.warp(UNIX_START_AUCTION_TIME);
        auction.startAuction(0);
        vm.stopPrank();
        _;
    }
    function test_initialize() public view {
        assertEq(auction.owner(), auction_owner);
    }

    function testStartAuctionWithValidCaller() public {
        vm.startPrank(auction_owner);
        mock_nft.approve(address(auction), 0);

        vm.warp(UNIX_START_AUCTION_TIME);
        auction.startAuction(0);
        vm.stopPrank();
        
        (uint256 start_time,) = auction.getAuctionStartTimeAndEndTime();
        assertEq(start_time, UNIX_START_AUCTION_TIME);
        assertTrue(auction.getAuction().isActive);
        assertEq(mock_nft.balanceOf(auction_owner), 0);
        assertEq(mock_nft.balanceOf(address(auction)), 1);
        assertEq(auction.getBiddersCount(), 0);
    }

    function testFailStartAuctionWithInvalidCaller() public {
        vm.startPrank(invalid_caller);
        vm.warp(UNIX_START_AUCTION_TIME);
        auction.startAuction(0);
        vm.stopPrank();
    }

    ////////////// AddBidToAuction //////////////
    function testAddBidAsTheFirstBidder() public AuctionStarted {
        uint256 auction_init_price = auction.getAuction().init_price;

        vm.deal(first_bidder, auction_init_price);
        vm.startPrank(first_bidder);
        vm.warp(UNIX_START_AUCTION_TIME + 300); // after 5 minuets
        
        auction.addBidToAuction{value: auction_init_price}();

        address latest_offer_owner = auction.getAuction().latest_offer_owner;
        uint256 latest_price_offer = auction.getAuction().latest_price_offer;
        uint256 stored_fund = auction.getBidderAccumulatedFund(first_bidder);
        // uint256 total_bids
        assertEq(stored_fund, auction_init_price);
        assertEq(address(auction).balance, auction_init_price);
        assertEq(first_bidder.balance, 0);
        assertEq(auction.getBiddersCount(), 1);
        assertEq(latest_offer_owner, first_bidder);
        assertEq(latest_price_offer, auction_init_price);
    }
}