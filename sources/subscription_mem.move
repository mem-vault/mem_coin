// SPDX-License-Identifier: Apache-2.0

module mem_coin::subscription_mem;

use std::string::String;
use sui::{clock::Clock, coin::{Self, Coin}, dynamic_field as df};
use mem_coin::utils::is_prefix;
use mem_coin::mem_coin::MEM_COIN;
use sui::event;

const EInvalidCap: u64 = 0;
const EInvalidFee: u64 = 1;
const ENoAccess: u64 = 2;
const ESubscriptionNotFound: u64 = 4;
const EMaxSubscriptionsReached: u64 = 5;
const MARKER: u64 = 3;

public struct Service has key {
    id: UID,
    fee: u64,
    ttl: u64,
    owner: address,
    name: String,
    description: String,
    max_subscriptions: u64,
    publish_id: u64,
}


public struct ServiceInfo has store, drop, copy {
    service_id: ID,
    fee: u64,
    ttl: u64,
    owner: address,
    name: String,
    description: String,
    max_subscriptions: u64,
    created_at: u64,
}

// Add the store ability to ServiceInfoStorage
public struct ServiceInfoStorage has key, store {
    id: UID,
    infos: vector<ServiceInfo>,
    counter: u64,
    max_size: u64,
}

public struct Subscription has key, store {
    id: UID,
    service_id: ID,
    created_at: u64,
}

public struct SubscriptionGroup has key, store {
    id: UID,
    service_id: ID,
    subscriptions: vector<Subscription>,
}

public struct Cap has key, store {
    id: UID,
    service_id: ID,
}

// Event structures
public struct ServiceCreatedEvent has copy, drop, store {
    owner: address,
    service_id: ID,
    service_name: String,
}

public struct SubscribedEvent has copy, drop, store {
    user: address,
    service_id: ID,
    subscription_id: ID,
}

public struct SubscriptionRemovedEvent has copy, drop, store {
    user: address,
    service_id: ID,
    subscription_id: ID,
}

public struct SubscriptionTransferredEvent has copy, drop, store {
    from: address,
    to: address,
    subscription_id: ID,
}

public struct ContentPublishedEvent has copy, drop, store {
    service_id: ID,
    publisher: address,
    blob_id: String,
}

//////////////////////////////////////////
/////// Service creation

public fun create_service(fee: u64, ttl: u64, max_subscriptions: u64, name: String, description: String, ctx: &mut TxContext): Cap {
    let service = Service {
        id: object::new(ctx),
        fee,
        ttl,
        owner: tx_context::sender(ctx),
        name,
        description,
        max_subscriptions,
        publish_id: 0,
    };
    
    let service_id = object::id(&service);
    
    let cap = Cap {
        id: object::new(ctx),
        service_id,
    };
    
    // Emit service created event
    event::emit(ServiceCreatedEvent {
        owner: tx_context::sender(ctx),
        service_id,
        service_name: name,
    });
    
    
    transfer::share_object(service);
    cap
}


entry fun create_service_entry(fee: u64, ttl: u64, max_subscriptions: u64, name: String, description: String, ctx: &mut TxContext) {
    transfer::transfer(create_service(fee, ttl, max_subscriptions, name, description, ctx), tx_context::sender(ctx));
}

// Add service info to the storage
public fun add_service_info(
    storage: &mut ServiceInfoStorage,
    service: &Service,
    created_at: u64,
) {


    let service_id = object::id(service);

    let info = ServiceInfo {
        service_id,
        fee: service.fee,
        ttl: service.ttl,
        owner: service.owner,
        name: service.name,
        description: service.description,
        max_subscriptions: service.max_subscriptions,
        created_at,
    };
    
    // If we haven't reached max size yet, just push
    if (vector::length(&storage.infos) < storage.max_size) {
        vector::push_back(&mut storage.infos, info);
    } else {
        // Replace the oldest entry (using counter and mod)
        let index = storage.counter % storage.max_size;
        *vector::borrow_mut(&mut storage.infos, index) = info;
    };
    
    // Increment counter
    storage.counter = storage.counter + 1;
}

// Get all service infos
public fun get_service_infos(storage: &ServiceInfoStorage): &vector<ServiceInfo> {
    &storage.infos
}


//////////////////////////////////////////
/////// Subscription Management

public fun subscribe(
    fee: Coin<MEM_COIN>,
    service: &Service,
    group: &mut SubscriptionGroup,
    c: &Clock,
    ctx: &mut TxContext,
) {
    assert!(vector::length(&group.subscriptions) < service.max_subscriptions, EMaxSubscriptionsReached);
    assert!(coin::value(&fee) == service.fee, EInvalidFee);
    transfer::public_transfer(fee, service.owner);

    let sub = Subscription {
        id: object::new(ctx),
        service_id: object::id(service),
        created_at: c.timestamp_ms(),
    };
    
    let subscription_id = object::id(&sub);
    
    vector::push_back(&mut group.subscriptions, sub);
    
    // Emit subscription event
    event::emit(SubscribedEvent {
        user: ctx.sender(),
        service_id: object::id(service),
        subscription_id,
    });
}

public fun create_subscription_group(service: &Service, ctx: &mut TxContext): SubscriptionGroup {
    SubscriptionGroup {
        id: object::new(ctx),
        service_id: object::id(service),
        subscriptions: vector::empty(),
    }
}

