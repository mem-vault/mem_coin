module mem_coin::swap {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::event;
    use mem_coin::mem_coin::MEM_COIN;

    // Error constants
    // const EInvalidCap: u64 = 0;
    const EPoolUnderflow: u64 = 1;
    const ESlippageExceeded: u64 = 2;
    const EUnauthorized: u64 = 3;
    const EZeroAmount: u64 = 4;
    const EReservesEmpty: u64 = 5;

    // Fee constants
    const SWAP_FEE_BPS: u64 = 30;  // 0.3% swap fee
    const ADMIN_FEE_BPS: u64 = 10;  // 0.1% admin fee (1/3 of total fee)
    const BPS_DENOMINATOR: u64 = 10000;  // 10000 = 100%

    // Liquidity Pool structure
    public struct LiquidityPool has key {
        id: UID,
        owner: address,
        pool_sui: Balance<SUI>,
        pool_mem: Balance<MEM_COIN>,
        admin_sui_fees: Balance<SUI>,
        admin_mem_fees: Balance<MEM_COIN>,
    }

    // Events
    public struct PoolCreatedEvent has copy, drop, store {
        owner: address,
        pool_id: ID,
    }

    public struct SwapMemForSuiEvent has copy, drop, store {
        user: address,
        pool_id: ID,
        memecoin_in: u64,
        sui_out: u64,
    }

    public struct SwapSuiForMemEvent has copy, drop, store {
        user: address,
        pool_id: ID,
        sui_in: u64,
        memecoin_out: u64,
    }

    // Create a new liquidity pool
    public entry fun create_pool(
        initial_sui: Coin<SUI>,
        initial_mem: Coin<MEM_COIN>,
        ctx: &mut TxContext
    ) {
        let pool = LiquidityPool {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            pool_sui: coin::into_balance(initial_sui),
            pool_mem: coin::into_balance(initial_mem),
            admin_sui_fees: balance::zero<SUI>(),
            admin_mem_fees: balance::zero<MEM_COIN>(),
        };

        event::emit(PoolCreatedEvent {
            owner: tx_context::sender(ctx),
            pool_id: object::id(&pool),
        });

        transfer::share_object(pool);
    }

    // Swap SUI for MEM_COIN
    public fun swap_sui_for_mem(
        pool: &mut LiquidityPool,
        input_sui: Coin<SUI>,
        min_expected_mem: u64,
        ctx: &mut TxContext
    ): Coin<MEM_COIN> {
        let dx = coin::value(&input_sui);
        assert!(dx > 0, EZeroAmount);

        let x = balance::value(&pool.pool_sui);
        let y = balance::value(&pool.pool_mem);
        assert!(x > 0 && y > 0, EReservesEmpty);

        // Calculate output amount using constant product formula
        let dy_raw = y * dx / (x + dx);
        
        // Calculate and split fees
        let total_fee = dy_raw * SWAP_FEE_BPS / BPS_DENOMINATOR;
        let admin_fee = total_fee * ADMIN_FEE_BPS / SWAP_FEE_BPS;
        let dy = dy_raw - total_fee;

        assert!(dy >= min_expected_mem, ESlippageExceeded);
        assert!(y >= dy + admin_fee, EPoolUnderflow);

        balance::join(&mut pool.pool_sui, coin::into_balance(input_sui));

        let output = balance::split(&mut pool.pool_mem, dy);
        if (admin_fee > 0) {
            let admin_balance = balance::split(&mut pool.pool_mem, admin_fee);
            balance::join(&mut pool.admin_mem_fees, admin_balance);
        };

        event::emit(SwapSuiForMemEvent {
            user: tx_context::sender(ctx),
            pool_id: object::id(pool),
            sui_in: dx,
            memecoin_out: dy
        });

        coin::from_balance(output, ctx)
    }

    // Swap MEM_COIN for SUI
    public fun swap_mem_for_sui(
        pool: &mut LiquidityPool,
        input_mem: Coin<MEM_COIN>,
        min_expected_sui: u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let dy = coin::value(&input_mem);
        assert!(dy > 0, EZeroAmount);

        let x = balance::value(&pool.pool_sui);
        let y = balance::value(&pool.pool_mem);
        assert!(x > 0 && y > 0, EReservesEmpty);

        // Calculate output amount using constant product formula
        let dx_raw = x * dy / (y + dy);
        
        // Calculate and split fees
        let total_fee = dx_raw * SWAP_FEE_BPS / BPS_DENOMINATOR;
        let admin_fee = total_fee * ADMIN_FEE_BPS / SWAP_FEE_BPS;
        let dx = dx_raw - total_fee;

        assert!(dx >= min_expected_sui, ESlippageExceeded);
        assert!(x >= dx + admin_fee, EPoolUnderflow);

        balance::join(&mut pool.pool_mem, coin::into_balance(input_mem));

        let output = balance::split(&mut pool.pool_sui, dx);
        if (admin_fee > 0) {
            let admin_balance = balance::split(&mut pool.pool_sui, admin_fee);
            balance::join(&mut pool.admin_sui_fees, admin_balance);
        };

        event::emit(SwapMemForSuiEvent {
            user: tx_context::sender(ctx),
            pool_id: object::id(pool),
            memecoin_in: dy,
            sui_out: dx
        });

        coin::from_balance(output, ctx)
    }

    // Admin functions to withdraw fees
    public fun admin_withdraw_sui_fees(
        pool: &mut LiquidityPool,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(tx_context::sender(ctx) == pool.owner, EUnauthorized);
        let output = balance::split(&mut pool.admin_sui_fees, amount);
        coin::from_balance(output, ctx)
    }

    public fun admin_withdraw_mem_fees(
        pool: &mut LiquidityPool,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<MEM_COIN> {
        assert!(tx_context::sender(ctx) == pool.owner, EUnauthorized);
        let output = balance::split(&mut pool.admin_mem_fees, amount);
        coin::from_balance(output, ctx)
    }

    // Utility functions to get pool information
    public fun get_pool_sui_balance(pool: &LiquidityPool): u64 {
        balance::value(&pool.pool_sui)
    }

    public fun get_pool_mem_balance(pool: &LiquidityPool): u64 {
        balance::value(&pool.pool_mem)
    }

    public fun get_pool_balances(pool: &LiquidityPool): (u64, u64) {
        (balance::value(&pool.pool_sui), balance::value(&pool.pool_mem))
    }

    // Entry functions for easier interaction
    public entry fun swap_sui_for_mem_entry(
        pool: &mut LiquidityPool,
        input_sui: Coin<SUI>,
        min_expected_mem: u64,
        ctx: &mut TxContext
    ) {
        let mem_coin = swap_sui_for_mem(pool, input_sui, min_expected_mem, ctx);
        transfer::public_transfer(mem_coin, tx_context::sender(ctx));
    }

    public entry fun swap_mem_for_sui_entry(
        pool: &mut LiquidityPool,
        input_mem: Coin<MEM_COIN>,
        min_expected_sui: u64,
        ctx: &mut TxContext
    ) {
        let sui_coin = swap_mem_for_sui(pool, input_mem, min_expected_sui, ctx);
        transfer::public_transfer(sui_coin, tx_context::sender(ctx));
    }

    public entry fun admin_withdraw_sui_fees_entry(
        pool: &mut LiquidityPool,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let sui_coin = admin_withdraw_sui_fees(pool, amount, ctx);
        transfer::public_transfer(sui_coin, tx_context::sender(ctx));
    }

    public entry fun admin_withdraw_mem_fees_entry(
        pool: &mut LiquidityPool,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let mem_coin = admin_withdraw_mem_fees(pool, amount, ctx);
        transfer::public_transfer(mem_coin, tx_context::sender(ctx));
    }
}