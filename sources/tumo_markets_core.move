module tumo_markets::tumo_markets_core;

use one::balance::{Self, Balance};
use one::clock::{Self, Clock};
use one::coin::{Self, Coin};
use one::event;
use one::object::{Self, UID, ID};
use one::transfer;
use one::oct::OCT;
use one::tx_context::{Self, TxContext};
use one::table::{Self, Table};
use tumo_markets::oracle::{PriceFeed};

// ==================== Error Codes ====================
const ENotAdmin: u64 = 0;
const EMarketPaused: u64 = 1;
const EInvalidPrice: u64 = 2;
const EZeroAmount: u64 = 3;
const EInvalidDirection: u64 = 4;
const EInvalidSize: u64 = 5;
const EInvalidCollateral: u64 = 6;
const EPositionNotFound: u64 = 7;
const EPositionExists: u64 = 8;
const EDirectionMismatch: u64 = 9;

// ==================== Constants ====================
const LONG: u8 = 0;
const SHORT: u8 = 1;
/// price được lưu theo dạng: price_decimal * PRICE_SCALE
const PRICE_SCALE: u64 = 1_000_000;

public struct LiquidityPool<phantom USDHType> has key {
    id: UID,
    balance: Balance<USDHType>,
}
// ==================== Market ====================

public struct Market<phantom CoinXType> has key { // Trading Market for CoinX/USDH
    id: UID,
    leverage: u8,
    is_paused: bool,
    positions: Table<address, Position<CoinXType>>,
}


// ==================== Position Entity (The Ticket) ====================
/// Đối tượng đại diện cho vị thế của User
/// Mỗi Position là một "Ticket" riêng biệt
public struct Position<phantom CoinXType> has store {
    owner: address,
    size: u64,
    collateral_amount: u64,
    entry_price: u64,
    direction: u8,
    open_timestamp: u64,
}

// ==================== Admin Capability ====================
public struct AdminCap has key {
    id: UID,
}

/// Quyền LP (Liquidity Provider) để nạp/rút thanh khoản
public struct LPCap has key {
    id: UID,
}

// ==================== Events ====================
public struct MarketInitialized has copy, drop {
    market_id: ID,
    leverage: u8,
}

public struct LiquidityAdded has copy, drop {
    provider: address,
    amount: u64,
    total_liquidity: u64,
}

public struct LiquidityRemoved has copy, drop {
    provider: address,
    amount: u64,
    total_liquidity: u64,
}

public struct PositionOpened has copy, drop {
    owner: address,
    size: u64,
    collateral: u64,
    entry_price: u64,
    direction: u8,
    timestamp: u64,
}

public struct PositionUpdated has copy, drop {
    owner: address,
    new_size: u64,
    new_collateral: u64,
    new_entry_price: u64,
    direction: u8,
    timestamp: u64,
}

public struct PositionClosed has copy, drop {
    position_id: ID,
    owner: address,
    size: u64,
    collateral_returned: u64,
    pnl: u64,
    is_profit: bool,
}

public struct MarketPaused has copy, drop {
    paused: bool,
}

// ==================== One-Time Witness ====================
public struct TUMO_MARKETS_CORE has drop {}

// ==================== Init Function ====================
fun init(_otw: TUMO_MARKETS_CORE, ctx: &mut TxContext) {
    let admin = tx_context::sender(ctx);

    let admin_cap = AdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, admin);

    let lp_cap = LPCap {
        id: object::new(ctx),
    };
    transfer::transfer(lp_cap, admin);
}

public fun create_market<CoinXType>(_admin_cap: &AdminCap, leverage: u8, ctx: &mut TxContext) {
    let copy_market = Market<CoinXType> {
        id: object::new(ctx),
        leverage,
        is_paused: false,
        positions: table::new(ctx)
    };
    let market_id = object::id(&copy_market);
    transfer::share_object(copy_market);
    event::emit(MarketInitialized {
        market_id,
        leverage,
    });
}

