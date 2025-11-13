//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoinDeploy} from "../../script/DecentralizedStableCoinDeploy.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoinDeploy deployer;
    DecentralizedStableCoin dsc;
    string constant NAME = "DecentralizedStableCoin";
    string constant SYMBOL = "DSC";
    uint256 constant INITIAL_SUPPY = 10000;
    uint256 constant BURN_TEST_TOKENS = 1500;
    address riki = makeAddr("user");

    event TransferBurnTokens(
        address indexed from,
        address indexed to,
        uint256 value
    );
    event TransferMintTokens(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    function setUp() public {
        deployer = new DecentralizedStableCoinDeploy();
        dsc = deployer.run();
        vm.deal(riki, 1 ether);
    }

    //NAME AND SYMBOL

    function testNameOfContractIsCorrect() public {
        assert(
            keccak256(abi.encodePacked(NAME)) ==
                keccak256(abi.encodePacked(dsc.name()))
        );
    }

    function testSymbolOfContractIsCorrect() public {
        assert(
            keccak256(abi.encodePacked(SYMBOL)) ==
                keccak256(abi.encodePacked(dsc.symbol()))
        );
    }

    function testTotalSupplyIsZero() public {
        console.log(dsc.totalSupply());
        assert(dsc.totalSupply() == 0);
    }

    //BURN

    function test_Burn_SucceedsAndUpdatesState() public mintInitialSupply {
        //ARRANGE
        // The owner is msg.sender and has INITIAL_SUPPLY tokens (from mintInitialSupply modifier/setup)
        uint256 ownerInitialBalance = dsc.balanceOf(msg.sender); // Should be INITIAL_SUPPLY
        uint256 initialTotalSupply = dsc.totalSupply(); // Should be INITIAL_SUPPLY

        // Calculate expected final values
        uint256 expectedFinalBalance = ownerInitialBalance - BURN_TEST_TOKENS;
        uint256 expectedFinalSupply = initialTotalSupply - BURN_TEST_TOKENS;

        // --- Act & Assert (Event) ---
        // 1. Expect the Transfer event (Burn is a Transfer to address(0))
        //vm.expectEmit(true, true, true, address(dsc)); // Check all indexed parameters
        //emit Transfer(msg.sender, address(0), BURN_TEST_TOKENS);

        // 2. Perform the burn action as the owner
        vm.prank(msg.sender);
        dsc.burn(BURN_TEST_TOKENS);

        // --- Assert (State) ---
        // 3. Verify the owner's balance decreased
        assertEq(
            dsc.balanceOf(msg.sender),
            expectedFinalBalance,
            "Owner's balance did not decrease correctly."
        );

        // 4. Verify the total supply decreased
        assertEq(
            dsc.totalSupply(),
            expectedFinalSupply,
            "Total supply did not decrease correctly."
        );
    }

    function testTransferEventActivatesWhenOwnerBurns()
        public
        mintInitialSupply
    {
        vm.expectEmit(true, true, false, false, address(dsc));
        emit TransferBurnTokens(
            address(msg.sender),
            address(0),
            BURN_TEST_TOKENS
        );

        vm.prank(msg.sender);
        dsc.burn(BURN_TEST_TOKENS);
    }

    function testBurnRevertsWhenCalledByNoOwner() public mintInitialSupply {
        vm.expectRevert();
        vm.prank(riki);
        dsc.burn(BURN_TEST_TOKENS);
    }

    function testBurnRevertsWhenAmountIsZero() public mintInitialSupply {
        vm.expectRevert(
            DecentralizedStableCoin
                .DecentralizedStableCoin__AmountMustBeMoreThanZero
                .selector
        );
        vm.prank(msg.sender);
        dsc.burn(0);
    }

    function testBurnRevertsIfBurnAmountIsLargerThanOwnersBalance()
        public
        mintInitialSupply
    {
        vm.expectRevert(
            DecentralizedStableCoin
                .DecentralizedStableCoin__BurnAmountExceedsBalance
                .selector
        );
        vm.prank(msg.sender);
        dsc.burn(INITIAL_SUPPY + 1);
    }

    //MINT

    function testOwnerCanMintAndOwnerBalanceIncreaseAfterMintingAndTotalSupplyIncreaseAfterMinting()
        public
    {
        //ARRANGE
        vm.startPrank(msg.sender);
        uint256 TOTAL_SUPPLY = dsc.totalSupply();
        uint256 OWNER_INITIAL_BALANCE = dsc.balanceOf(msg.sender);

        //ACT
        dsc.mint(msg.sender, 10000);

        //ASSERT
        assert(dsc.totalSupply() == INITIAL_SUPPY);
        assert(OWNER_INITIAL_BALANCE < dsc.balanceOf(msg.sender));
        assert(TOTAL_SUPPLY < dsc.totalSupply());
        vm.stopPrank();
    }

    function testTransferEventActivatesAfterMintingAndMintingFunctionReturnsTrue()
        public
    {
        //ARRANGE
        vm.expectEmit(true, true, false, false, address(dsc));
        emit TransferMintTokens(address(0), msg.sender, INITIAL_SUPPY);

        //ACT/ASSERT
        vm.prank(msg.sender);
        bool success = dsc.mint(msg.sender, INITIAL_SUPPY);
        assertEq(success, true, "Mint was not successful");
    }

    function testMintingFailsBecauseOwnerNotMinting() public {
        vm.expectRevert();
        vm.prank(riki);
        dsc.mint(riki, INITIAL_SUPPY);
    }

    function testMintingRevertsWhenRecepientAddressIsZero() public {
        vm.expectRevert(
            DecentralizedStableCoin
                .DecentralizedStableCoin__NotZeroAddress
                .selector
        );
        vm.prank(msg.sender);
        dsc.mint(address(0), INITIAL_SUPPY);
    }

    function testMintingRevertsIfAmountIsZero() public {
        vm.expectRevert(
            DecentralizedStableCoin
                .DecentralizedStableCoin__AmountMustBeMoreThanZero
                .selector
        );
        vm.prank(msg.sender);
        dsc.mint(msg.sender, 0);
    }

    function testOwnerCanTransferOwnershipToNewAddress() public {
        //ARRANGE
        address oldOwner = msg.sender;
        address newOwner = riki;

        //ACT
        vm.prank(oldOwner);
        dsc.transferOwnership(newOwner);

        //ASSERT
        assertEq(dsc.owner(), newOwner, "Owner was not updated");
    }

    function testContractRevertsWhenNotOwnerAttemptsToUpdateOwnership() public {
        vm.expectRevert();
        vm.prank(riki);
        dsc.transferOwnership(riki);
    }

    function testPreviousOwnerCannotMintOrBurnButNewOwnerCan() public {
        //ARRANGE
        address oldOwner = msg.sender;
        address newOwner = riki;

        //ACT
        vm.prank(oldOwner);
        dsc.transferOwnership(newOwner);

        //ASSERT
        vm.expectRevert();
        vm.prank(oldOwner);
        dsc.mint(oldOwner, INITIAL_SUPPY);

        vm.expectRevert();
        vm.prank(oldOwner);
        dsc.burn(INITIAL_SUPPY);

        vm.prank(newOwner);
        dsc.mint(newOwner, INITIAL_SUPPY);
        assertEq(
            dsc.balanceOf(newOwner),
            INITIAL_SUPPY,
            "New owner couldn't mint"
        );

        vm.prank(newOwner);
        dsc.burn(INITIAL_SUPPY - 1);
        assertEq(dsc.balanceOf(newOwner), 1, "New owner couldn't burn");
    }

    //MODIFIERS

    modifier mintInitialSupply() {
        vm.prank(msg.sender);
        dsc.mint(msg.sender, 10000);
        _;
    }
}
