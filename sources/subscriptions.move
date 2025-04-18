// SPDX-License-Identifier: Apache-2.0

module mem_coin::subscriptions;

use std::string::String;
use sui::{clock::{Self, Clock}, coin::{Self, Coin}, dynamic_field as df, dynamic_object_field as dof, sui::SUI};
use mem_coin::utils::is_prefix;

// Error constants
const EInvalidCap: u64 = 0;
const EInvalidFee: u64 = 1;
const ENoAccess: u64 = 2;
const MARKER: u64 = 3;
const EInvalidItem: u64 = 5;

// Data structures
// Two levels of subscription: 1. collection, 2. item
public struct Collection has key {
    id: UID,
    owner: address, // the creator, who receives subscription fees.
    name: String,
    description: String,
    collection_price: u64,  // Price for the whole collection
    ttl: u64,               // Time to live for subscriptions
}

public struct Item has key, store {
    id: UID,
    name: String,
    description: String,
    price: u64,              // Individual item price
    collection_id: ID,       // Reference to parent collection
}

public struct CollectionSubscription has key, store {
    id: UID,
    collection_id: ID,
    created_at: u64,
}

public struct ItemSubscription has key, store {
    id: UID,
    item_id: ID,
    collection_id: ID,
    created_at: u64,
}

public struct CollectionCap has key, store {
    id: UID,
    collection_id: ID,
}

//////////////////////////////////////////
/////// Collection Management

/// Create a collection with optional collection-wide price
public fun create_collection(
    name: String,
    description: String,
    collection_price: u64,
    ttl: u64,
    ctx: &mut TxContext
): CollectionCap {
    let collection = Collection {
        id: object::new(ctx),
        owner: tx_context::sender(ctx),
        name,
        description,
        collection_price,
        ttl,
    };
    
    let cap = CollectionCap {
        id: object::new(ctx),
        collection_id: object::id(&collection),
    };
    
    transfer::share_object(collection);
    cap
}

// Convenience function to create a collection and transfer the cap to the sender
entry fun create_collection_entry(
    name: String,
    description: String,
    collection_price: u64,
    ttl: u64,
    ctx: &mut TxContext
) {
    transfer::public_transfer(create_collection(name, description, collection_price, ttl, ctx), tx_context::sender(ctx));
}

/// Add an item to a collection
public fun add_item(
    collection: &mut Collection,
    cap: &CollectionCap,
    name: String,
    description: String,
    price: u64,
    ctx: &mut TxContext
): ID {
    // Verify the cap is for this collection
    assert!(cap.collection_id == object::id(collection), EInvalidCap);
    
    // Create the item
    let item = Item {
        id: object::new(ctx),
        name,
        description,
        price,
        collection_id: object::id(collection),
    };
    
    // Store the item as a dynamic object field in the collection
    let item_id = object::id(&item);
    dof::add(&mut collection.id, item_id, item);
    
    // Add a marker to track that this item exists
    df::add(&mut collection.id, item_id, true);
    
    // Return the item ID
    item_id
}

entry fun add_item_entry(
    collection: &mut Collection,
    cap: &CollectionCap,
    name: String,
    description: String,
    price: u64,
    ctx: &mut TxContext
) {
    let _item_id = add_item(collection, cap, name, description, price, ctx);
}

/// Update item price
public fun update_item_price(
    collection: &mut Collection,
    cap: &CollectionCap,
    item_id: ID,
    new_price: u64
) {
    // Verify the cap is for this collection
    assert!(cap.collection_id == object::id(collection), EInvalidCap);
    
    // Get the item and update its price
    let item = dof::borrow_mut<ID, Item>(&mut collection.id, item_id);
    item.price = new_price;
}

/// Update collection price
public fun update_collection_price(
    collection: &mut Collection,
    cap: &CollectionCap,
    new_price: u64
) {
    // Verify the cap is for this collection
    assert!(cap.collection_id == object::id(collection), EInvalidCap);
    
    // Update the collection price
    collection.collection_price = new_price;
}

//////////////////////////////////////////
/////// Subscription Management

/// Subscribe to a whole collection
public fun subscribe_to_collection(
    fee: Coin<SUI>,
    collection: &Collection,
    c: &Clock,
    ctx: &mut TxContext
): CollectionSubscription {
    // Verify the fee matches the collection price
    assert!(coin::value(&fee) == collection.collection_price, EInvalidFee);
    
    // Transfer the fee to the collection owner
    transfer::public_transfer(fee, collection.owner);
    
    // Create and return the subscription
    CollectionSubscription {
        id: object::new(ctx),
        collection_id: object::id(collection),
        created_at: clock::timestamp_ms(c),
    }
}

