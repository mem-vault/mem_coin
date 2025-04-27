module mem_coin::memvault {

    use sui::coin::{Coin, TreasuryCap, create_currency, mint};
    use sui::balance::{Balance};
    use sui::sui::SUI;
    use sui::dynamic_field as df;
    use sui::event;
    use sui::url::Url;
    use std::string::String;
    use mem_coin::utils::is_prefix;

    const ENotEnoughHolding: u64 = 0;
    const EInvalidCap: u64 = 1;
    const EMaxSubscribers: u64 = 2;
    const EPoolUnderflow: u64 = 3;
    const ESlippageExceeded: u64 = 4;
    const EUnauthorized: u64 = 5;
    const ENoAccess: u64 = 8;
    const EZeroAmount: u64 = 9;
    const EReservesEmpty: u64 = 10;
    const SWAP_FEE_BPS: u64 = 30;
    const ADMIN_FEE_BPS: u64 = 5;
    const BPS_DENOMINATOR: u64 = 10000;
    const MARKER: u64 = 9999;

    public struct Phantom has store, drop {}

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
        treasury_cap: TreasuryCap<T>,
    }

    public struct Subscription has key, store {
        id: UID,
        service_id: ID
    }

    public struct Cap has key {
        id: UID,
        service_id: ID,
    }

    public struct SubscriptionGroup has key {
        id: UID,
        service_id: ID,
        subscriptions: vector<Subscription>,
    }

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

    public struct SwapSuiForMemEvent has copy, drop, store {
        user: address,
        service_id: ID,
        sui_in: u64,
        memecoin_out: u64,
    }

    public struct ContentPublishedEvent has copy, drop, store {
        service_id: ID,
        publisher: address,
        blob_id: String,
    }

    public struct ServiceWitness has store, drop {}

    public entry fun create_service(
        name: String,
        symbol: String,
        total_supply: u64,
        initial_sui_liquidity: Coin<SUI>,
        max_subscribers: u64,
        ctx: &mut TxContext
    ) {
        assert!(max_subscribers > 0 && total_supply > 0, EInvalidCap);
        // let witness = ServiceWitness { id: object::new(ctx) };
        let (mut treasury_cap, coin_metadata) = create_currency<ServiceWitness>(
            ServiceWitness {},
            18u8,
            std::string::into_bytes(name),
            std::string::into_bytes(symbol),
            std::vector::empty<u8>(),
            std::option::none<Url>(),
            ctx
        );
    
        transfer::public_freeze_object(coin_metadata);
    
        let min_holding = total_supply / max_subscribers;
    
        let minted = mint(&mut treasury_cap, total_supply, ctx);
        let mut minted_balance = sui::coin::into_balance(minted);
    
        let pool_amount = total_supply * 80 / 100;
        let pool_mem = sui::balance::split(&mut minted_balance, pool_amount);
        let pool_sui = sui::coin::into_balance(initial_sui_liquidity);
    
        let service = Service<ServiceWitness> {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            name: name,
            min_holding,
            max_subscribers,
            pool_sui,
            pool_mem,
            admin_sui_fees: sui::balance::zero<SUI>(),
            admin_mem_fees: sui::balance::zero<ServiceWitness>(),
            treasury_cap: treasury_cap,
        };
    
        let cap = Cap {
            id: object::new(ctx),
            service_id: object::id(&service),
        };
    
        event::emit(ServiceCreatedEvent {
            owner: tx_context::sender(ctx),
            service_id: object::id(&service),
            memecoin_name: service.name,
        });
    
        transfer::transfer(service, tx_context::sender(ctx));
        transfer::transfer(cap, tx_context::sender(ctx));
        let owner_coin = sui::coin::from_balance(minted_balance, ctx);
        transfer::public_transfer(owner_coin, tx_context::sender(ctx));
    }


    // public entry fun create_service(
    //     name: String,
    //     symbol: String,
    //     total_supply: u64,
    //     initial_sui_liquidity: Coin<SUI>,
    //     max_subscribers: u64,
    //     ctx: &mut TxContext
    // ) {
    //     assert!(max_subscribers > 0 && total_supply > 0, EInvalidCap);

    //     // Use the correct one-time witness pattern for coin creation
    //     let (mut treasury_cap, coin_metadata) = create_currency<Phantom>(
    //         Phantom {},
    //         18u8,
    //         std::string::into_bytes(name),
    //         std::string::into_bytes(symbol),
    //         std::vector::empty<u8>(),
    //         std::option::none<Url>(),
    //         ctx
    //     );

    //     transfer::public_freeze_object(coin_metadata);

    //     let min_holding = total_supply / max_subscribers;

    //     let minted = mint(&mut treasury_cap, total_supply, ctx);
    //     let mut minted_balance = sui::coin::into_balance(minted);

    //     let pool_amount = total_supply * 80 / 100;
    //     let pool_mem = sui::balance::split(&mut minted_balance, pool_amount);
    //     let pool_sui = sui::coin::into_balance(initial_sui_liquidity);

    //     let service = Service<Phantom> {
    //         id: object::new(ctx),
    //         owner: tx_context::sender(ctx),
    //         name: name,
    //         min_holding,
    //         max_subscribers,
    //         pool_sui,
    //         pool_mem,
    //         admin_sui_fees: sui::balance::zero<SUI>(),
    //         admin_mem_fees: sui::balance::zero<Phantom>(),
    //         treasury_cap: treasury_cap,
    //     };

    //     let cap = Cap {
    //         id: object::new(ctx),
    //         service_id: object::id(&service),
    //     };

    //     event::emit(ServiceCreatedEvent {
    //         owner: tx_context::sender(ctx),
    //         service_id: object::id(&service),
    //         memecoin_name: service.name,
    //     });

    //     transfer::transfer(service, tx_context::sender(ctx));
    //     transfer::transfer(cap, tx_context::sender(ctx));
    //     let owner_coin = sui::coin::from_balance(minted_balance, ctx);
    //     transfer::public_transfer(owner_coin, tx_context::sender(ctx));
    // }

    public fun create_subscription_group(service: &Service<ServiceWitness>, ctx: &mut TxContext): SubscriptionGroup {
        SubscriptionGroup {
            id: object::new(ctx),
            service_id: object::id(service),
            subscriptions: vector::empty(),
        }
    }

    public fun subscribe(
        service: &Service<ServiceWitness>,
        group: &mut SubscriptionGroup,
        user_coin: Coin<ServiceWitness>,
        ctx: &mut TxContext
    ): Coin<ServiceWitness> {
        let user_holding = sui::coin::value(&user_coin);
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

        user_coin
    }

    //////////////////////////////////////////////////////////
    /// Access control
    /// key format: [pkg id]::[service id][random nonce]

    fun approve_internal(id: vector<u8>, sub: &Subscription, service: &Service<Phantom>, user_coin: &Coin<Phantom>): bool {
        if (object::id(service) != sub.service_id) {
            return false
        };

        let user_holding = sui::coin::value(user_coin);
        if(user_holding < service.min_holding) {
            return false
        };

        // Check if the id has the right prefix
        is_prefix(service.id.to_bytes(), id)
    }

    entry fun seal_approve(id: vector<u8>, sub: &Subscription, service: &Service<Phantom>, user_coin: &Coin<Phantom>) {
        assert!(approve_internal(id, sub, service, user_coin), ENoAccess);
    }

    /// Encapsulate a blob into a service
    public fun publish(
        service: &mut Service<Phantom>,
        cap: &Cap,
        blob_id: String,
        ctx: &mut TxContext,

    ) {
        assert!(cap.service_id == object::id(service), EInvalidCap);

        df::add(&mut service.id, blob_id, MARKER);


        // 🔥 Emit ContentPublishedEvent
        event::emit(ContentPublishedEvent {
            service_id: object::id(service),
            publisher: tx_context::sender(ctx),
            blob_id: blob_id,
        });
    }


    //////////////////////////
    // Swapping-logic
    //////////////////////////

    public fun swap_sui_for_memecoin(
        service: &mut Service<Phantom>,
        input_sui: Coin<SUI>,
        min_expected_mem: u64,
        ctx: &mut TxContext
    ): Coin<Phantom> {
        let dx = sui::coin::value(&input_sui);
        assert!(dx > 0, EZeroAmount);

        let x = sui::balance::value(&service.pool_sui);
        let y = sui::balance::value(&service.pool_mem);
        assert!(x > 0 && y > 0, EReservesEmpty);

        let dy_raw = y * dx / (x + dx);
        let total_fee = dy_raw * SWAP_FEE_BPS / BPS_DENOMINATOR;
        let admin_fee = total_fee * ADMIN_FEE_BPS / SWAP_FEE_BPS;
        let dy = dy_raw - total_fee;

        assert!(dy >= min_expected_mem, ESlippageExceeded);
        assert!(y >= dy + admin_fee, EPoolUnderflow);

        sui::balance::join(&mut service.pool_sui, sui::coin::into_balance(input_sui));

        let output = sui::balance::split(&mut service.pool_mem, dy);
        if (admin_fee > 0) {
            let admin_balance = sui::balance::split(&mut service.pool_mem, admin_fee);
            sui::balance::join(&mut service.admin_mem_fees, admin_balance);
        };
        event::emit(SwapSuiForMemEvent {
            user: tx_context::sender(ctx),
            service_id: object::id(service),
            sui_in: dx,
            memecoin_out: dy
        });

        sui::coin::from_balance(output, ctx)
    }

    public fun swap_memecoin_for_sui(
        service: &mut Service<Phantom>,
        input_mem: Coin<Phantom>,
        min_expected_sui: u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let dy = sui::coin::value(&input_mem);
        assert!(dy > 0, EZeroAmount);

        let x = sui::balance::value(&service.pool_sui);
        let y = sui::balance::value(&service.pool_mem);
        assert!(x > 0 && y > 0, EReservesEmpty);

        let dx_raw = x * dy / (y + dy);
        let total_fee = dx_raw * SWAP_FEE_BPS / BPS_DENOMINATOR;
        let admin_fee = total_fee * ADMIN_FEE_BPS / SWAP_FEE_BPS;
        let dx = dx_raw - total_fee;

        assert!(dx >= min_expected_sui, ESlippageExceeded);
        assert!(x >= dx + admin_fee, EPoolUnderflow);

        sui::balance::join(&mut service.pool_mem, sui::coin::into_balance(input_mem));

        let output = sui::balance::split(&mut service.pool_sui, dx);
        if (admin_fee > 0) {
            let admin_balance = sui::balance::split(&mut service.pool_sui, admin_fee);
            sui::balance::join(&mut service.admin_sui_fees, admin_balance);
        };
        event::emit(SwapMemForSuiEvent {
            user: tx_context::sender(ctx),
            service_id: object::id(service),
            memecoin_in: dy,
            sui_out: dx
        });

        sui::coin::from_balance(output, ctx)
    }

    public fun admin_withdraw_sui(service: &mut Service<Phantom>, amount: u64, ctx: &mut TxContext): Coin<SUI> {
        assert!(tx_context::sender(ctx) == service.owner, EUnauthorized);
        let output = sui::balance::split(&mut service.pool_sui, amount);
        sui::coin::from_balance(output, ctx)
    }

    public fun admin_withdraw_memecoin(service: &mut Service<Phantom>, amount: u64, ctx: &mut TxContext): Coin<Phantom> {
        assert!(tx_context::sender(ctx) == service.owner, EUnauthorized);
        let output = sui::balance::split(&mut service.pool_mem, amount);
        sui::coin::from_balance(output, ctx)
    }

    ////////////////////////////////
    // === Pool information ===
    ////////////////////////////////

    /// Returns the current amount of SUI in the pool
    public fun get_pool_sui_balance<T: store>(service: &Service<T>): u64 {
        sui::balance::value(&service.pool_sui)
    }

    /// Returns the current amount of memecoin in the pool
    public fun get_pool_mem_balance<T: store>(service: &Service<T>): u64 {
        sui::balance::value(&service.pool_mem)
    }

    /// Returns both SUI and memecoin balances in the pool
    public fun get_pool_balances<T: store>(service: &Service<T>): (u64, u64) {
        (sui::balance::value(&service.pool_sui), sui::balance::value(&service.pool_mem))
    }

}
