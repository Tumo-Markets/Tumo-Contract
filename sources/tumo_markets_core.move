module tumo_markets::tumo_markets_core;

use one::balance::{Self, Balance};
use one::clock::{Self, Clock};
use one::coin::{Self, Coin};
use one::event;
use one::object::{Self, UID, ID};
use one::oct::OCT;
use one::table::{Self, Table};
use one::transfer;
use one::tx_context::{Self, TxContext};
use tumo_markets::oracle::PriceFeed;

// ==================== Error Codes ====================
const ENotAdmin: u64 = 0;
const EMarketPaused: u64 = 1;
const EInvalidPrice: u64 = 2;
const EZeroAmount: u64 = 3;
const EInvalidDirection: u64 = 4;
const EInvalidSize: u64 = 5;
const EInvalidCollateral: u64 = 6;
const EPositionNotFound: u64 = 7;
const EDirectionMismatch: u64 = 8;
const EInsufficientLiquidity: u64 = 9;
const ECannotLiquidate: u64 = 10;

// ==================== Constants ====================
const LONG: u8 = 0;
const SHORT: u8 = 1;


public struct LiquidityPool<phantom LiquidityCoinType> has key {
    id: UID,
    balance: Balance<LiquidityCoinType>,
}
// ==================== Market ====================

public struct Market<phantom CoinXType> has key {
    // Trading Market for CoinX/LiquidityCoin
    id: UID,
    leverage: u8,
    is_paused: bool,
    positions: Table<address, Position<CoinXType>>,
}

// ==================== Position Entity (The Ticket) ====================

public struct Position<phantom CoinXType> has store {
    id: ID,
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
    position_id: ID,
    owner: address,
    market_id: ID,
    size: u64,
    collateral: u64,
    entry_price: u64,
    direction: u8,
    timestamp: u64,
}

public struct PositionUpdated has copy, drop {
    position_id: ID,
    owner: address,
    market_id: ID,
    new_size: u64,
    new_collateral: u64,
    new_entry_price: u64,
    direction: u8,
    timestamp: u64,
}

public struct PositionClosed has copy, drop {
    position_id: ID,
    owner: address,
    market_id: ID,
    size: u64,
    collateral_returned: u64,
    pnl: u64,
    is_profit: bool,
    close_price: u64,
}

public struct MarketPaused has copy, drop {
    paused: bool,
}

public struct PositionLiquidated has copy, drop {
    position_id: ID,
    owner: address,
    market_id: ID,
    liquidator: address,
    size: u64,
    collateral: u64,
    pnl: u64,
    amount_returned_to_liquidator: u64,
    timestamp: u64,
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
        positions: table::new(ctx),
    };
    let market_id = object::id(&copy_market);
    transfer::share_object(copy_market);
    event::emit(MarketInitialized {
        market_id,
        leverage,
    });
}

public fun create_liquidity_pool<LiquidityCoinType>(_admin_cap: &AdminCap, ctx: &mut TxContext) {
    let liquidity_pool = LiquidityPool<LiquidityCoinType> {
        id: object::new(ctx),
        balance: balance::zero(),
    };
    transfer::share_object(liquidity_pool);
}

