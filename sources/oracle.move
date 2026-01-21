module tumo_markets::oracle;

use one::clock::{Self, Clock};
use one::object::{Self, UID};
use one::transfer;
use one::tx_context::{Self, TxContext};
use one::event;

// --- Errors ---
const EInvalidPrice: u64 = 0;
const EStaleUpdate: u64 = 1;

// --- Structs ---
public struct PriceFeedCap has key {
    id: UID,
}

public struct PriceFeed<phantom CoinXType> has key {
    id: UID,
    price: u64, 
    last_updated: u64,
}

// --- Events ---

public struct PriceUpdated has copy, drop {
    new_price: u64,
    timestamp: u64,
    updated_by: address,
}

fun init(ctx: &mut TxContext) {
    let admin = tx_context::sender(ctx);

    transfer::transfer(
        PriceFeedCap {
            id: object::new(ctx),
        },
        admin,
    );
}

#[test_only]
public fun mint_cap_for_testing(ctx: &mut TxContext) {
    // Helper cho unit test ở module khác: mint PriceFeedCap cho sender
    let sender = tx_context::sender(ctx);
    transfer::transfer(
        PriceFeedCap { id: object::new(ctx) },
        sender,
    );
}

fun update_price_logic<CoinXType>(
    feed: &mut PriceFeed<CoinXType>,
    new_price: u64,
    clock: &Clock,
) {
    assert!(new_price > 0, EInvalidPrice);

    let current_timestamp = clock::timestamp_ms(clock);
    
    assert!(current_timestamp >= feed.last_updated, EStaleUpdate);

    feed.price = new_price;
    feed.last_updated = current_timestamp;
}

public fun create_price_feed<CoinXType>(
    _: &PriceFeedCap,
    ctx: &mut TxContext,
) {
    let feed = PriceFeed<CoinXType> {
        id: object::new(ctx),
        price: 0,
        last_updated: 0,
    };

    transfer::share_object(feed);
}

public fun update_price<CoinXType>(
    _auth_cap: &PriceFeedCap,
    feeds: &mut PriceFeed<CoinXType>,
    new_prices: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_price_logic(feeds, *vector::borrow(&new_prices, 0), clock);

    let event = PriceUpdated {
        new_price: feeds.price,
        timestamp: feeds.last_updated,
        updated_by: tx_context::sender(ctx),
    };
    event::emit(event);
}

public fun get_price<CoinXType>(feed: &PriceFeed<CoinXType>): (u64, u64) {
    (feed.price, feed.last_updated)
}

