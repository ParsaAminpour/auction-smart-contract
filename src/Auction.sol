// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {mulDiv} from "@prb-math/contracts/Common.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

contract Auction is Ownable, ReentrancyGuard {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using SafeERC20 for IERC20;

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*
    /               Errors                /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    error Auction__EndTimeIsLessThanMinimumAuctionPeriodTime();
    error Auction__InvalidTokenId();
    error Auction__BidProposeIsNotGreaterThanLastOne();

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /           State Variables           /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    uint256 public constant DECAY_FACTOR = 2 * 1e18; // 2.0
    uint256 public constant INCREMENT_RATIO_PER_BID = 5 * 1e16; // 5%
    uint256 public constant PROTOCOL_INTEREST = 2 * 1e16; // 2%
    uint32 public constant MINIMUM_AUCTION_TIME_PERIOD = 3600; // 1 day
    // We assume that the platform funded with reward_token before.
    IERC20 public immutable reward_token;
    IERC721 public immutable nft_token;
    address public immutable factory;
    
    struct AuctionStructure {
        address auction_owner; // 32
        uint256 init_price; // 32
        uint256 latest_price_offer; // 32
        address latest_offer_owner; // 32
        uint256 start_time; // 8
        uint256 end_time; // 8

        uint256 total_bids;
        bool completed; // 1
    }

    AuctionStructure private auction;

    EnumerableMap.AddressToUintMap private bidders_offer;
    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /              Events                 /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/


    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /         External Functions          /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    constructor(IERC20 _reward_token, IERC721 _nft_token, address _factory, address _owner, uint256 _init_price, uint32 _end_time)
        Ownable(msg.sender)
    {
        if (_end_time - block.timestamp < MINIMUM_AUCTION_TIME_PERIOD) {
            revert Auction__EndTimeIsLessThanMinimumAuctionPeriodTime();
        }
        reward_token = _reward_token;
        nft_token = _nft_token;
        factory = _factory;
        // for AuctionStructure
        auction.auction_owner = _owner;
        auction.init_price = _init_price;
        auction.end_time = _end_time;
        auction.completed = false;
    }

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /              Functions              /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    /// NOTE: here the auction owner will transfer the NFT to the contract.
    function startAuction(uint256 _tokenId) external onlyOwner {
        if (nft_token.ownerOf(_tokenId) != msg.sender) {
            revert Auction__InvalidTokenId();
        }

        auction.start_time = block.timestamp;        
        nft_token.safeTransferFrom(msg.sender, address(this), _tokenId);
    }

    function addBidToAuction(uint256 _bid_propose) external nonReentrant {
        // uint256 bidders_offer_len = bidders_offer.length();
        // if (bidders_offer_len == 0) {
        //     bidders_offer.set(msg.sender, _bid_propose);
        // } else {
        //     (, uint256 lastOffer) = bidders_offer.at(bidders_offer_len);
            
        //     if _bid_propose > lastOffer {
        //         revert Auction__BidProposeIsNotGreaterThanLastOne();
        //     } else {

        //     }
        // }
    }

    function removeActiveBid() external nonReentrant {}

    function closeAuction() external {}

    function startDraw() external nonReentrant {}

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /           get functions             /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
}