// ==================== Liquidity Operations ====================
public fun add_liquidity<LiquidityCoinType>(
    liquidity_pool: &mut LiquidityPool<LiquidityCoinType>,
    _lp_cap: &LPCap,
    payment: Coin<LiquidityCoinType>,
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
public fun remove_liquidity<LiquidityCoinType>(
    liquidity_pool: &mut LiquidityPool<LiquidityCoinType>,
    _lp_cap: &LPCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<LiquidityCoinType> {
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

public fun open_position<LiquidityCoinType, CoinXType>(
    market: &mut Market<CoinXType>,
    liquidity_pool: &mut LiquidityPool<LiquidityCoinType>,
    payment_collateral_coin: Coin<LiquidityCoinType>,
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
    let market_id = object::uid_to_inner(&market.id);

    if (!table::contains(&market.positions, owner)) {
        assert!(payment_collateral > 0, EInvalidCollateral);
        // Check min collateral based on leverage
        assert!(payment_collateral * (market.leverage as u64) >= size, EInvalidSize);
        let position = Position<CoinXType> {
            id: object::id_from_address(tx_context::fresh_object_address(ctx)),
            owner,
            size,
            collateral_amount: payment_collateral,
            entry_price,
            direction,
            open_timestamp: timestamp,
        };

        let position_id = position.id;

        event::emit(PositionOpened {
            position_id,
            owner,
            market_id,
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

        let position_id = position.id;

        event::emit(PositionUpdated {
            position_id,
            owner,
            market_id,
            new_size,
            new_collateral,
            new_entry_price,
            direction,
            timestamp,
        });
    }
}

public fun close_position<LiquidityCoinType, CoinXType>(
    market: &mut Market<CoinXType>,
    liquidity_pool: &mut LiquidityPool<LiquidityCoinType>,
    oracle: &PriceFeed<CoinXType>,
    _clock: &Clock,
    ctx: &mut TxContext,
): Coin<LiquidityCoinType> {
    assert!(!market.is_paused, EMarketPaused);
    let sender = tx_context::sender(ctx);
    assert!(table::contains(&market.positions, sender), EPositionNotFound);

    let Position {
        id,
        owner,
        size,
        collateral_amount,
        entry_price,
        direction,
        open_timestamp: _,
    } = table::remove(&mut market.positions, sender);

    let position_id = id;

    let (exit_price, _last_updated) = oracle.get_price();
    assert!(exit_price > 0, EInvalidPrice);

    let (pnl, is_profit) = calculate_pnl(size, entry_price, exit_price, direction);

    let return_amount = if (is_profit) {
        collateral_amount + pnl
    } else {
        if (pnl >= collateral_amount) {
            0
        } else {
            collateral_amount - pnl
        }
    };

    // Ensure pool has enough liquidity to pay out
    assert!(balance::value(&liquidity_pool.balance) >= return_amount, EInsufficientLiquidity);

    event::emit(PositionClosed {
        position_id,
        owner,
        market_id: object::uid_to_inner(&market.id),
        size,
        collateral_returned: return_amount,
        pnl,
        is_profit,
        close_price: exit_price,
    });

    if (return_amount > 0) {
        let return_balance = balance::split<LiquidityCoinType>(&mut liquidity_pool.balance, return_amount);
        coin::from_balance<LiquidityCoinType>(return_balance, ctx)
    } else {
        coin::zero<LiquidityCoinType>(ctx)
    }
}

public fun liquidate<LiquidityCoinType, CoinXType>(
    market: &mut Market<CoinXType>,
    liquidity_pool: &mut LiquidityPool<LiquidityCoinType>,
    oracle: &PriceFeed<CoinXType>,
    clock: &Clock,
    liquidated_owner: address,
    ctx: &mut TxContext,
): Coin<LiquidityCoinType> {
    assert!(!market.is_paused, EMarketPaused);
    assert!(table::contains(&market.positions, liquidated_owner), EPositionNotFound);

    // Read-only check first (we need to borrow, but table borrow is immutable)
    let position = table::borrow(&market.positions, liquidated_owner);
    let size = position.size;
    let collateral_amount = position.collateral_amount;
    let entry_price = position.entry_price;
    let direction = position.direction;

    let (exit_price, _last_updated) = oracle.get_price();
    assert!(exit_price > 0, EInvalidPrice);

    let (pnl, is_profit) = calculate_pnl(size, entry_price, exit_price, direction);

    // Check liquidation condition
    // Liquidate if Collateral - Loss < Maintenance Margin (Size * 10%)
    // If profit, never liquidate (unless we implement funding fees which drain collateral, but not here yet)
    if (is_profit) {
        abort ECannotLiquidate
    };

    // PnL is loss here
    let loss = pnl;

    // maintenance_margin = size * 10 / 100
    let maintenance_margin_pct = (100/market.leverage) as u64;
    let maintenance_margin = (size * maintenance_margin_pct) / 100;

    // If Loss >= Collateral, it's already bankrupt.
    // If Collateral - Loss < Maintenance, it's liquidatable.
    // Equivalent: Collateral < Maintenance + Loss
    if (loss < collateral_amount) {
        let remaining_collateral = collateral_amount - loss;
        assert!(remaining_collateral < maintenance_margin, ECannotLiquidate);
    } else {};

    // Do Liquidation
    let Position {
        id,
        owner,
        size: _,
        collateral_amount: _,
        entry_price: _,
        direction: _,
        open_timestamp: _,
    } = table::remove(&mut market.positions, liquidated_owner);

    let position_id = id;

    // Calculate Reward
    // If bankrupt (loss >= collateral), remaining is 0. Liquidator gets 0. (Or we could pay small fee from pool if we want).
    // If liquidatable but not bankrupt, remaining = collateral - loss.
    // Reward = remaining * 10%.

    let return_amount = if (loss >= collateral_amount) {
        0
    } else {
        let remaining = collateral_amount - loss;
        remaining
    };

    // Ensure pool has enough
    assert!(balance::value(&liquidity_pool.balance) >= return_amount, EInsufficientLiquidity);

    let market_id = object::uid_to_inner(&market.id);
    event::emit(PositionLiquidated {
        position_id,
        owner,
        market_id,
        liquidator: tx_context::sender(ctx),
        size,
        collateral: collateral_amount,
        pnl: loss,
        amount_returned_to_liquidator: return_amount,
        timestamp: clock::timestamp_ms(clock),
    });

    if (return_amount > 0) {
        let return_balance = balance::split<LiquidityCoinType>(&mut liquidity_pool.balance, return_amount);
        coin::from_balance<LiquidityCoinType>(return_balance, ctx)
    } else {
        coin::zero<LiquidityCoinType>(ctx)
    }
}

public fun edit_market_leverage<CoinXType>(
    market: &mut Market<CoinXType>,
    _admin_cap: &AdminCap,
    new_leverage: u8,
) {
    market.leverage = new_leverage;
}

// ==================== Helper Functions ====================

/// Tính PnL đơn giản
/// Returns (pnl_amount, is_profit)
fun calculate_pnl(size: u64, entry_price: u64, exit_price: u64, direction: u8): (u64, bool) {
    if (direction == LONG) {
        // Long: profit triggers when exit_price > entry_price
        if (exit_price > entry_price) {
            let price_diff = exit_price - entry_price;
            // Use u128 to avoid overflow: size * price_diff can exceed u64 max
            let pnl = ((size as u128) * (price_diff as u128)) / (entry_price as u128);
            ((pnl as u64), true)
        } else {
            let price_diff = entry_price - exit_price;
            let pnl = ((size as u128) * (price_diff as u128)) / (entry_price as u128);
            ((pnl as u64), false)
        }
    } else {
        // Short: profit triggers when exit_price < entry_price
        if (exit_price < entry_price) {
            let price_diff = entry_price - exit_price;
            let pnl = ((size as u128) * (price_diff as u128)) / (entry_price as u128);
            ((pnl as u64), true)
        } else {
            let price_diff = exit_price - entry_price;
            let pnl = ((size as u128) * (price_diff as u128)) / (entry_price as u128);
            ((pnl as u64), false)
        }
    }
}

// ==================== Admin Functions ====================

/// Pause/Unpause Market
public fun set_paused<CoinXType>(
    market: &mut Market<CoinXType>,
    _admin_cap: &AdminCap,
    paused: bool,
) {
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

public fun is_paused<LiquidityCoinType>(market: &Market<LiquidityCoinType>): bool {
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
            1_000_000,
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
            2_000_000,
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
            1_000_000,
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

#[test]
fun test_close_position_profit() {
    use one::test_scenario;
    use tumo_markets::oracle;

    let user = @0xAA;
    let mut scenario = test_scenario::begin(user);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
        oracle::mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    // Prepare: Add Liquidity
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let lp_cap = test_scenario::take_from_sender<LPCap>(&scenario);
        let payment = coin::mint_for_testing<OCT>(100000, test_scenario::ctx(&mut scenario));
        add_liquidity(&mut liquidity_pool, &lp_cap, payment, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_to_sender(&scenario, lp_cap);
    };

    // Prepare: Create Price Feed
    test_scenario::next_tx(&mut scenario, user);
    {
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        oracle::create_price_feed<OCT>(&price_cap, test_scenario::ctx(&mut scenario));
        test_scenario::return_to_sender(&scenario, price_cap);
    };

    // Open Position LONG at 1000
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<oracle::PriceFeed<OCT>>(&scenario);

        // Price = 1000
        oracle::update_price<OCT>(
            &price_cap,
            &mut feed,
            1_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let collateral = coin::mint_for_testing<OCT>(1000, test_scenario::ctx(&mut scenario));
        open_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            collateral,
            &feed,
            5000, // 5x leverage
            LONG,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    // Close Position at 1200 (Profit)
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<oracle::PriceFeed<OCT>>(&scenario);

        // Price = 1200 (20% increase)
        oracle::update_price<OCT>(
            &price_cap,
            &mut feed,
            1_200_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // PnL calculation:
        // entry = 1000, exit = 1200, diff = 200
        // size = 5000
        // pnl = 5000 * 200 / 1000 = 1000
        // return = collateral (1000) + pnl (1000) = 2000

        let returned_coin = close_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            &feed,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        assert!(coin::value(&returned_coin) == 2000, 0);
        coin::burn_for_testing(returned_coin);

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_close_position_loss() {
    use one::test_scenario;
    use tumo_markets::oracle;

    let user = @0xAA;
    let mut scenario = test_scenario::begin(user);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
        oracle::mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    // Add Liquidity
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let lp_cap = test_scenario::take_from_sender<LPCap>(&scenario);
        let payment = coin::mint_for_testing<OCT>(100000, test_scenario::ctx(&mut scenario));
        add_liquidity(&mut liquidity_pool, &lp_cap, payment, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_to_sender(&scenario, lp_cap);
    };

    // Create oracle
    test_scenario::next_tx(&mut scenario, user);
    {
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        oracle::create_price_feed<OCT>(&price_cap, test_scenario::ctx(&mut scenario));
        test_scenario::return_to_sender(&scenario, price_cap);
    };

    // Open LONG at 1000
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
            1_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let collateral = coin::mint_for_testing<OCT>(1000, test_scenario::ctx(&mut scenario));
        open_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            collateral,
            &feed,
            5000,
            LONG,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    // Close at 900 (Loss)
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<oracle::PriceFeed<OCT>>(&scenario);

        // Price = 900 (-10%)
        oracle::update_price<OCT>(
            &price_cap,
            &mut feed,
            900_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // PnL calc:
        // diff = 100
        // pnl = 5000 * 100 / 1000 = 500
        // return = 1000 - 500 = 500

        let returned_coin = close_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            &feed,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        assert!(coin::value(&returned_coin) == 500, 0);
        coin::burn_for_testing(returned_coin);

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_liquidate_success() {
    use one::test_scenario;
    use tumo_markets::oracle;

    let user = @0xAA;
    let liquidator = @0xBB;
    let mut scenario = test_scenario::begin(user);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
        oracle::mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    // Add Liquidity
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let lp_cap = test_scenario::take_from_sender<LPCap>(&scenario);
        let payment = coin::mint_for_testing<OCT>(100000, test_scenario::ctx(&mut scenario));
        add_liquidity(&mut liquidity_pool, &lp_cap, payment, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_to_sender(&scenario, lp_cap);
    };

    // Create oracle
    test_scenario::next_tx(&mut scenario, user);
    {
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        oracle::create_price_feed<OCT>(&price_cap, test_scenario::ctx(&mut scenario));
        test_scenario::return_to_sender(&scenario, price_cap);
    };

    // Open LONG at 1000, Collateral 1000, Size 10000 (10x)
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
            1_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let collateral = coin::mint_for_testing<OCT>(1000, test_scenario::ctx(&mut scenario));
        open_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            collateral,
            &feed,
            10000,
            LONG,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    // Price Drops to 909 -> Liquidatable?
    // Size = 10000. Maintenance = 10% * 10000 = 1000.
    // Price drops 9% -> Loss = 10000 * 9% = 900.
    // Collateral - Loss = 1000 - 900 = 100.
    // 100 < 1000 -> Liquidatable!

    // Liquidate by liquidator

    // Update price as User
    test_scenario::next_tx(&mut scenario, user);
    {
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        let mut feed = test_scenario::take_shared<oracle::PriceFeed<OCT>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        // Price drop 10% => 900.
        // Loss = 1000. Collateral = 1000. Equity = 0. Bankrupt (but handled).
        // Try 910. Loss = 900. Remaining = 100. Maintenance = 1000. 100 < 1000. Liquidatable.
        oracle::update_price<OCT>(
            &price_cap,
            &mut feed,
            910_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    // Liquidate as Liquidator
    test_scenario::next_tx(&mut scenario, liquidator);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let feed = test_scenario::take_shared<oracle::PriceFeed<OCT>>(&scenario);

        let reward = liquidate<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            &feed,
            &clock,
            user, // owner to liquidate
            test_scenario::ctx(&mut scenario),
        );

        // Check reward
        // Loss = 10000 * (1000 - 910)/1000 = 900
        // Remaining = 1000 - 900 = 100
        // Reward = 10% of 100 = 10
        assert!(coin::value(&reward) == 10, 0);
        coin::burn_for_testing(reward);

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(feed);
        clock::destroy_for_testing(clock);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = ECannotLiquidate)]
fun test_liquidate_fail_healthy() {
    use one::test_scenario;
    use tumo_markets::oracle;

    let user = @0xAA;
    let liquidator = @0xBB;
    let mut scenario = test_scenario::begin(user);

    {
        init_for_testing(test_scenario::ctx(&mut scenario));
        oracle::mint_cap_for_testing(test_scenario::ctx(&mut scenario));
    };

    // Add Liquidity
    test_scenario::next_tx(&mut scenario, user);
    {
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let lp_cap = test_scenario::take_from_sender<LPCap>(&scenario);
        let payment = coin::mint_for_testing<OCT>(100000, test_scenario::ctx(&mut scenario));
        add_liquidity(&mut liquidity_pool, &lp_cap, payment, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_to_sender(&scenario, lp_cap);
    };

    // Create oracle
    test_scenario::next_tx(&mut scenario, user);
    {
        let price_cap = test_scenario::take_from_sender<oracle::PriceFeedCap>(&scenario);
        oracle::create_price_feed<OCT>(&price_cap, test_scenario::ctx(&mut scenario));
        test_scenario::return_to_sender(&scenario, price_cap);
    };

    // Open LONG
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
            1_000_000,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        let collateral = coin::mint_for_testing<OCT>(1000, test_scenario::ctx(&mut scenario));
        open_position<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            collateral,
            &feed,
            5000, // 5x
            LONG,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(feed);
        test_scenario::return_to_sender(&scenario, price_cap);
        clock::destroy_for_testing(clock);
    };

    // Liquidate immediately (Healthy)
    test_scenario::next_tx(&mut scenario, liquidator);
    {
        let mut market = test_scenario::take_shared<Market<OCT>>(&scenario);
        let mut liquidity_pool = test_scenario::take_shared<LiquidityPool<OCT>>(&scenario);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let feed = test_scenario::take_shared<oracle::PriceFeed<OCT>>(&scenario);

        // Price still 1000. No loss. Healthy. Should fail.
        let reward = liquidate<OCT, OCT>(
            &mut market,
            &mut liquidity_pool,
            &feed,
            &clock,
            user,
            test_scenario::ctx(&mut scenario),
        );

        coin::burn_for_testing(reward);
        test_scenario::return_shared(market);
        test_scenario::return_shared(liquidity_pool);
        test_scenario::return_shared(feed);
        clock::destroy_for_testing(clock);
    };

    test_scenario::end(scenario);
}
