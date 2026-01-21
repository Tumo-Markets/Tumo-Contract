module tumo_markets::oracle;

use one::clock::{Self, Clock};
use one::event;
use one::object::{Self, UID};
use one::transfer;
use one::tx_context::{Self, TxContext};

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

fun update_price_logic<CoinXType>(feed: &mut PriceFeed<CoinXType>, new_price: u64, clock: &Clock) {
    assert!(new_price > 0, EInvalidPrice);

    let current_timestamp = clock::timestamp_ms(clock);

    assert!(current_timestamp >= feed.last_updated, EStaleUpdate);

    feed.price = new_price;
    feed.last_updated = current_timestamp;
}

public fun create_price_feed<CoinXType>(_: &PriceFeedCap, ctx: &mut TxContext) {
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
    new_price: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_price_logic(feeds, new_price, clock);

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

#[test]
fun test_create_price_feed() {
    use one::test_scenario;
    use one::oct::{OCT};

    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);

    {
        mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let cap = test_scenario::take_from_sender<PriceFeedCap>(&scenario);
        create_price_feed<OCT>(&cap, test_scenario::ctx(&mut scenario));
        test_scenario::return_to_sender(&scenario, cap);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let feed = test_scenario::take_shared<PriceFeed<OCT>>(&scenario);
        let (price, last_updated) = get_price(&feed);
        assert!(price == 0, 0);
        assert!(last_updated == 0, 1);
        test_scenario::return_shared(feed);
    };
    test_scenario::end(scenario);
}

#[test]
fun test_update_price() {
    use one::test_scenario;
    use one::oct::{OCT};

    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);

    {
        mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let cap = test_scenario::take_from_sender<PriceFeedCap>(&scenario);
        create_price_feed<OCT>(&cap, test_scenario::ctx(&mut scenario));
        test_scenario::return_to_sender(&scenario, cap);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let cap = test_scenario::take_from_sender<PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<PriceFeed<OCT>>(&scenario);
        let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        // Advance clock to ensure non-zero timestamp
        clock::set_for_testing(&mut clock, 1000);

        // Update price
        update_price<OCT>(&cap, &mut feed, 1000, &clock, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, cap);
        clock::destroy_for_testing(clock);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let feed = test_scenario::take_shared<PriceFeed<OCT>>(&scenario);
        let (price, timestamp) = get_price(&feed);
        assert!(price == 1000, 2);
        assert!(timestamp == 1000, 3);
        test_scenario::return_shared(feed);
    };
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidPrice)]
fun test_update_fail_invalid_price() {
    use one::test_scenario;
    use one::oct::{OCT};

    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);

    {
        mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let cap = test_scenario::take_from_sender<PriceFeedCap>(&scenario);
        create_price_feed<OCT>(&cap, test_scenario::ctx(&mut scenario));
        test_scenario::return_to_sender(&scenario, cap);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let cap = test_scenario::take_from_sender<PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<PriceFeed<OCT>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        // Update price with 0 -> Fail
        update_price<OCT>(&cap, &mut feed, 0, &clock, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, cap);
        clock::destroy_for_testing(clock);
    };
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = EStaleUpdate)]
fun test_update_fail_stale() {
    use one::test_scenario;
    use one::oct::{OCT};

    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);

    {
        mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let cap = test_scenario::take_from_sender<PriceFeedCap>(&scenario);
        create_price_feed<OCT>(&cap, test_scenario::ctx(&mut scenario));
        test_scenario::return_to_sender(&scenario, cap);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let cap = test_scenario::take_from_sender<PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<PriceFeed<OCT>>(&scenario);
        let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        // Set clock to 1000
        clock::set_for_testing(&mut clock, 1000);

        // Update price - sets last_updated to 1000
        update_price<OCT>(&cap, &mut feed, 1000, &clock, test_scenario::ctx(&mut scenario));

        // Manually set feed last_updated to FUTURE (2000)
        feed.last_updated = 2000;

        // Try to update again with clock at 1000. 1000 < 2000 -> Stale
        update_price<OCT>(&cap, &mut feed, 1200, &clock, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, cap);
        clock::destroy_for_testing(clock);
    };
    test_scenario::end(scenario);
}

// Minimal dummy coin for internal testing if needed, keeping it simple.
// In reality we imported OCT? Wait, OCT is not defined in oracle.
// Check if OCT is available or needed to be defined.
// tumble_markets_core defines OCT? No, it's used there.
// Actually, `phantom CoinXType` allows any type. I can define a dummy struct here.
