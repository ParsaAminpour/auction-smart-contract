// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {mulDiv} from "@prb-math/contracts/Common.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract Auction is Ownable, ReentrancyGuard, IERC721Receiver, Pausable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using SafeERC20 for IERC20;

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*
    /               Errors                /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    error Auction__EndTimeIsLessThanMinimumAuctionPeriodTime();
    error Auction__InvalidTokenId();
    error Auction__BidProposeIsNotGreaterThanThreshold();
    error Auction__BidProposeIsLessThanInitPrice(uint256 invalid_bid_propose);
    error Auction__AuctionIsClosed();
    error Auction__AuctionIsNotActive();
    error Auction__AuctionIsPausedByTheOwner();
    error Auction__IsNotTimedOut();
    error Auction__AuctionIsActive();
    error Auction__BidderAddressIsInvalid();
    error Auction__NoBidderAvailable();

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /           State Variables           /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    uint256 public constant DECAY_FACTOR = 2 * 1e18; // 2.0
    uint256 public constant INCREMENT_RATIO_PER_BID = 5; // 5%
    uint256 public constant PROB_CAP = 25 * 1e16;
    uint256 public constant PRECISION = 100;
    uint256 public constant PROTOCOL_INTEREST = 2 * 1e16; // 2%
    uint256 public constant EXTRA_TIME = 300; // 5 min
    uint32 public constant MINIMUM_AUCTION_TIME_PERIOD = 3600; // 1 day
    // We assume that the platform funded with reward_token before.
    IERC20 public immutable i_reward_token;
    IERC721 public immutable nft_token;
    address public immutable factory;

    event ProposalAdded(address bidder, uint256 bid_offer);
    event fallbackEmitted(address caller);
    event receiveEmitted(address caller);
    event BiddersDrawWinnerSelected(address winner);
    
    struct AuctionStructure {
        address auction_owner; // 32
        // @audit-info should be removed from struct.
        uint256 init_price; // 32 
        uint256 latest_price_offer; // 32
        address latest_offer_owner; // 32

        uint256 start_time; // 8
        uint256 end_time; // 8
        
        uint256 total_bids; // 32
        uint256 bided_tokenId; // 32
        // isActive = false has require condition of Auction time out.
        bool isActive; // 1 
    }

    AuctionStructure private auction;
    EnumerableMap.AddressToUintMap private bidders_offer;

    constructor(IERC20 _reward_token, IERC721 _nft_token, address _factory, address _owner, uint256 _init_price, uint256 _end_time)
        Ownable(msg.sender)
    {
        if (_end_time - block.timestamp < MINIMUM_AUCTION_TIME_PERIOD) {
            revert Auction__EndTimeIsLessThanMinimumAuctionPeriodTime();
        }
        i_reward_token = _reward_token;
        nft_token = _nft_token;
        factory = _factory;
        // for AuctionStructure
        auction.auction_owner = _owner;
        auction.init_price = _init_price;
        auction.end_time = _end_time;
    }

    modifier auctionIsActive() {
        if (block.timestamp > auction.end_time) revert Auction__AuctionIsClosed();
        if (!auction.isActive) revert Auction__AuctionIsNotActive();
        _;
    }
    modifier auctionIsClosed() {
        if (block.timestamp < auction.end_time || auction.isActive) {
            revert Auction__AuctionIsActive();
        }
        _;
    }
    fallback() external payable {
        emit fallbackEmitted(msg.sender);
    }
    receive() external payable {
        emit receiveEmitted(msg.sender);
    }
    /// NOTE: here the auction owner will transfer the NFT to the contract.
    /// Follows CEI.
    function startAuction(uint256 _tokenId) external onlyOwner {
        if (nft_token.ownerOf(_tokenId) != msg.sender) {
            revert Auction__InvalidTokenId();
        }
        auction.start_time = block.timestamp;
        auction.isActive = true;
        auction.bided_tokenId = _tokenId;
        nft_token.safeTransferFrom(msg.sender, address(this), _tokenId);
    }

    /// new bidder's offer is surely more than his latest bid if he's already participated.
    /// this bidder is surely participated before.
    function _addToTotalBidsOffer(address bidder, uint256 bidder_offer) internal {
        if (bidders_offer.contains(bidder)) {
            auction.total_bids += bidder_offer - bidders_offer.get(bidder);
        }
        auction.total_bids += bidder_offer;
    }

    // @audit could be vulnerable to ETH mishandling attack.
    function addBidToAuction() external payable nonReentrant auctionIsActive whenNotPaused {
        require(msg.value > 0, "Bid Propose should be more than 0");
        // avoiding in using an external call multiple times.
        uint256 bidOffer = msg.value;

        if (bidders_offer.length() == 0) {
            if (bidOffer < auction.init_price) revert Auction__BidProposeIsLessThanInitPrice(bidOffer);

            bidders_offer.set(msg.sender, bidOffer);
            auction.total_bids += bidOffer;
            
        } else {
            // Threshold should be more than latest price offer and 5% more.
            uint256 offerThreshold = auction.latest_price_offer + mulDiv(auction.latest_price_offer, INCREMENT_RATIO_PER_BID, PRECISION);
            
            if (bidOffer > offerThreshold) {
                bidders_offer.set(msg.sender, bidOffer);
                _addToTotalBidsOffer(msg.sender, bidOffer);
            } else revert Auction__BidProposeIsNotGreaterThanThreshold();

        }
        auction.latest_offer_owner = msg.sender;
        auction.latest_price_offer = bidOffer;

        if (auction.end_time - block.timestamp < EXTRA_TIME) {
            auction.end_time += EXTRA_TIME;
        }
        emit ProposalAdded(msg.sender, bidOffer);
    }

    // @audit-info transfer calcualtions in seperate functions.
    function startDraw() external nonReentrant auctionIsClosed {
        uint256 bidders_amount = bidders_offer.length();
        if (bidders_amount == 0) revert Auction__NoBidderAvailable();

        address[] memory bidders = bidders_offer.keys();
        uint256[] memory capped_probs = new uint256[](bidders_amount);
        
        uint256 total_accumulated_bids = auction.total_bids;
        (uint256 exceeded_probs, uint256 s_non_capped) = (0 ,0);
        
        for(uint256 i = 0; i < bidders_amount; i++) {
            uint256 b_i = bidders_offer.get(bidders[i]);
            uint256 prob = mulDiv(b_i, 1e18, total_accumulated_bids);
            
            if (prob > PROB_CAP) {
                capped_probs[i] = PROB_CAP;
                exceeded_probs +=  prob - PROB_CAP;
            } else {
                capped_probs[i] = prob;
                s_non_capped += prob;
            }
        }
        // Distributin capped amounts and convert them to cumulative probs simulteneously.
        uint256[] memory cumulative_probs = new uint256[](bidders_amount);
        uint256 runningTotal = 0;
        for(uint256 i = 0; i < bidders_amount; i++) {
            if (capped_probs[i] < PROB_CAP) {
                capped_probs[i] += mulDiv(capped_probs[i], exceeded_probs, s_non_capped);
            }
            runningTotal += capped_probs[i];
            cumulative_probs[i] = runningTotal;
        }
        // the vrf_number should be between 0 and 1. 
        uint256 vrf_number = _generateVRFNumber();
        address winner;
        for(uint256 i = 0; i < bidders_amount; i++) {
            if (cumulative_probs[i] >= vrf_number) {
                winner = bidders[i + 1];
                break;
            }
        }
        
        emit BiddersDrawWinnerSelected(winner);
    }

    function _generateVRFNumber() internal view returns(uint256) {}

    function withdrawAccumulatedFund() external auctionIsActive() {

    }

    /// follows CEI.
    function closeAuction() external auctionIsActive {
        if (block.timestamp < auction.end_time) revert Auction__IsNotTimedOut();
        auction.isActive = false;

        if (bidders_offer.length() == 0) revert Auction__NoBidderAvailable();
        nft_token.safeTransferFrom(address(this), auction.latest_offer_owner, auction.bided_tokenId);
    }
    function changePause() external onlyOwner() {
        paused() ? _unpause() : _pause();
    }



    // @audit this sould be handled in best practice.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) 
    external 
    returns (bytes4) 
    {
        return this.onERC721Received.selector;
    }

    function getAuctionStartTimeAndEndTime() public view returns(uint256, uint256) {
        return (auction.start_time, auction.end_time);
    }

    function getAuction() public view returns(AuctionStructure memory memAuction) {
        memAuction = auction;
    }

    function getBidderAccumulatedFund(address _bidder) public view returns(uint256) {
        // Bidder existance will be checked in the EnumerableMap::AddressToUintMap::get fucntion.
        return bidders_offer.get(_bidder);
    }
    function getBiddersCount() public view returns(uint256) {
        return bidders_offer.length();
    }
}