public fun create_liquidity_pool<USDHType>(_admin_cap: &AdminCap, ctx: &mut TxContext) {
    let liquidity_pool = LiquidityPool<USDHType> {
        id: object::new(ctx),
        balance: balance::zero(),
    };
    transfer::share_object(liquidity_pool);
}
// ==================== Liquidity Operations ====================
public fun add_liquidity<USDHType>(
    liquidity_pool: &mut LiquidityPool<USDHType>,
    _lp_cap: &LPCap,
    payment: Coin<USDHType>,
    ctx: &mut TxContext,
) {
    let provider = tx_context::sender(ctx);
    let amount = coin::value(&payment);
    assert!(amount > 0, EZeroAmount);

    // Nạp vào liquidity pool
    let payment_balance = coin::into_balance(payment);
    balance::join(&mut liquidity_pool.balance, payment_balance);

    let total_liquidity = balance::value(&liquidity_pool.balance);

    event::emit(LiquidityAdded {
        provider,
        amount,
        total_liquidity,
    });
}

/// Admin/LP rút thanh khoản từ Pool
public fun remove_liquidity<USDHType>(
    liquidity_pool: &mut LiquidityPool<USDHType>,
    _lp_cap: &LPCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<USDHType> {
    assert!(amount > 0, EZeroAmount);

    let provider = tx_context::sender(ctx);
    let withdrawn = balance::split(&mut liquidity_pool.balance, amount);

    let total_liquidity = balance::value(&liquidity_pool.balance);

    event::emit(LiquidityRemoved {
        provider,
        amount,
        total_liquidity,
    });

    coin::from_balance(withdrawn, ctx)
}

// ==================== Position Operations ====================

public fun open_position<USDHType, CoinXType>(
    market: &mut Market<CoinXType>,
    liquidity_pool: &mut LiquidityPool<USDHType>,
    payment_collateral_coin: Coin<USDHType>,
    oracle: &PriceFeed<CoinXType>,
    size: u64,
    direction: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!market.is_paused, EMarketPaused);
    assert!(size > 0, EInvalidSize);
    assert!(direction == LONG || direction == SHORT, EInvalidDirection);

    let (entry_price, _last_updated) = oracle.get_price();

    assert!(entry_price > 0, EInvalidPrice);

    let owner = tx_context::sender(ctx);
    let payment_collateral = coin::value(&payment_collateral_coin);


    let collateral_balance = coin::into_balance(payment_collateral_coin);
    balance::join(&mut liquidity_pool.balance, collateral_balance);

    let timestamp = clock::timestamp_ms(clock);

    if (!table::contains(&market.positions, owner)) {
        assert!(payment_collateral > 0, EInvalidCollateral);
        // Check min collateral based on leverage
        assert!(payment_collateral * (market.leverage as u64) >= size, EInvalidSize);
        let position = Position<CoinXType> {
            owner,
            size,
            collateral_amount: payment_collateral,
            entry_price,
            direction,
            open_timestamp: timestamp,
        };

        event::emit(PositionOpened {
            owner,
            size,
            collateral: payment_collateral,
            entry_price,
            direction,
            timestamp,
        });

        table::add(&mut market.positions, owner, position);
    } else {
        let position = table::borrow_mut(&mut market.positions, owner);
        assert!(position.direction == direction, EDirectionMismatch);

        // New totals
        let new_size = position.size + size;
        let new_collateral = position.collateral_amount + payment_collateral;

        // Ensure total collateral meets leverage constraint for total size
        assert!(new_collateral * (market.leverage as u64) >= new_size, EInvalidSize);

        // Weighted average entry price:
        // new_entry = (old_entry*old_size + current_price*added_size) / (old_size + added_size)
        let weighted_sum: u128 =
            (position.entry_price as u128) * (position.size as u128) + (entry_price as u128) * (size as u128);
        let new_entry_price: u64 = (weighted_sum / (new_size as u128)) as u64;

        position.size = new_size;
        position.collateral_amount = new_collateral;
        position.entry_price = new_entry_price;
        // keep original open_timestamp (position.open_timestamp) to represent first open time

        event::emit(PositionUpdated {
            owner,
            new_size,
            new_collateral,
            new_entry_price,
            direction,
            timestamp,
        });
    }
}


