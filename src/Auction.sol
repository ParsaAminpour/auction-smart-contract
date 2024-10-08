// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {mulDiv} from "@prb-math/contracts/Common.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {VRFConsumerBaseV2} from "@chainlink/contracts/vrf/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {ConfirmedOwner} from "@chainlink/contracts/shared/access/ConfirmedOwner.sol";

// ____  _             _ _        _              _   _             
// |  _ \| | __ _ _ __ (_) |_     / \  _   _  ___| |_(_) ___  _ __  
// | |_) | |/ _` | '_ \| | __|   / _ \| | | |/ __| __| |/ _ \| '_ \ 
// |  __/| | (_| | | | | | |_   / ___ \ |_| | (__| |_| | (_) | | | |
// |_|   |_|\__,_|_| |_|_|\__| /_/   \_\__,_|\___|\__|_|\___/|_| |_|
/// @title Auction
/// @author Parsa Aminpour (https://github.com/ParsaAminpour)
/// @notice This project is associated with the Planit task in the technical interview phase.
///     Since the scope of the task is larger than what can be completed in almost 3 days, some sections
///     of this contract are not finished. I have made my best effort to implement the functionalities based on the task form document
///     to demonstrate my ability to handle mathematical functions with constraints in Ethereum smart contracts.
///     The uncompleted tasks that I would have finished with more time include:
///         - Implementing the Factory design pattern for auction contracts using `create2`.
///         - Implementing functionality to handle Chainlink subscriptions automatically instead of manually.
///         - Completing unit tests for Chainlink VRF functionalities.
///         - Implementing fuzz testing for auction functionalities.
///         - Implementing formal verification of the auction draw equations using Certora.
/// @notice Estimated time to complete this project up to this phase: `27hr 47min`
contract Auction is ReentrancyGuard, IERC721Receiver, Pausable, VRFConsumerBaseV2, ConfirmedOwner {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*
    /               Errors                /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    error Auction__EndTimeIsLessThanMinimumAuctionPeriodTime();
    error Auction__InvalidTokenId();
    error Auction__BidProposeIsNotGreaterThanThreshold();
    error Auction__BidProposeIsLessThanInitPrice(uint256 invalid_bid_propose);
    error Auction__AuctionIsClosed();
    error Auction__AuctionIsNotActive();
    error Auction__IsNotTimedOut();
    error Auction__AuctionIsActive();
    error Auction__CallerIsNotEligibleToWithdraw();
    error Auction__CallerIsNotTheAuctionOwner();
    error Auction__VRFCoordinatorNumberIsNotFulfilled();
    error Auction__DrawIsNotCompeltedYet();
    error Auction__AuctionAlreadyStarted();
    error Auction__NoOfferClaimedToWithdraw();

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /           State Variables           /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    uint256 public constant INCREMENT_RATIO_PER_BID = 5; // 5%
    uint256 public constant PROB_CAP = 25 * 1e16;
    uint256 public constant PERCENT_RATIO = 100;
    uint256 public constant EXTRA_TIME = 300; // 5 min
    uint32 public constant MINIMUM_AUCTION_TIME_PERIOD = 3600; // 1 day

    bytes32 public constant keyHash = 0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c;
    uint32 public constant callbackGasLimit = 100000;
    uint16 public constant requestConfirmations = 3;
    uint32 public constant numWords = 2;

    // We assume that the platform funded with reward_token before.
    IERC20 public immutable i_reward_token;
    IERC721 public immutable i_nft_token;
    address public immutable i_factory;
    uint64 public immutable i_subscriptionId;

    uint256 internal lastRequestId;
    mapping(uint256 => RequestStatus) internal s_requests; /* requestId --> requestStatus */

    struct AuctionStructure {
        address auction_owner;
        uint256 init_price;
        uint256 latest_price_offer;
        address latest_offer_owner;
        uint256 start_time;
        uint256 end_time;
        uint256 total_bids;
        uint256 bided_tokenId;
        bool isActive;
        bool isDrew;
    }

    struct RequestStatus {
        bool fulfilled;
        bool exists;
        uint256[] randomWords;
    }

    VRFCoordinatorV2Interface COORDINATOR;
    AuctionStructure private auction;
    EnumerableMap.AddressToUintMap private bidders_offer;

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /             Events                  /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    event withdrawSucceeded(address indexed from, address indexed to, uint256 indexed amount, bytes data);
    event ProposalAdded(address bidder, uint256 bid_offer);
    event AuctionClosed();
    event fallbackEmitted(address caller);
    event receiveEmitted(address caller);
    event BiddersDrawWinnerSelected(address winner);
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);



    /// @notice Will call by AuctionFactory
    /// @dev I didn't implement Chainlink subscription in the contract and assume that _subs_owner is the subscription owner and paid the fee before.
    ///  implementing this is out of this challenge death time.
    /// @param _reward_token is the token associated to this contract to pay the prize to the draw result.
    /// @param _nft_token is the nft token associated to this Auction paid by Auction owner in startAuction.
    /// @param _factory the factory contract the deployed this Auction via create2
    /// @param _subs_owner the owner of this platform which paid the Chainlink supsciption to handle VRF numbers.
    /// @param _owner is the Auction owner.
    /// @param _init_price the initial price for auctioned NFT token.
    /// @param _end_time Auction death time.
    /// @param _sub_consumer_id is chainlink subscription id after purchasing subscription mannualy.
    // @audit-info subscription should be handled in contract code-base not mannualy, but it ignored cuz of the project's restricted time. 
    constructor(
        IERC20 _reward_token,
        IERC721 _nft_token,
        address _factory,
        address _subs_owner,
        address _owner,
        uint256 _init_price,
        uint256 _end_time,
        uint64 _sub_consumer_id
    )
        VRFConsumerBaseV2(0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625) // for ETH sepolia test network
        ConfirmedOwner(_subs_owner)
    {
        if (_end_time - block.timestamp < MINIMUM_AUCTION_TIME_PERIOD) {
            revert Auction__EndTimeIsLessThanMinimumAuctionPeriodTime();
        }

        COORDINATOR = VRFCoordinatorV2Interface(0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625);

        i_reward_token = _reward_token;
        i_nft_token = _nft_token;
        i_factory = _factory;
        i_subscriptionId = _sub_consumer_id;

        // for AuctionStructure
        auction.auction_owner = _owner;
        auction.init_price = _init_price;
        auction.end_time = _end_time;
    }

    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /             Modifiers               /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
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

    modifier drawCompleted() {
        if (!auction.isDrew) revert Auction__DrawIsNotCompeltedYet();
        _;
    }

    modifier onlyAuctionOwner() {
        if (auction.auction_owner != msg.sender) revert Auction__CallerIsNotTheAuctionOwner();
        _;
    }


    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /         External Functions          /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    /// @notice For starting auction, auction owner has to call this function to make auction useable after deploying the contract.
    /// @param _tokenId auction owner's NFT token id
    /// Follows CEI.
    function startAuction(uint256 _tokenId) external onlyAuctionOwner {
        if (auction.isActive) revert Auction__AuctionAlreadyStarted();
        if (i_nft_token.ownerOf(_tokenId) != msg.sender) {
            revert Auction__InvalidTokenId();
        }
        auction.start_time = block.timestamp;
        auction.isActive = true;
        auction.bided_tokenId = _tokenId;

        i_nft_token.safeTransferFrom(msg.sender, address(this), _tokenId);
    }


    /// @notice bidder has to send 5% more than the latest price offer for the ERC721 token.
    ///     if bidder has already participated he should send (his_new_offer - his_last_offer) which
    ///     his accumulated fund should be greater than (1.05 * latest_price_offer) to be acceptable.
    // @audit could be vulnerable to ETH mishandling attack.
    function addBidToAuction() external payable nonReentrant auctionIsActive whenNotPaused {
        require(msg.value > 0, "Bid Propose should be more than 0");
        // avoiding in using an external call multiple times.
        // msg.value can be less than lastest_offer because the participant deposited a portion of his new offer before.
        uint256 fund_received = msg.value;

        // The beggining of the Auction.
        if (bidders_offer.length() == 0) {
            if (fund_received < auction.init_price) revert Auction__BidProposeIsLessThanInitPrice(fund_received);

            bidders_offer.set(msg.sender, fund_received);
            auction.latest_price_offer = fund_received;
        } else {
            uint256 offerThreshold =
                auction.latest_price_offer + mulDiv(auction.latest_price_offer, INCREMENT_RATIO_PER_BID, PERCENT_RATIO);

            (bool bidder_exist, uint256 bidder_last_offer) = bidders_offer.tryGet(msg.sender);

            // Most of times msg.sender has alrdy participated before in auctions, due to that we put bidder_exist:true condition first to avoid unecessary checks.
            if (
                (bidder_exist && (bidder_last_offer + fund_received < offerThreshold))
                    || (!bidder_exist && (fund_received < offerThreshold))
            ) revert Auction__BidProposeIsNotGreaterThanThreshold();

            if (bidder_exist) {
                uint256 new_offer = bidder_last_offer + fund_received;
                bidders_offer.set(msg.sender, new_offer); // replace the new_offer value.
                auction.latest_price_offer = new_offer;
            } else {
                bidders_offer.set(msg.sender, fund_received); // Add new bidder's offer value.
                auction.latest_price_offer = fund_received;
            }
        }

        // this scope means that bidders proposal was accesptable and added to the Set data.
        auction.total_bids += fund_received;
        auction.latest_offer_owner = msg.sender;

        if (auction.end_time - block.timestamp < EXTRA_TIME) {
            auction.end_time += EXTRA_TIME;
        }
        emit ProposalAdded(msg.sender, fund_received);
    }


    /// @notice performing a draw among the bidders based on their accumulated funds inside the contract.
    /// @notice for more details about the calculations step by step please visit: 
    ///     https://github.com/ParsaAminpour/auction-smart-contract/blob/main/calculation.ipynb
    function startDraw() external nonReentrant onlyOwner auctionIsClosed {
        uint256 bidders_amount = bidders_offer.length();
        address winner;

        if (bidders_amount > 2) {

            address[] memory bidders = bidders_offer.keys();
            uint256[] memory capped_probs = new uint256[](bidders_amount);

            uint256 total_accumulated_bids = auction.total_bids;
            (uint256 exceeded_probs, uint256 s_non_capped) = (0, 0);

            for (uint256 i = 0; i < bidders_amount; i++) {
                uint256 b_i = bidders_offer.get(bidders[i]);
                uint256 prob = mulDiv(b_i, 1e18, total_accumulated_bids);

                if (prob > PROB_CAP) {
                    capped_probs[i] = PROB_CAP;
                    exceeded_probs += prob - PROB_CAP;
                } else {
                    capped_probs[i] = prob;
                    s_non_capped += prob;
                }
            }
            // Distributin capped amounts and convert them to cumulative probs simulteneously.
            uint256[] memory cumulative_probs = new uint256[](bidders_amount);
            uint256 runningTotal = 0;
            
            for (uint256 i = 0; i < bidders_amount; i++) {
                if (capped_probs[i] < PROB_CAP) {
                    capped_probs[i] += mulDiv(capped_probs[i], exceeded_probs, s_non_capped);
                }
                runningTotal += capped_probs[i];
                cumulative_probs[i] = runningTotal;
            }

            // the vrf_number should be between 1e17 and 1e18.
            ( ,uint256 vrf_number) = _generateVRFNumber().tryMod(1e18);
            for (uint256 i = 0; i < bidders_amount; i++) {
                if (cumulative_probs[i] >= vrf_number) {
                    winner = bidders[i + 1];
                    break;
                }
            }
        }

        auction.isDrew = true;
        emit BiddersDrawWinnerSelected(winner);
    }

    /// @notice auction owner can call this function to close the auction.
    /// @notice if no one participated at auction, the stored NFT will back to the auction owner itself.
    /// follows CEI.
    function closeAuction() external auctionIsActive onlyAuctionOwner {
        if (block.timestamp < auction.end_time) revert Auction__IsNotTimedOut();
        auction.isActive = false;

        bidders_offer.length() != 0
            ? i_nft_token.safeTransferFrom(address(this), auction.latest_offer_owner, auction.bided_tokenId)
            : i_nft_token.safeTransferFrom(address(this), auction.auction_owner, auction.bided_tokenId);
        
        emit AuctionClosed();
    }

    /// @notice The rest of bidders expect the winner can withdraw their accumulated funds from the contract.
    /// @param _data bytes32 data for transaction.
    // follows CEI
    function withdrawAccumulatedFund(bytes memory _data) external nonReentrant drawCompleted {
        address bidder = msg.sender;
        (bool bidder_exist, uint256 bidder_stored_fund) = bidders_offer.tryGet(bidder);

        if (auction.latest_offer_owner != bidder && bidder_exist) {
            bidders_offer.remove(bidder);

            (bool success, bytes memory returnedData) = bidder.call{value: bidder_stored_fund}(_data);
            if (!success && (returnedData.length != 0 || !abi.decode(returnedData, (bool)))) {
                assembly {
                    revert(add(returnedData, 32), mload(returnedData))
                }
            }
            emit withdrawSucceeded(address(this), bidder, bidder_stored_fund, _data);

        } else {
            revert Auction__CallerIsNotEligibleToWithdraw();
        }
    }

    /// @notice the Auction owner can withdraw his fund inside the contract if NFT sold to latest offer owner.
    /// @notice if there was not offer there won't be any transfer and auction owner claimed his NFT before via closeAuction.
    /// @param _data bytes32 data for transaction.
    function auctionOwnerWithdraw(bytes memory _data) external nonReentrant onlyAuctionOwner drawCompleted {
        if (auction.latest_offer_owner == address(0)) revert Auction__NoOfferClaimedToWithdraw();

        uint256 latest_offer = auction.latest_price_offer;
        (bool success, bytes memory returnedData) = msg.sender.call{value: latest_offer}(_data);
        if (!success && (returnedData.length != 0 || !abi.decode(returnedData, (bool)))) {
            assembly {
                revert(add(returnedData, 32), mload(returnedData))
            }
        }
        emit withdrawSucceeded(address(this), msg.sender, latest_offer, _data);
    }


    function changePause() external onlyAuctionOwner {
        paused() ? _unpause() : _pause();
    }


    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /         Internal Functions          /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    function _coordinatorRequestRandomWord() internal returns (uint256 requestId) {
        requestId =
            COORDINATOR.requestRandomWords(keyHash, i_subscriptionId, requestConfirmations, callbackGasLimit, numWords);
        s_requests[requestId] = RequestStatus({randomWords: new uint256[](0), exists: true, fulfilled: false});

        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    /// @inheritdoc VRFConsumerBaseV2
    /// @notice will trigger by calling VRFConsumerBaseV2::rawFulfillRandomWords (msg.sender = vrfCoordinator)
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        emit RequestFulfilled(_requestId, _randomWords);
    }

    // @audit-info the second word should be eleiminated via its configs.
    function _getRequestStatus(uint256 _requestId) internal view returns (bool fulfilled, uint256 randomWords) {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords[0]); // just one vrf number
    }

    // chainlink fucntionalities
    // geenrating and consuming the VRF should be in single trx without any storing process.
    function _generateVRFNumber() internal returns (uint256) {
        uint256 req_id = _coordinatorRequestRandomWord();
        (bool success, uint256 vrf_number) = _getRequestStatus(req_id);

        if (!success) revert Auction__VRFCoordinatorNumberIsNotFulfilled();
        return vrf_number;
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }


    /*.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*    
    /          Get Functions              /
    *.*.*.*.*.*.*.*.*.**.*.*.*.*.*.*.*.*.*/
    function getAuctionStartTimeAndEndTime() public view returns (uint256, uint256) {
        return (auction.start_time, auction.end_time);
    }

    function getAuction() public view returns (AuctionStructure memory memAuction) {
        memAuction = auction;
    }

    function getBidderAccumulatedFund(address _bidder) public view returns (uint256) {
        // Bidder existance will be checked in the EnumerableMap::AddressToUintMap::get fucntion.
        return bidders_offer.get(_bidder);
    }

    function getBiddersCount() public view returns (uint256) {
        return bidders_offer.length();
    }

    fallback() external payable {
        emit fallbackEmitted(msg.sender);
    }

    receive() external payable {
        emit receiveEmitted(msg.sender);
    }
}
