// SPDX-License-Identifier: Apache-2.0

/// Example coin with a trusted manager responsible for minting/burning (e.g., a stablecoin)
/// By convention, modules defining custom coin types use upper case names, in contrast to
/// ordinary modules, which use camel case.

module mem_coin::memory;

use sui::coin::{Self, Coin, TreasuryCap};

/// Name of the coin. By convention, this type has the same name as its parent module
/// and has no fields. The full type of the coin defined by this module will be `COIN<MEMORY>`.
public struct MEMORY has drop {}

/// Register the managed currency to acquire its `TreasuryCap`. Because
/// this is a module initializer, it ensures the currency only gets
/// registered once.
fun init(witness: MEMORY, ctx: &mut TxContext) {
    // Get a treasury cap for the coin and give it to the transaction sender
    let (treasury_cap, metadata) = coin::create_currency<MEMORY>(
        witness,
        2,
        b"MEMORY",
        b"MMRY",
        b"",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury_cap, tx_context::sender(ctx))
}

/// Manager can mint new coins
public fun mint(
    treasury_cap: &mut TreasuryCap<MEMORY>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    coin::mint_and_transfer(treasury_cap, amount, recipient, ctx)
}

/// Manager can burn coins
public fun burn(treasury_cap: &mut TreasuryCap<MEMORY>, coin: Coin<MEMORY>) {
    coin::burn(treasury_cap, coin);
}