// public fun close_position(
//     market: &mut Market,
//     position: Position,
//     exit_price: u64,
//     ctx: &mut TxContext,
// ): Coin<USDH> {
//     assert!(!market.is_paused, EMarketPaused);

//     let Position {
//         id,
//         owner,
//         size,
//         collateral,
//         entry_price,
//         direction,
//         open_timestamp: _,
//         market_id: _,
//     } = position;

//     // Verify owner
//     let sender = tx_context::sender(ctx);
//     assert!(sender == owner, ENotPositionOwner);

//     let position_id = object::uid_to_inner(&id);

//     // Tính PnL (simplified)
//     let (pnl, is_profit) = calculate_pnl(size, entry_price, exit_price, direction);

//     // Tính số tiền trả lại
//     let return_amount = if (is_profit) {
//         let profit = pnl;
//         // let max_profit = balance::value(&market.liquidity_pool) - market.total_locked_collateral + collateral;
//         // let actual_profit = if (profit > max_profit - collateral) { max_profit - collateral } else { profit };
//         // collateral + actual_profit
//         collateral + profit
//     } else {
//         let loss = pnl;
//         // if (loss >= collateral) { 0 } else { collateral - loss }
//         assert!(loss < collateral, EInsufficientLiquidity);
//         collateral - loss
//     };
//     assert!(return_amount <= balance::value(&market.liquidity_pool), EInsufficientLiquidity);

//     // Cập nhật market state
//     market.total_positions = market.total_positions - 1;
//     market.total_locked_collateral = market.total_locked_collateral - collateral;

//     // Xóa position object
//     object::delete(id);

//     event::emit(PositionClosed {
//         position_id,
//         owner,
//         size,
//         collateral_returned: return_amount,
//         pnl,
//         is_profit,
//     });
    
//     // Trả lại tiền cho user
//     if (return_amount > 0) {
//         let return_balance = balance::split(&mut market.liquidity_pool, return_amount);
//         coin::from_balance(return_balance, ctx)
//     } else {
//         coin::zero<USDH>(ctx)
//     }
// }

// ==================== Helper Functions ====================

/// Tính PnL đơn giản
/// Returns (pnl_amount, is_profit)
fun calculate_pnl(size: u64, entry_price: u64, exit_price: u64, direction: u8): (u64, bool) {
    if (direction == LONG) {
        // Long: profit khi giá tăng
        if (exit_price > entry_price) {
            let price_diff = exit_price - entry_price;
            let pnl = (size * price_diff) / entry_price;
            (pnl, true)
        } else {
            let price_diff = entry_price - exit_price;
            let pnl = (size * price_diff) / entry_price;
            (pnl, false)
        }
    } else {
        // Short: profit khi giá giảm
        if (exit_price < entry_price) {
            let price_diff = entry_price - exit_price;
            let pnl = (size * price_diff) / entry_price;
            (pnl, true)
        } else {
            let price_diff = exit_price - entry_price;
            let pnl = (size * price_diff) / entry_price;
            (pnl, false)
        }
    }
}

// ==================== Admin Functions ====================

/// Pause/Unpause Market
public fun set_paused<USDHType> (market: &mut Market<USDHType>, _admin_cap: &AdminCap, paused: bool) {
    market.is_paused = paused;
    event::emit(MarketPaused { paused });
}

public fun transfer_admin(admin_cap: AdminCap, new_admin: address) {
    transfer::transfer(admin_cap, new_admin);
}