/// Subscribe to a specific item
public fun subscribe_to_item(
    fee: Coin<SUI>,
    collection: &Collection,
    item_id: ID,
    c: &Clock,
    ctx: &mut TxContext
): ItemSubscription {
    // Verify the item exists using the marker
    assert!(df::exists_(&collection.id, item_id), EInvalidItem);
    
    // Get the item to check its price
    let item = dof::borrow<ID, Item>(&collection.id, item_id);
    
    // Verify the fee matches the item price
    assert!(coin::value(&fee) == item.price, EInvalidFee);
    
    // Transfer the fee to the collection owner
    transfer::public_transfer(fee, collection.owner);
    
    // Create and return the subscription
    ItemSubscription {
        id: object::new(ctx),
        item_id,
        collection_id: object::id(collection),
        created_at: clock::timestamp_ms(c),
    }
}

/// Transfer a collection subscription to another address
public fun transfer_collection_subscription(sub: CollectionSubscription, to: address) {
    transfer::public_transfer(sub, to);
}

/// Transfer an item subscription to another address
public fun transfer_item_subscription(sub: ItemSubscription, to: address) {
    transfer::public_transfer(sub, to);
}

//////////////////////////////////////////
/////// Access Control

/// Check if a collection subscription is valid
fun is_collection_subscription_valid(
    sub: &CollectionSubscription,
    collection: &Collection,
    c: &Clock
): bool {
    // Verify the subscription is for this collection
    if (object::id(collection) != sub.collection_id) {
        return false
    };
    
    // Verify the subscription hasn't expired
    if (clock::timestamp_ms(c) > sub.created_at + collection.ttl) {
        return false
    };
    
    true
}

/// Check if an item subscription is valid
fun is_item_subscription_valid(
    sub: &ItemSubscription,
    collection: &Collection,
    item_id: ID,
    c: &Clock
): bool {
    // Verify the subscription is for this collection and item
    if (object::id(collection) != sub.collection_id || item_id != sub.item_id) {
        return false
    };
    
    // Verify the subscription hasn't expired
    if (clock::timestamp_ms(c) > sub.created_at + collection.ttl) {
        return false
    };
    
    true
}

/// Verify access to a collection with a collection subscription
entry fun verify_collection_access(
    id: vector<u8>,
    sub: &CollectionSubscription,
    collection: &Collection,
    c: &Clock
) {
    // Verify the subscription is valid
    assert!(is_collection_subscription_valid(sub, collection, c), ENoAccess);
    
    // Check if the id has the right prefix
    assert!(is_prefix(collection.id.to_bytes(), id), ENoAccess);
}

/// Verify access to an item with an item subscription
entry fun verify_item_access(
    id: vector<u8>,
    sub: &ItemSubscription,
    collection: &Collection,
    item_id: ID,
    c: &Clock
) {
    // Verify the subscription is valid
    assert!(is_item_subscription_valid(sub, collection, item_id, c), ENoAccess);
    
    // Get the item
    let item = dof::borrow<ID, Item>(&collection.id, item_id);
    
    // Check if the id has the right prefix
    assert!(is_prefix(item.id.to_bytes(), id), ENoAccess);
}

/// Publish content to a collection (only collection owner can do this)
public fun publish_to_collection(
    collection: &mut Collection,
    cap: &CollectionCap,
    content_id: String
) {
    // Verify the cap is for this collection
    assert!(cap.collection_id == object::id(collection), EInvalidCap);
    
    // Add the content to the collection
    df::add(&mut collection.id, content_id, MARKER);
}

/// Publish content to a specific item (only collection owner can do this)
public fun publish_to_item(
    collection: &mut Collection,
    cap: &CollectionCap,
    item_id: ID,
    content_id: String
) {
    // Verify the cap is for this collection
    assert!(cap.collection_id == object::id(collection), EInvalidCap);
    
    // Verify the item exists using the marker
    assert!(df::exists_(&collection.id, item_id), EInvalidItem);
    
    // Get the item
    let item = dof::borrow_mut<ID, Item>(&mut collection.id, item_id);
    
    // Add the content to the item
    df::add(&mut item.id, content_id, MARKER);
}

#[test_only]
public fun destroy_for_testing(
    collection: Collection,
    collection_sub: CollectionSubscription,
    item_sub: ItemSubscription
) {
    let Collection { id, .. } = collection;
    object::delete(id);
    
    let CollectionSubscription { id, .. } = collection_sub;
    object::delete(id);
    
    let ItemSubscription { id, .. } = item_sub;
    object::delete(id);
}