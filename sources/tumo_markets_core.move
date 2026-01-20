module tumo_markets::tumo_markets_core;

use one::balance::{Self, Balance};
use one::clock::{Self, Clock};
use one::coin::{Self, Coin};
use one::event;
use one::object::{Self, UID, ID};
use one::transfer;
use one::oct::OCT;
use one::tx_context::{Self, TxContext};
use tumo_markets::oracle::{Self, PriceFeed};
use one::bls12381::UncompressedG1;

// ==================== Error Codes ====================
const ENotAdmin: u64 = 0;
const EMarketPaused: u64 = 1;
const EInsufficientLiquidity: u64 = 2;
const EZeroAmount: u64 = 3;
const EInvalidDirection: u64 = 4;
const EInvalidSize: u64 = 5;
const EInvalidCollateral: u64 = 6;
const EPositionNotFound: u64 = 7;
const ENotPositionOwner: u64 = 8;

// ==================== Constants ====================
const DIRECTION_LONG: u8 = 1;
const DIRECTION_SHORT: u8 = 2;

public struct LiquidityPool<phantom USDHType> has key {
    id: UID,
    balance: Balance<USDHType>,
}
// ==================== Market ====================

public struct Market<phantom CoinXType> has key { // Trading Market for CoinX/USDH
    id: UID,
    is_paused: bool,
}


// ==================== Position Entity (The Ticket) ====================
/// Đối tượng đại diện cho vị thế của User
/// Mỗi Position là một "Ticket" riêng biệt
public struct Position has key, store {
    id: UID,
    owner: address,
    size: u64,
    collateral: u64,
    entry_price: u64,
    direction: u8,
    open_timestamp: u64,
    market_id: ID,
}

// ==================== Admin Capability ====================
public struct AdminCap has key, store {
    id: UID,
}

/// Quyền LP (Liquidity Provider) để nạp/rút thanh khoản
public struct LPCap has key, store {
    id: UID,
}

// ==================== Events ====================
public struct MarketInitialized has copy, drop {
    market_id: ID,
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
    size: u64,
    collateral: u64,
    entry_price: u64,
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

public fun create_market<CoinXType>(_admin_cap: &AdminCap, ctx: &mut TxContext) {
    let copy_market = Market<CoinXType> {
        id: object::new(ctx),
        is_paused: false,
    };
    let market_id = object::id(&copy_market);
    transfer::share_object(copy_market);
    event::emit(MarketInitialized {
        market_id,
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

/// Mở một Position mới (Long hoặc Short)
// public fun open_position_and_deposit_liquidity<USDHType, CoinXType>(
//     market: &mut Market<CoinXType>,
//     payment_collateral_coin: Coin<USDHType>,
//     size: u64,
//     oracle: &PriceFeed<CoinXType>,
//     direction: u8,
//     clock: &Clock,
//     ctx: &mut TxContext,
// ) {
//     assert!(!market.is_paused, EMarketPaused);
//     assert!(size > 0, EInvalidSize);
//     assert!(direction == DIRECTION_LONG || direction == DIRECTION_SHORT, EInvalidDirection);

//     let (entry_price, decimals, last_updated) = oracle.get_price();

//     let owner = tx_context::sender(ctx);
//     let collateral = coin::value(&payment_collateral_coin);
//     assert!(collateral > 0, EInvalidCollateral);

//     let available_liquidity = balance::value(&market.liquidity_pool);
//     assert!(available_liquidity >= size, EInsufficientLiquidity);

//     // Nạp collateral vào pool
//     let collateral_balance = coin::into_balance(collateral_coin);
//     balance::join(&mut market.liquidity_pool, collateral_balance);

//     // Cập nhật market state
//     market.total_positions = market.total_positions + 1;
//     market.total_locked_collateral = market.total_locked_collateral + collateral;

//     let timestamp = clock::timestamp_ms(clock);
//     let market_id = object::id(market);

//     // Tạo Position object
//     let position = Position {
//         id: object::new(ctx),
//         owner,
//         size,
//         collateral,
//         entry_price,
//         direction,
//         open_timestamp: timestamp,
//         market_id,
//     };

//     let position_id = object::id(&position);

//     event::emit(PositionOpened {
//         position_id,
//         owner,
//         size,
//         collateral,
//         entry_price,
//         direction,
//         timestamp,
//     });

//     transfer::transfer(position, owner);
// }

// /// Đóng Position và trả lại collateral (+ PnL nếu có)
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
    if (direction == DIRECTION_LONG) {
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

/// Transfer AdminCap cho admin mới
public fun transfer_admin(admin_cap: AdminCap, new_admin: address) {
    transfer::transfer(admin_cap, new_admin);
}

/// Transfer LPCap cho LP mới
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

// ==================== Constants Getters ====================
public fun direction_long(): u8 { DIRECTION_LONG }

public fun direction_short(): u8 { DIRECTION_SHORT }

// ==================== Test Functions ====================
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(TUMO_MARKETS_CORE {}, ctx);
    let admin_cap = AdminCap { id: object::new(ctx) };
    create_market<OCT>(&admin_cap, ctx);
    create_liquidity_pool<OCT>(&admin_cap, ctx);
    transfer::transfer(admin_cap, tx_context::sender(ctx));
}

#[test]
fun test_add_liquidity() {
    use one::test_scenario;
    use one::coin;

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