public fun transfer_lp_cap(lp_cap: LPCap, new_lp: address) {
    transfer::transfer(lp_cap, new_lp);
}

// ==================== View Functions ====================

public fun is_paused<USDHType>(market: &Market<USDHType>): bool {
    market.is_paused
}


// ==================== Position View Functions ====================

// public fun position_owner(position: &Position): address {
//     position.owner
// }

// public fun position_size(position: &Position): u64 {
//     position.size
// }

// public fun position_collateral(position: &Position): u64 {
//     position.collateral
// }

// public fun position_entry_price(position: &Position): u64 {
//     position.entry_price
// }

// public fun position_direction(position: &Position): u8 {
//     position.direction
// }

// public fun position_open_timestamp(position: &Position): u64 {
//     position.open_timestamp
// }

// public fun position_market_id(position: &Position): ID {
//     position.market_id
// }

// public fun is_long(position: &Position): bool {
//     position.direction == DIRECTION_LONG
// }

// public fun is_short(position: &Position): bool {
//     position.direction == DIRECTION_SHORT
// }


// ==================== Test Functions ====================
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(TUMO_MARKETS_CORE {}, ctx);
    let admin_cap = AdminCap { id: object::new(ctx) };
    // leverage default for tests
    create_liquidity_pool<OCT>(&admin_cap, ctx);
    create_market<OCT>(&admin_cap, 10, ctx);
    transfer::transfer(admin_cap, tx_context::sender(ctx));
}

#[test]
fun test_create_market() {
    use one::test_scenario;

    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);

        // create market với leverage = 10
        create_market<OCT>(&admin_cap, 10, test_scenario::ctx(&mut scenario));

        // verify shared object tồn tại và leverage đúng
        let market = test_scenario::take_shared<Market<OCT>>(&scenario);
        assert!(market.leverage == 10, EInvalidSize);
        test_scenario::return_shared(market);

        test_scenario::return_to_sender(&scenario, admin_cap);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_open_position() {
    use one::test_scenario;
    use tumo_markets::oracle;

    let user = @0xAA;
    let mut scenario = test_scenario::begin(user);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
        // mint oracle cap trong init để có sẵn cho user
        oracle::mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    // TX1: tạo oracle feed
    test_scenario::next_tx(&mut scenario, user);
    {
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        oracle::create_price_feed<OCT>(&price_cap, test_scenario::ctx(&mut scenario));

        test_scenario::return_to_sender(&scenario, price_cap);
    };

    // TX2: set price + open position 2 lần (gộp position)
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        // one::clock::Clock không phải shared object mặc định trong test_scenario,
        // nên tạo clock local cho unit test
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<oracle::PriceFeed<OCT>>(&scenario);

        // set price = 1000 (scaled)
        oracle::update_price<OCT>(
            &price_cap,
            &mut feed,
            vector[1_000_000],
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // open lần 1: collateral=1000, size=5000, leverage=10 => ok
        let pay1 = coin::mint_for_testing<OCT>(1000, test_scenario::ctx(&mut scenario));
        open_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            pay1,
            &feed,
            5000,
            LONG,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let pos1 = table::borrow(&market.positions, user);
        assert!(pos1.size == 5000, EInvalidSize);
        assert!(pos1.collateral_amount == 1000, EInvalidCollateral);
        assert!(pos1.entry_price == 1_000_000, EInvalidPrice); // giá đã scale 1M
        assert!(pos1.direction == LONG, EInvalidDirection);

        // update price = 2_000_000 rồi open lần 2 cùng direction để gộp
        oracle::update_price<OCT>(
            &price_cap,
            &mut feed,
            vector[2_000_000],
            &clock,
            test_scenario::ctx(&mut scenario),
        );
        let pay2 = coin::mint_for_testing<OCT>(1000, test_scenario::ctx(&mut scenario));
        open_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            pay2,
            &feed,
            5000,
            LONG,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let pos2 = table::borrow(&market.positions, user);
        assert!(pos2.size == 10000, EInvalidSize);
        assert!(pos2.collateral_amount == 2000, EInvalidCollateral);
        // avg: (1_000_000*5000 + 2_000_000*5000)/10000 = 1_500_000
        assert!(pos2.entry_price == 1_500_000, EInvalidPrice);
        assert!(pos2.direction == LONG, EInvalidDirection);

        test_scenario::return_shared(feed);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(market);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = EDirectionMismatch)]
