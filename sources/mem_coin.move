module mem_coin::mem_coin;

use sui::coin::{Self, Coin, TreasuryCap};

public struct MEM_COIN has drop {}

fun init(witness: MEM_COIN, ctx: &mut TxContext) {
		let (treasury, metadata) = coin::create_currency(
				witness,
				6,
				b"MEM_COIN",
				b"MEM",
				b"",
				option::none(),
				ctx,
		);
		transfer::public_freeze_object(metadata);
		transfer::public_transfer(treasury, ctx.sender())
}

// Manager can mint new coins
public fun mint(
		treasury_cap: &mut TreasuryCap<MEM_COIN>,
		amount: u64,
		recipient: address,
		ctx: &mut TxContext,
) {
		let coin = coin::mint(treasury_cap, amount, ctx);
		transfer::public_transfer(coin, recipient)
}

/// Manager can burn coins
public fun burn(treasury_cap: &mut TreasuryCap<MEM_COIN>, coin: Coin<MEM_COIN>) {
    coin::burn(treasury_cap, coin);
}