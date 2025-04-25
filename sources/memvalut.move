module mem_coin::memvault_v2 {

    use std::string::String;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;

    const ENotEnoughHolding: u64 = 0;
    const EInvalidCap: u64 = 1;
    const EMaxSubscribers: u64 = 3;
    const EPoolUnderflow: u64 = 4;

    public struct Phantom has drop {}

    /// The service created, each launching its own memecoin T.
    public struct Service<phantom T: store> has key {
        id: UID,
        owner: address,
        name: String,
        min_holding: u64,

        max_subscribers: u64,
        pool_sui: Balance<SUI>,
        pool_mem: Balance<T>,
        total_supply: Balance<T>,
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

    public fun create_service<T: copy + drop + store>(
        name: String,
        total_supply_amount: u64, // n
        initial_sui_liquidity: Coin<SUI>, // m
        max_subscribers: u64, // z
        ctx: &mut TxContext
    ): (Service<T>, Cap, Coin<T>) {
        assert!(max_subscribers > 0 && total_supply_amount > 0, EInvalidCap);

        let min_holding = total_supply_amount / max_subscribers;

        // Create a zero balance for the memecoin T
        let total_supply = balance::zero<T>();
        
        // For a real implementation, we would need to mint tokens here
        // For now, we'll just use an empty balance for the pool
        let pool_mem = balance::zero<T>();
        let pool_sui = coin::into_balance(initial_sui_liquidity);

        let service = Service<T> {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            name,
            min_holding,
            max_subscribers,
            pool_sui,
            pool_mem,
            total_supply,
        };

        let cap = Cap {
            id: object::new(ctx),
            service_id: object::id(&service),
        };

        let remaining = coin::from_balance(balance::zero<T>(), ctx);
        (service, cap, remaining)
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
        user_holding: u64, // Pass actual wallet balance of T (off-chain check)
        ctx: &mut TxContext
    ) {
        assert!(user_holding >= service.min_holding, ENotEnoughHolding);
        assert!(vector::length(&group.subscriptions) < service.max_subscribers, EMaxSubscribers);

        let sub = Subscription {
            id: object::new(ctx),
            service_id: object::id(service),
        };

        vector::push_back(&mut group.subscriptions, sub);
    }

    ////////////////////////////////
    // === Swap logic ===
    ////////////////////////////////

    public fun swap_sui_for_memecoin<T: store>(
        service: &mut Service<T>,
        input_sui: Coin<SUI>,
        ctx: &mut TxContext
    ): Coin<T> {
        let dx = coin::value(&input_sui);
        let x = balance::value(&service.pool_sui);
        let y = balance::value(&service.pool_mem);
        let dy = y * dx / (x + dx);
        assert!(dy > 0 && y >= dy, EPoolUnderflow);

        balance::join(&mut service.pool_sui, coin::into_balance(input_sui));
        let output = balance::split(&mut service.pool_mem, dy);
        coin::from_balance(output, ctx)
    }

    public fun swap_memecoin_for_sui<T: store>(
        service: &mut Service<T>,
        input_mem: Coin<T>,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let dy = coin::value(&input_mem);
        let x = balance::value(&service.pool_sui);
        let y = balance::value(&service.pool_mem);
        let dx = x * dy / (y + dy);
        assert!(dx > 0 && x >= dx, EPoolUnderflow);

        balance::join(&mut service.pool_mem, coin::into_balance(input_mem));
        let output = balance::split(&mut service.pool_sui, dx);
        coin::from_balance(output, ctx)
    }

    ////////////////////////////////
    // === Verification logic ===
    ////////////////////////////////

    fun approve_internal(sub: &Subscription, sid: ID): bool {
        sid == sub.service_id
    }

    entry fun seal_approve(sub: &Subscription, sid: ID) {
        assert!(approve_internal(sub, sid), EInvalidCap);
    }
}