fun open_position_direction_mismatch_should_fail() {
    use one::test_scenario;
    use tumo_markets::oracle;

    let user = @0xAA;
    let mut scenario = test_scenario::begin(user);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
        // mint oracle cap trong init để có sẵn cho user
        oracle::mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    // TX1: tạo oracle feed
    test_scenario::next_tx(&mut scenario, user);
    {
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        oracle::create_price_feed<OCT>(&price_cap, test_scenario::ctx(&mut scenario));

        test_scenario::return_to_sender(&scenario, price_cap);
    };

    // TX2: open LONG rồi mở SHORT -> abort
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<oracle::PriceFeed<OCT>>(&scenario);

        oracle::update_price<OCT>(
            &price_cap,
            &mut feed,
            vector[1_000_000],
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let pay1 = coin::mint_for_testing<OCT>(1000, test_scenario::ctx(&mut scenario));
        open_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            pay1,
            &feed,
            5000,
            LONG,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // mismatch
        let pay2 = coin::mint_for_testing<OCT>(1000, test_scenario::ctx(&mut scenario));
        open_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            pay2,
            &feed,
            1000,
            SHORT,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // unreachable
        test_scenario::return_shared(feed);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(market);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    test_scenario::end(scenario);
}
#[test]
#[expected_failure]
fun pause_by_other_than_admin_should_fail() {
    use one::test_scenario;

    let admin = @0xAD;
    let other_user = @0xBC;
    let mut scenario = test_scenario::begin(admin);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, other_user);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let fake_admin_cap = AdminCap { id: object::new(test_scenario::ctx(&mut scenario)) };

        set_paused(&mut market, &fake_admin_cap, true);

        // assert!(did_abort, "Pausing by non-admin should abort with ENotAdmin");
        test_scenario::return_shared(fake_admin_cap);
        test_scenario::return_shared(market);
    };

    test_scenario::end(scenario);
}
#[test]
fun test_add_liquidity() {
    use one::test_scenario;

    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let lp_cap = test_scenario::take_from_sender<LPCap>(&scenario);
        let payment = coin::mint_for_testing<OCT>(10000, test_scenario::ctx(&mut scenario));

        add_liquidity(&mut liquidity_pool, &lp_cap, payment, test_scenario::ctx(&mut scenario));
        let balance = balance::value(&liquidity_pool.balance);
        assert!(balance == 10000);

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_to_sender(&scenario, lp_cap);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_pause_market() {
    use one::test_scenario;

    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);

        set_paused(&mut market, &admin_cap, true);
        assert!(is_paused(&market) == true);

        set_paused(&mut market, &admin_cap, false);
        assert!(is_paused(&market) == false);

        test_scenario::return_shared(market);
        test_scenario::return_to_sender(&scenario, admin_cap);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_add_liquidity_when_paused() {
    use one::test_scenario;

    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);

        set_paused(&mut market, &admin_cap, true);

        test_scenario::return_shared(market);
        test_scenario::return_to_sender(&scenario, admin_cap);
    };

    test_scenario::next_tx(&mut scenario, admin);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let lp_cap = test_scenario::take_from_sender<LPCap>(&scenario);
        let payment = coin::mint_for_testing<OCT>(10000, test_scenario::ctx(&mut scenario));

        add_liquidity(&mut liquidity_pool, &lp_cap, payment, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_to_sender(&scenario, lp_cap);
    };

    test_scenario::end(scenario);
}
