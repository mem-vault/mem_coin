module mem_coin::memvault_v3 {

    use std::string::String;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::event;
    // use sui::object::{Self, ID, UID};
    // use sui::tx_context::{Self, TxContext};

    const ENotEnoughHolding: u64 = 0;
    const EInvalidCap: u64 = 1;
    const EMaxSubscribers: u64 = 2;
    const EPoolUnderflow: u64 = 3;
    const ESlippageExceeded: u64 = 4;
    const EUnauthorized: u64 = 5;

    // Enhanced fee structure
    const SWAP_FEE_BPS: u64 = 30; // 0.3% swap fee
    const ADMIN_FEE_BPS: u64 = 5; // 0.05% admin fee (1/6 of total fee)
    // Remove or comment out the unused constant
    // const LP_FEE_BPS: u64 = 25; // 0.25% LP fee (5/6 of total fee)
    const BPS_DENOMINATOR: u64 = 10000; // 10000 = 100%

    // Additional error codes
    const EZeroAmount: u64 = 6;
    const EReservesEmpty: u64 = 7;

    public struct Phantom has drop {}

    public struct ServiceCreatedEvent has copy, drop, store {
        owner: address,
        service_id: ID,
        memecoin_name: String,
    }

    public struct SubscribedEvent has copy, drop, store {
        user: address,
        service_id: ID,
    }

    public struct SwapMemForSuiEvent has copy, drop, store {
        user: address,
        service_id: ID,
        memecoin_in: u64,
        sui_out: u64,
    }

    // Add admin fee balances to Service struct
    public struct Service<phantom T: store> has key {
        id: UID,
        owner: address,
        name: String,
        min_holding: u64,
        max_subscribers: u64,
        pool_sui: Balance<SUI>,
        pool_mem: Balance<T>,
        admin_sui_fees: Balance<SUI>,
        admin_mem_fees: Balance<T>,
    }

    public struct Cap has key {
        id: UID,
        service_id: ID,
    }

    public struct Subscription has key, store {
        id: UID,
        service_id: ID,
    }

    public struct SubscriptionGroup has key {
        id: UID,
        service_id: ID,
        subscriptions: vector<Subscription>,
    }

    ///////////////////////////////////////
    // === Create service and memecoin ===
    ///////////////////////////////////////

    // Update create_service to initialize admin fee balances
    public fun create_service<T: copy + drop + store>(
        treasury_cap: &mut TreasuryCap<T>,
        name: String,
        total_supply_amount: u64,
        initial_sui_liquidity: Coin<SUI>,
        max_subscribers: u64,
        ctx: &mut TxContext
    ): (Service<T>, Cap, Coin<T>) {
        assert!(max_subscribers > 0 && total_supply_amount > 0, EInvalidCap);
        let min_holding = total_supply_amount / max_subscribers;

        let minted_coins = coin::mint(treasury_cap, total_supply_amount, ctx);
        let mut minted_balance = coin::into_balance(minted_coins);

        let pool_amount = (total_supply_amount * 80) / 100;
        let pool_mem = balance::split(&mut minted_balance, pool_amount);
        let pool_sui = coin::into_balance(initial_sui_liquidity);

        let service = Service<T> {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            name,
            min_holding,
            max_subscribers,
            pool_sui,
            pool_mem,
            admin_sui_fees: balance::zero<SUI>(),
            admin_mem_fees: balance::zero<T>(),
        };

        let cap = Cap {
            id: object::new(ctx),
            service_id: object::id(&service),
        };

        event::emit(ServiceCreatedEvent {
            owner: tx_context::sender(ctx),
            service_id: object::id(&service),
            memecoin_name: service.name // Use a reference to the name in the service
        });

        (service, cap, coin::from_balance(minted_balance, ctx))
    }

    ////////////////////////////////
    // === Subscription logic ===
    ////////////////////////////////

    public fun create_subscription_group<T: store>(service: &Service<T>, ctx: &mut TxContext): SubscriptionGroup {
        SubscriptionGroup {
            id: object::new(ctx),
            service_id: object::id(service),
            subscriptions: vector::empty(),
        }
    }

    public fun subscribe<T: store>(
        service: &Service<T>,
        group: &mut SubscriptionGroup,
        user_coin: Coin<T>,
        ctx: &mut TxContext
    ): Coin<T> {
        let user_holding = coin::value(&user_coin);
        assert!(user_holding >= service.min_holding, ENotEnoughHolding);
        assert!(vector::length(&group.subscriptions) < service.max_subscribers, EMaxSubscribers);

        let sub = Subscription {
            id: object::new(ctx),
            service_id: object::id(service),
        };
        vector::push_back(&mut group.subscriptions, sub);

        event::emit(SubscribedEvent {
            user: tx_context::sender(ctx),
            service_id: object::id(service),
        });

        // Return the coin instead of transferring it
        user_coin
    }

    ////////////////////////////////
    // === Swap logic with fee ===
    ////////////////////////////////

    public fun swap_sui_for_memecoin<T: store>(
        service: &mut Service<T>,
        input_sui: Coin<SUI>,
        min_expected_mem: u64,
        ctx: &mut TxContext
    ): Coin<T> {
        let dx = coin::value(&input_sui);
        assert!(dx > 0, EZeroAmount);
        
        let x = balance::value(&service.pool_sui);
        let y = balance::value(&service.pool_mem);
        assert!(x > 0 && y > 0, EReservesEmpty);

        // Calculate output amount using constant product formula
        let dy_raw = y * dx / (x + dx);
        
        // Calculate and split fees
        let total_fee = dy_raw * SWAP_FEE_BPS / BPS_DENOMINATOR;
        let admin_fee = total_fee * ADMIN_FEE_BPS / SWAP_FEE_BPS;
        let _lp_fee = total_fee - admin_fee; // Renamed with underscore to indicate unused
        
        // Final output amount after fees
        let dy = dy_raw - total_fee;

        // Slippage check
        assert!(dy > 0 && dy >= min_expected_mem, ESlippageExceeded);
        assert!(y >= dy + admin_fee, EPoolUnderflow);

        // Add input to pool
        balance::join(&mut service.pool_sui, coin::into_balance(input_sui));
        
        // Split output and fees
        let output = balance::split(&mut service.pool_mem, dy);
        
        // Add admin fee to admin balance
        if (admin_fee > 0) {
            let admin_fee_balance = balance::split(&mut service.pool_mem, admin_fee);
            balance::join(&mut service.admin_mem_fees, admin_fee_balance);
        };
        // Create and emit swap event
        let user = tx_context::sender(ctx);
        let service_id = object::id(service);
        let swap_event = SwapMemForSuiEvent {
            user,
            service_id,
            memecoin_in: dy,
            sui_out: dx
        };
        event::emit(swap_event);

        coin::from_balance(output, ctx)
    }

    public fun swap_memecoin_for_sui<T: store>(
        service: &mut Service<T>,
        input_mem: Coin<T>,
        min_expected_sui: u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let dy = coin::value(&input_mem);
        assert!(dy > 0, EZeroAmount);
        
        let x = balance::value(&service.pool_sui);
        let y = balance::value(&service.pool_mem);
        assert!(x > 0 && y > 0, EReservesEmpty);

        // Calculate output amount using constant product formula
        let dx_raw = x * dy / (y + dy);
        
        // Calculate and split fees
        let total_fee = dx_raw * SWAP_FEE_BPS / BPS_DENOMINATOR;
        let admin_fee = total_fee * ADMIN_FEE_BPS / SWAP_FEE_BPS;
        let _lp_fee = total_fee - admin_fee; // Renamed with underscore to indicate unused
        
        // Final output amount after fees
        let dx = dx_raw - total_fee;

        // Slippage check
        assert!(dx > 0 && dx >= min_expected_sui, ESlippageExceeded);
        assert!(x >= dx + admin_fee, EPoolUnderflow);

        // Add input to pool
        balance::join(&mut service.pool_mem, coin::into_balance(input_mem));
        
        // Split output and fees
        let output = balance::split(&mut service.pool_sui, dx);
        
        // Add admin fee to admin balance
        if (admin_fee > 0) {
            let admin_fee_balance = balance::split(&mut service.pool_sui, admin_fee);
            balance::join(&mut service.admin_sui_fees, admin_fee_balance);
        };
        // Create and emit swap event
        let user = tx_context::sender(ctx);
        let service_id = object::id(service);
        let swap_event = SwapMemForSuiEvent {
            user,
            service_id,
            memecoin_in: dy,
            sui_out: dx
        };
        event::emit(swap_event);
    
        coin::from_balance(output, ctx)
    }

    ////////////////////////////////
    // === Admin withdrawal ===
    ////////////////////////////////

    public fun admin_withdraw_sui<T: store>(
        service: &mut Service<T>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(tx_context::sender(ctx) == service.owner, EUnauthorized);
        let output = balance::split(&mut service.pool_sui, amount);
        coin::from_balance(output, ctx)
    }

    public fun admin_withdraw_memecoin<T: store>(
        service: &mut Service<T>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<T> {
        assert!(tx_context::sender(ctx) == service.owner, EUnauthorized);
        let output = balance::split(&mut service.pool_mem, amount);
        coin::from_balance(output, ctx)
    }

    entry fun emit_service_created<T: store>(_service: &Service<T>) {
        event::emit(ServiceCreatedEvent {
            owner: _service.owner,
            service_id: object::id(_service),
            memecoin_name: _service.name
        });
    }


    ////////////////////////////////
    // === Pool information ===
    ////////////////////////////////

    /// Returns the current amount of SUI in the pool
    public fun get_pool_sui_balance<T: store>(service: &Service<T>): u64 {
        balance::value(&service.pool_sui)
    }

    /// Returns the current amount of memecoin in the pool
    public fun get_pool_mem_balance<T: store>(service: &Service<T>): u64 {
        balance::value(&service.pool_mem)
    }

    /// Returns both SUI and memecoin balances in the pool
    public fun get_pool_balances<T: store>(service: &Service<T>): (u64, u64) {
        (balance::value(&service.pool_sui), balance::value(&service.pool_mem))
    }
}
