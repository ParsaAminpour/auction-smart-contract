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
    uint256 public constant BIDDERS_OFFER_CONSTANT_DELTA = 0.2 ether;

    uint256 public constant UNIX_START_AUCTION_TIME = 1727728201; // Oct 01 2024 00:00:01

    Auction public auction; // 0x4881AFD14A3A467dc0A33a3A3eE7Bd52633206fd
    ERC20Mock public mock_token; // 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    ERC721Mock public mock_nft; // 0x2e234DAe75C793f67A35089C9d99245E1C58470b
    address public factory_addr; // 0xF002aAa653348bBa3A37b25598d28DA99fAff0aA

    event withdrawSucceeded(address indexed from, address indexed to, uint256 indexed amount, bytes data);
    event ProposalAdded(address bidder, uint256 bid_offer);
    event fallbackEmitted(address caller);
    event receiveEmitted(address caller);
    event BiddersDrawWinnerSelected(address winner);
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    // roles
    address public chainlink_subs_owner;
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
        chainlink_subs_owner = makeAddr("chainlink_subs_owner");    // 0x1385CF5FB06D4176F52aC2fcd49139441001f35e
        auction_owner = makeAddr("auction_owner");                  // 0xF114a6A8b3865069b48f1049c68257B44829Fe26
        invalid_caller = makeAddr("invalid_caller");                // 0xA1586948b867b75a6D0e0b5760A29567972e12b2
        first_bidder = makeAddr("first_bidder");                    // 0xE54D5ca0a73c907faA6739Ab69354668eEcE076F
        second_bidder = makeAddr("second_bidder");                  // 0xe1B4A5246cD70e0d8Dcb8a1409AA21bBB74610B6
        third_bidder = makeAddr("third_bidder");                    // 0xA9346B4bF6D7489D8a84A9A4A4A031a2914A3F92
        forth_bidder = makeAddr("forth_bidder");                    // 0x8E20c078053a4F0f99fcD64322B4B0a0e07b0F45
        fifth_bidder = makeAddr("fifth_bidder");                    // 0xc6E6234895eDf4c0efFA1E80DC37C84D1d0C850f

        init_price = 1e18; // 1 ETH
        auction_token_prize_amount = 1e17; // assume 0.1 ETH as prize

        mock_token = new ERC20Mock();
        mock_nft = new ERC721Mock();

        vm.startPrank(auction_owner);
        auction = new Auction(
            mock_token,
            mock_nft,
            factory_addr,
            chainlink_subs_owner,
            auction_owner,
            init_price,
            UNIX_START_AUCTION_TIME + 3600,
            1
        );
        vm.stopPrank();

        // funding the ERC20 token to the Auction contract and ERC721 to the auction owner.
        vm.startPrank(auction_owner);
        mock_nft.mint(auction_owner, 0);
        vm.stopPrank();

        mock_token.mint(address(auction), auction_token_prize_amount);
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
        assertEq(auction.owner(), chainlink_subs_owner);
        assertEq(auction.getAuction().auction_owner, auction_owner);
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
        vm.stopPrank();

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

    // @audit-info testing bidders should be dynamic to avoid repeating prev bidders participation calls. (idh time for it)
    function testAddNewBidderAsTheSecondPerson() public AuctionStarted {
        uint256 auction_init_price = auction.getAuction().init_price;

        vm.deal(first_bidder, auction_init_price);
        vm.warp(UNIX_START_AUCTION_TIME + 300); // after 5 minuets
        vm.startPrank(first_bidder);
        auction.addBidToAuction{value: auction_init_price}();
        vm.stopPrank();

        uint256 prev_end_time = auction.getAuction().end_time;
        uint256 second_bidder_offer = auction_init_price + BIDDERS_OFFER_CONSTANT_DELTA;
        vm.deal(second_bidder, second_bidder_offer);
        vm.warp(UNIX_START_AUCTION_TIME + 600); // 5 mins later

        vm.expectEmit();
        emit Auction.ProposalAdded(second_bidder, second_bidder_offer);

        vm.startPrank(second_bidder);
        auction.addBidToAuction{value: second_bidder_offer}();
        vm.stopPrank();

        // Checking lastest price offer now
        assertEq(auction.getAuction().latest_price_offer, second_bidder_offer);

        // checking latest offer owner now
        assertEq(auction.getAuction().latest_offer_owner, second_bidder);

        // checking the second bidder status in data Set.
        assertEq(auction.getBidderAccumulatedFund(second_bidder), second_bidder_offer);

        // checking total bids
        uint256 expected_total_fund = auction_init_price + second_bidder_offer;
        assertEq(auction.getAuction().total_bids, expected_total_fund);

        // checking total bids equal to contract balance (not useable in production)
        assertEq(auction.getAuction().total_bids, address(auction).balance);

        // end time should no be changed.
        assertEq(auction.getAuction().end_time, prev_end_time);
    }

    function testAddBidderAsTheThirdPersonWhichParticipatedBefore() public AuctionStarted {
        //////////// First Bidder ////////////
        uint256 auction_init_price = auction.getAuction().init_price;
        vm.deal(first_bidder, auction_init_price);
        vm.warp(UNIX_START_AUCTION_TIME + 300); // after 5 minuets
        vm.startPrank(first_bidder);
        auction.addBidToAuction{value: auction_init_price}();
        vm.stopPrank();

        //////////// Second Bidder ////////////
        uint256 second_bidder_offer = auction_init_price + BIDDERS_OFFER_CONSTANT_DELTA;
        vm.deal(second_bidder, second_bidder_offer);
        vm.warp(UNIX_START_AUCTION_TIME + 600); // 5 mins later

        vm.startPrank(second_bidder);
        auction.addBidToAuction{value: second_bidder_offer}();
        vm.stopPrank();

        //////////// First Bidder Again ////////////
        uint256 first_bidder_another_offer = BIDDERS_OFFER_CONSTANT_DELTA * 2; // init_price has payed before.
        vm.deal(first_bidder, first_bidder_another_offer);
        vm.warp(UNIX_START_AUCTION_TIME + 900); // 5 mins later

        vm.startPrank(first_bidder);
        auction.addBidToAuction{value: first_bidder_another_offer}();
        vm.stopPrank();

        // Checking lastest price offer now.
        uint256 first_offer_accumulated_offer = first_bidder_another_offer + auction_init_price;
        assertEq(auction.getAuction().latest_price_offer, first_offer_accumulated_offer);

        // checking latest offer owner now
        assertEq(auction.getAuction().latest_offer_owner, first_bidder);

        // checking the third bidder status in data Set.
        assertEq(auction.getBidderAccumulatedFund(first_bidder), first_offer_accumulated_offer);

        // checking total bids
        uint256 expected_total_fund = auction_init_price + second_bidder_offer + first_bidder_another_offer;
        assertEq(auction.getAuction().total_bids, expected_total_fund);

        // checking total bids equal to contract balance (not useable in production)
        assertEq(auction.getAuction().total_bids, address(auction).balance);

        // repetitve participant should not change the data Set length (obvs)
        assertEq(auction.getBiddersCount(), 2);
    }
}