public fun remove_subscription(group: &mut SubscriptionGroup, sub_id: ID): Subscription {
    let len = vector::length(&group.subscriptions);
    let mut found = false;
    let mut i = 0;
    
    // Find the index of the subscription to remove
    while (i < len) {
        let sub_ref = &group.subscriptions[i];
        if (object::id(sub_ref) == sub_id) {
            found = true;
            break
        };
        i = i + 1;
        i = i + 1;
    };
    
    assert!(found, ESubscriptionNotFound);
    
    // If it's the last element, just pop it
    if (i == len - 1) {
        return vector::pop_back(&mut group.subscriptions)
    };
    
    // Otherwise, we need to move elements to maintain order
    // First, take out the last element as a temporary holder
    let last = vector::pop_back(&mut group.subscriptions);
    
    // If we removed the only element, return it
    if (i == 0 && vector::is_empty(&group.subscriptions)) {
        return last
    };
    
    // Otherwise, swap with the element we want to remove
    let removed = vector::remove(&mut group.subscriptions, i);
    vector::push_back(&mut group.subscriptions, last);
    
    removed
}

// //////////////////////////////////////////
// /////// Batch Operations

entry fun batch_subscribe(
    mut fees: vector<Coin<MEM_COIN>>,
    service: &Service,
    group: &mut SubscriptionGroup,
    c: &Clock,
    ctx: &mut TxContext,
) {
    let count = vector::length(&fees);
    let mut i = 0;
    
    while (i < count) {
        // Pop each coin and use it to subscribe
        if (i < count - 1) {
            let coin_ref = vector::borrow_mut(&mut fees, i);
            let coin_value = coin::value(coin_ref);
            let payment = coin::split(coin_ref, coin_value, ctx);
            subscribe(payment, service, group, c, ctx);
        } else {
            // For the last coin, just take it directly
            let coin = vector::pop_back(&mut fees);
            subscribe(coin, service, group, c, ctx);
        };
        i = i + 1;
    };
    // Explicitly destroy the empty vector
    vector::destroy_empty(fees);
}

entry fun batch_remove_subscriptions(
    group: &mut SubscriptionGroup,
    sub_ids: vector<ID>,
    ctx: &TxContext,
) {
    let count = vector::length(&sub_ids);
    let mut sub_ids_mut = sub_ids;
    let mut i = 0;
    
    while (i < count) {
        // Get the removed subscription and transfer it to the transaction sender
        let id = vector::pop_back(&mut sub_ids_mut);
        let removed_sub = remove_subscription(group, id);
        
        // Emit subscription removed event
        event::emit(SubscriptionRemovedEvent {
            user: tx_context::sender(ctx),
            service_id: group.service_id,
            subscription_id: object::id(&removed_sub),
        });
        
        transfer::transfer(removed_sub, tx_context::sender(ctx));
        i = i + 1;
    };
    // Explicitly destroy the empty vector
    vector::destroy_empty(sub_ids_mut);
}

//////////////////////////////////////////
/////// Getters

public fun get_service_id(cap: &Cap): ID {
    cap.service_id
}

public fun get_group_service_id(group: &SubscriptionGroup): ID {
    group.service_id
}

public fun get_subscriptions_length(group: &SubscriptionGroup): u64 {
    vector::length(&group.subscriptions)
}

public fun get_subscription_at(group: &SubscriptionGroup, index: u64): &Subscription {
    vector::borrow(&group.subscriptions, index)
}

public fun is_subscriptions_empty(group: &SubscriptionGroup): bool {
    vector::is_empty(&group.subscriptions)
}

public fun get_subscriptions(group: &SubscriptionGroup): &vector<Subscription> {
    &group.subscriptions
}

//////////////////////////////////////////
/////// Access control

fun approve_internal(id: vector<u8>, sub: &Subscription, service: &Service, c: &Clock): bool {
    object::id(service) == sub.service_id &&
    c.timestamp_ms() <= sub.created_at + service.ttl &&
    is_prefix(service.id.to_bytes(), id)
}

entry fun seal_approve(id: vector<u8>, sub: &Subscription, service: &Service, c: &Clock) {
    assert!(approve_internal(id, sub, service, c), ENoAccess);
}


//////////////////////////////////////////
/// Trading Functionality

/// Transfer subscription ownership (simple direct transfer)
#[allow(lint(custom_state_change))]
entry fun transfer_subscription(sub: Subscription, to: address, ctx: &TxContext) {
    // Emit transfer event
    event::emit(SubscriptionTransferredEvent {
        from: ctx.sender(),
        to,
        subscription_id: object::id(&sub),
    });
    
    transfer::transfer(sub, to);
}

/// Encapsulate a blob into a Sui object and attach it to the Subscription
public fun publish(service: &mut Service, cap: &Cap, blob_id: String, ctx: &mut TxContext) {
    assert!(cap.service_id == object::id(service), EInvalidCap);
    df::add(&mut service.id, blob_id, MARKER);
    
    // Increment the publish_id counter
    service.publish_id = service.publish_id + 1;
    
    // Emit content published event
    event::emit(ContentPublishedEvent {
        service_id: object::id(service),
        publisher: tx_context::sender(ctx),
        blob_id,
    });
}

// Add a getter function for publish_id
public fun get_publish_id(service: &Service): u64 {
    service.publish_id
}

// Initialize the service info storage
public entry fun init_service_info_storage(ctx: &mut TxContext) {
    let storage = ServiceInfoStorage {
        id: object::new(ctx),
        infos: vector::empty<ServiceInfo>(),
        counter: 0,
        max_size: 10,
    };
    
    transfer::share_object(storage);
}