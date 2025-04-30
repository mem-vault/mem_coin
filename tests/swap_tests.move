// SPDX-License-Identifier: Apache-2.0

#[test_only]
#[allow(duplicate_alias, unused_use, unused_const, unused_mut_ref, unused_variable)]
module mem_coin::swap_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::test_utils::assert_eq;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;
    use sui::balance;
    use sui::object::{Self, ID};
    use sui::transfer;
    use sui::tx_context;
    use std::option;
    
    use mem_coin::mem_coin::{Self, MEM_COIN};
    use mem_coin::swap::{Self, LiquidityPool};
    
    // Test addresses
    const ADMIN: address = @0xA1;
    const USER1: address = @0xB1;
    const USER2: address = @0xC1;
    
    // Test constants
    const INITIAL_SUI_AMOUNT: u64 = 1_000_000_000; // 1000 SUI
    const INITIAL_MEM_AMOUNT: u64 = 1_000_000_000; // 1000 MEM
    const SWAP_AMOUNT: u64 = 10_000_000; // 10 SUI/MEM
    
    // Error constants from the swap module
    const EPoolUnderflow: u64 = 1;
    const ESlippageExceeded: u64 = 2;
    const EUnauthorized: u64 = 3;
    const EZeroAmount: u64 = 4;
    const EReservesEmpty: u64 = 5;
    
    // Helper function to create a test pool
    fun create_test_pool(scenario: &mut Scenario): ID {
        let pool_id: ID;
        
        // First transaction: Admin creates the pool
        ts::next_tx(scenario, ADMIN);
        {
            // Create treasury cap for minting MEM_COIN
            let ctx = ts::ctx(scenario);
            
            // Mint SUI for pool creation
            let sui_coin = coin::mint_for_testing<SUI>(INITIAL_SUI_AMOUNT, ctx);
            
            // Create MEM_COIN and get treasury cap
            let (mut treasury_cap, metadata) = mem_coin::init_for_testing(ctx);
            
            // Transfer metadata to avoid unused value error
            transfer::public_transfer(metadata, ADMIN);
            
            // Mint MEM_COIN for pool creation
            let mem_coin = coin::mint(&mut treasury_cap, INITIAL_MEM_AMOUNT, ctx);
            
            // Create the pool
            swap::create_pool(sui_coin, mem_coin, ctx);
            
            // Return treasury cap to admin for later use
            transfer::public_transfer(treasury_cap, ADMIN);
        };
        
        // Second transaction: Get the pool ID
        ts::next_tx(scenario, ADMIN);
        {
            // Get the pool ID (we'll need to take the shared object to get its ID)
            let pool = ts::take_shared<LiquidityPool>(scenario);
            pool_id = object::id(&pool);
            ts::return_shared(pool);
        };
        
        pool_id
    }
    
    // Helper function to mint MEM_COIN
    fun mint_mem_coin(scenario: &mut Scenario, amount: u64, recipient: address) {
        ts::next_tx(scenario, ADMIN);
        {
            let mut treasury_cap = ts::take_from_sender<TreasuryCap<MEM_COIN>>(scenario);
            let ctx = ts::ctx(scenario);
            
            mem_coin::mint(&mut treasury_cap, amount, recipient, ctx);
            
            ts::return_to_sender(scenario, treasury_cap);
        };
    }
    
    // Helper function to mint SUI
    fun mint_sui(scenario: &mut Scenario, amount: u64, recipient: address): Coin<SUI> {
        ts::next_tx(scenario, recipient);
        let ctx = ts::ctx(scenario);
        coin::mint_for_testing<SUI>(amount, ctx)
    }
    
    #[test]
    fun test_create_pool() {
        let mut scenario = ts::begin(ADMIN);
        {
            let pool_id = create_test_pool(&mut scenario);
            
            // Verify the pool was created with correct balances
            ts::next_tx(&mut scenario, ADMIN);
            {
                let pool = ts::take_shared<LiquidityPool>(&scenario);
                assert_eq(object::id(&pool), pool_id);
                assert_eq(swap::get_pool_sui_balance(&pool), INITIAL_SUI_AMOUNT);
                assert_eq(swap::get_pool_mem_balance(&pool), INITIAL_MEM_AMOUNT);                

                let (sui_balance, mem_balance) = swap::get_pool_balances(&pool);
                assert_eq(sui_balance, INITIAL_SUI_AMOUNT);
                assert_eq(mem_balance, INITIAL_MEM_AMOUNT);
                
                ts::return_shared(pool);
            };
        };
        ts::end(scenario);
    }
    
    #[test]
    fun test_swap_sui_for_mem() {
        let mut scenario = ts::begin(ADMIN);
        {
            let _pool_id = create_test_pool(&mut scenario);
            
            // USER1 swaps SUI for MEM
            ts::next_tx(&mut scenario, USER1);
            {
                let mut pool = ts::take_shared<LiquidityPool>(&scenario);
                let sui_coin = mint_sui(&mut scenario, SWAP_AMOUNT, USER1);
                let ctx = ts::ctx(&mut scenario);
                
                // Calculate expected output based on constant product formula
                let (sui_balance, mem_balance) = swap::get_pool_balances(&pool);
                let expected_output_raw = mem_balance * SWAP_AMOUNT / (sui_balance + SWAP_AMOUNT);
                let total_fee = expected_output_raw * 30 / 10000; // 0.3% fee
                let expected_output = expected_output_raw - total_fee;
                
                // Set min expected to slightly less than calculated to account for rounding
                let min_expected = expected_output * 99 / 100; // 99% of expected
                
                let mem_coin = swap::swap_sui_for_mem(&mut pool, sui_coin, min_expected, ctx);
                
                // Verify the output amount is as expected
                assert_eq(coin::value(&mem_coin), expected_output);
                
                // Verify pool balances were updated correctly
                assert_eq(swap::get_pool_sui_balance(&pool), INITIAL_SUI_AMOUNT + SWAP_AMOUNT);
                assert_eq(swap::get_pool_mem_balance(&pool), INITIAL_MEM_AMOUNT - expected_output - (total_fee * 10 / 30)); // Subtract output and admin fee
                
                transfer::public_transfer(mem_coin, USER1);
                ts::return_shared(pool);
            };
        };
        ts::end(scenario);
    }
    
    #[test]
    fun test_swap_mem_for_sui() {
        let mut scenario = ts::begin(ADMIN);
        {
            let _pool_id = create_test_pool(&mut scenario);
            
            // Mint MEM_COIN for USER2
            mint_mem_coin(&mut scenario, SWAP_AMOUNT, USER2);
            
            // USER2 swaps MEM for SUI
            ts::next_tx(&mut scenario, USER2);
            {
                let mut pool = ts::take_shared<LiquidityPool>(&scenario);
                let mem_coin = ts::take_from_sender<Coin<MEM_COIN>>(&scenario);
                let ctx = ts::ctx(&mut scenario);  // Changed from &scenario to &mut scenario
                
                // Calculate expected output based on constant product formula
                let (sui_balance, mem_balance) = swap::get_pool_balances(&pool);
                let expected_output_raw = sui_balance * SWAP_AMOUNT / (mem_balance + SWAP_AMOUNT);
                let total_fee = expected_output_raw * 30 / 10000; // 0.3% fee
                let expected_output = expected_output_raw - total_fee;
                
                // Set min expected to slightly less than calculated to account for rounding
                let min_expected = expected_output * 99 / 100; // 99% of expected
                
                let sui_coin = swap::swap_mem_for_sui(&mut pool, mem_coin, min_expected, ctx);
                
                // Verify the output amount is as expected
                assert_eq(coin::value(&sui_coin), expected_output);
                
                // Verify pool balances were updated correctly
                assert_eq(swap::get_pool_mem_balance(&pool), INITIAL_MEM_AMOUNT + SWAP_AMOUNT);
                assert_eq(swap::get_pool_sui_balance(&pool), INITIAL_SUI_AMOUNT - expected_output - (total_fee * 10 / 30)); // Subtract output and admin fee
                
                transfer::public_transfer(sui_coin, USER2);
                ts::return_shared(pool);
            };
        };
        ts::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = ESlippageExceeded, location = swap)]
    fun test_swap_slippage_protection() {
        let mut scenario = ts::begin(ADMIN);
        {
            let _pool_id = create_test_pool(&mut scenario);
            
            // USER1 swaps SUI for MEM with unrealistic slippage protection
            ts::next_tx(&mut scenario, USER1);
            {
                let mut pool = ts::take_shared<LiquidityPool>(&scenario);
                let sui_coin = mint_sui(&mut scenario, SWAP_AMOUNT, USER1);
                let ctx = ts::ctx(&mut scenario);  // Changed from &scenario to &mut scenario
                
                // Set unrealistically high min expected output to trigger slippage protection
                let unrealistic_min_expected = SWAP_AMOUNT * 2; // No way to get 2x out
                
                let mem_coin = swap::swap_sui_for_mem(&mut pool, sui_coin, unrealistic_min_expected, ctx);
                
                transfer::public_transfer(mem_coin, USER1);
                ts::return_shared(pool);
            };
        };
        ts::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = EZeroAmount, location = swap)]
    fun test_swap_zero_amount() {
        let mut scenario = ts::begin(ADMIN);
        {
            let _pool_id = create_test_pool(&mut scenario);
            
            // USER1 tries to swap 0 SUI
            ts::next_tx(&mut scenario, USER1);
            {
                let mut pool = ts::take_shared<LiquidityPool>(&scenario);
                let sui_coin = mint_sui(&mut scenario, 0, USER1);
                let ctx = ts::ctx(&mut scenario);  // Changed from &scenario to &mut scenario
                
                let mem_coin = swap::swap_sui_for_mem(&mut pool, sui_coin, 0, ctx);
                
                transfer::public_transfer(mem_coin, USER1);
                ts::return_shared(pool);
            };
        };
        ts::end(scenario);
    }
    
    #[test]
    fun test_admin_fee_withdrawal() {
        let mut scenario = ts::begin(ADMIN);
        {
            let _pool_id = create_test_pool(&mut scenario);
            
            // First, do a swap to generate some fees
            ts::next_tx(&mut scenario, USER1);
            {
                let mut pool = ts::take_shared<LiquidityPool>(&mut scenario);
                let sui_coin = mint_sui(&mut scenario, SWAP_AMOUNT * 10, USER1);
                let ctx = ts::ctx(&mut scenario);  // Changed from &scenario to &mut scenario
                
                let mem_coin = swap::swap_sui_for_mem(&mut pool, sui_coin, 0, ctx);
                transfer::public_transfer(mem_coin, USER1);
                ts::return_shared(pool);
            };
            
            // Now ADMIN withdraws the MEM fees
            ts::next_tx(&mut scenario, ADMIN);
            {
                let mut pool = ts::take_shared<LiquidityPool>(&scenario);
                let ctx = ts::ctx(&mut scenario);  // Changed from &scenario to &mut scenario
                
                // Calculate expected admin fee
                let (_, mem_balance) = swap::get_pool_balances(&pool);
                let expected_output_raw = INITIAL_MEM_AMOUNT * (SWAP_AMOUNT * 10) / (INITIAL_SUI_AMOUNT + (SWAP_AMOUNT * 10));
                let total_fee = expected_output_raw * 30 / 10000; // 0.3% fee
                let admin_fee = total_fee * 10 / 30; // 1/3 of total fee goes to admin
                
                // Admin withdraws MEM fees
                let mem_fee_coin = swap::admin_withdraw_mem_fees(&mut pool, admin_fee, ctx);
                
                // Verify the withdrawn amount
                assert_eq(coin::value(&mem_fee_coin), admin_fee);
                
                transfer::public_transfer(mem_fee_coin, ADMIN);
                ts::return_shared(pool);
            };
        };
        ts::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = EUnauthorized, location = swap)]
    fun test_unauthorized_fee_withdrawal() {
        let mut scenario = ts::begin(ADMIN);
        {
            let _pool_id = create_test_pool(&mut scenario);
            
            // USER1 tries to withdraw fees (should fail)
            ts::next_tx(&mut scenario, USER1);
            {
                let mut pool = ts::take_shared<LiquidityPool>(&scenario);
                let ctx = ts::ctx(&mut scenario);  // Changed from &scenario to &mut scenario
                
                let mem_fee_coin = swap::admin_withdraw_mem_fees(&mut pool, 1000, ctx);
                
                transfer::public_transfer(mem_fee_coin, USER1);
                ts::return_shared(pool);
            };
        };
        ts::end(scenario);
    }
}