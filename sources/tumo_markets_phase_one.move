module tumo_markets_phase_one::tumo_markets_phase_one {

    use one::tx_context::{Self, TxContext};
    use one::object::{Self, UID, ID};
    use one::transfer;
    use one::coin::{Self, Coin};
    use one::balance::{Self, Balance};
    use one::event;
    use one::oct::OCT;
    use one::clock::{Self, Clock};

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

    // ==================== Market Entity (The Vault) ====================
    public struct Market has key {
        id: UID,
        admin: address,
        is_paused: bool,
        liquidity_pool: Balance<OCT>,
        total_positions: u64,
        total_locked_collateral: u64,
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
        admin: address,
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
    public struct TUMO_MARKETS_PHASE_ONE has drop {}

    // ==================== Init Function ====================
    fun init(_otw: TUMO_MARKETS_PHASE_ONE, ctx: &mut TxContext) {
        let admin = tx_context::sender(ctx);
        
        let market = Market {
            id: object::new(ctx),
            admin,
            is_paused: false,
            liquidity_pool: balance::zero(),
            total_positions: 0,
            total_locked_collateral: 0,
        };

        let market_id = object::id(&market);
        transfer::share_object(market);

        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(admin_cap, admin);

        let lp_cap = LPCap {
            id: object::new(ctx),
        };
        transfer::transfer(lp_cap, admin);

        event::emit(MarketInitialized { market_id, admin });
    }

    // ==================== Liquidity Operations ====================
    public fun add_liquidity(
        market: &mut Market,
        _lp_cap: &LPCap,
        payment: Coin<OCT>,
        ctx: &mut TxContext
    ) {
        assert!(!market.is_paused, EMarketPaused);

        let provider = tx_context::sender(ctx);
        let amount = coin::value(&payment);
        assert!(amount > 0, EZeroAmount);

        // Nạp vào liquidity pool
        let payment_balance = coin::into_balance(payment);
        balance::join(&mut market.liquidity_pool, payment_balance);

        let total_liquidity = balance::value(&market.liquidity_pool);

        event::emit(LiquidityAdded {
            provider,
            amount,
            total_liquidity,
        });
    }

    /// Admin/LP rút thanh khoản từ Pool
    public fun remove_liquidity(
        market: &mut Market,
        _lp_cap: &LPCap,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<OCT> {
        assert!(!market.is_paused, EMarketPaused);
        assert!(amount > 0, EZeroAmount);

        let available_liquidity = balance::value(&market.liquidity_pool) - market.total_locked_collateral;
        assert!(available_liquidity >= amount, EInsufficientLiquidity);

        let provider = tx_context::sender(ctx);
        let withdrawn = balance::split(&mut market.liquidity_pool, amount);

        let total_liquidity = balance::value(&market.liquidity_pool);

        event::emit(LiquidityRemoved {
            provider,
            amount,
            total_liquidity,
        });

        coin::from_balance(withdrawn, ctx)
    }

    // ==================== Position Operations ====================

    /// Mở một Position mới (Long hoặc Short)
    public fun open_position(
        market: &mut Market,
        collateral_coin: Coin<OCT>,
        size: u64,
        entry_price: u64,
        direction: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!market.is_paused, EMarketPaused);
        assert!(size > 0, EInvalidSize);
        assert!(direction == DIRECTION_LONG || direction == DIRECTION_SHORT, EInvalidDirection);

        let owner = tx_context::sender(ctx);
        let collateral = coin::value(&collateral_coin);
        assert!(collateral > 0, EInvalidCollateral);

        
        let available_liquidity = balance::value(&market.liquidity_pool);
        assert!(available_liquidity >= size, EInsufficientLiquidity);

        // Nạp collateral vào pool
        let collateral_balance = coin::into_balance(collateral_coin);
        balance::join(&mut market.liquidity_pool, collateral_balance);

        // Cập nhật market state
        market.total_positions = market.total_positions + 1;
        market.total_locked_collateral = market.total_locked_collateral + collateral;

        let timestamp = clock::timestamp_ms(clock);
        let market_id = object::id(market);

        // Tạo Position object
        let position = Position {
            id: object::new(ctx),
            owner,
            size,
            collateral,
            entry_price,
            direction,
            open_timestamp: timestamp,
            market_id,
        };

        let position_id = object::id(&position);

        event::emit(PositionOpened {
            position_id,
            owner,
            size,
            collateral,
            entry_price,
            direction,
            timestamp,
        });

        transfer::transfer(position, owner);
    }


    /// Đóng Position và trả lại collateral (+ PnL nếu có)
    public fun close_position(
        market: &mut Market,
        position: Position,
        exit_price: u64,
        ctx: &mut TxContext
    ): Coin<OCT> {
        assert!(!market.is_paused, EMarketPaused);

    
        let Position {
            id,
            owner,
            size,
            collateral,
            entry_price,
            direction,
            open_timestamp: _,
            market_id: _,
        } = position;

        // Verify owner
        let sender = tx_context::sender(ctx);
        assert!(sender == owner, ENotPositionOwner);

        let position_id = object::uid_to_inner(&id);

        // Tính PnL (simplified)
        let (pnl, is_profit) = calculate_pnl(size, entry_price, exit_price, direction);

        // Tính số tiền trả lại
        let return_amount = if (is_profit) {
            let profit = pnl;
            // let max_profit = balance::value(&market.liquidity_pool) - market.total_locked_collateral + collateral;
            // let actual_profit = if (profit > max_profit - collateral) { max_profit - collateral } else { profit };
            // collateral + actual_profit
            collateral + profit
        } else {
            let loss = pnl;
            // if (loss >= collateral) { 0 } else { collateral - loss }
            assert!(loss < collateral, EInsufficientLiquidity);
            collateral - loss
        };
        assert!(return_amount <= balance::value(&market.liquidity_pool), EInsufficientLiquidity);

        // Cập nhật market state
        market.total_positions = market.total_positions - 1;
        market.total_locked_collateral = market.total_locked_collateral - collateral;

        // Xóa position object
        object::delete(id);

        event::emit(PositionClosed {
            position_id,
            owner,
            size,
            collateral_returned: return_amount,
            pnl,
            is_profit,
        });

        // Trả lại tiền cho user
        if (return_amount > 0) {
            let return_balance = balance::split(&mut market.liquidity_pool, return_amount);
            coin::from_balance(return_balance, ctx)
        } else {
            coin::zero<OCT>(ctx)
        }
    }

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
    public fun set_paused(
        market: &mut Market,
        _admin_cap: &AdminCap,
        paused: bool,
    ) {
        market.is_paused = paused;
        event::emit(MarketPaused { paused });
    }

    /// Transfer AdminCap cho admin mới
    public fun transfer_admin(
        admin_cap: AdminCap,
        new_admin: address,
    ) {
        transfer::transfer(admin_cap, new_admin);
    }

    /// Transfer LPCap cho LP mới
    public fun transfer_lp_cap(
        lp_cap: LPCap,
        new_lp: address,
    ) {
        transfer::transfer(lp_cap, new_lp);
    }

    // ==================== View Functions ====================

    public fun is_paused(market: &Market): bool {
        market.is_paused
    }

    public fun total_liquidity(market: &Market): u64 {
        balance::value(&market.liquidity_pool)
    }

    public fun available_liquidity(market: &Market): u64 {
        balance::value(&market.liquidity_pool) - market.total_locked_collateral
    }

    public fun total_positions(market: &Market): u64 {
        market.total_positions
    }

    public fun total_locked_collateral(market: &Market): u64 {
        market.total_locked_collateral
    }

    public fun admin(market: &Market): address {
        market.admin
    }

    // ==================== Position View Functions ====================

    public fun position_owner(position: &Position): address {
        position.owner
    }

    public fun position_size(position: &Position): u64 {
        position.size
    }

    public fun position_collateral(position: &Position): u64 {
        position.collateral
    }

    public fun position_entry_price(position: &Position): u64 {
        position.entry_price
    }

    public fun position_direction(position: &Position): u8 {
        position.direction
    }

    public fun position_open_timestamp(position: &Position): u64 {
        position.open_timestamp
    }

    public fun position_market_id(position: &Position): ID {
        position.market_id
    }

    public fun is_long(position: &Position): bool {
        position.direction == DIRECTION_LONG
    }

    public fun is_short(position: &Position): bool {
        position.direction == DIRECTION_SHORT
    }

    // ==================== Constants Getters ====================
    public fun direction_long(): u8 { DIRECTION_LONG }
    public fun direction_short(): u8 { DIRECTION_SHORT }

    // ==================== Test Functions ====================
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(TUMO_MARKETS_PHASE_ONE {}, ctx);
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
            let mut market = test_scenario::take_shared<Market>(&scenario);
            let lp_cap = test_scenario::take_from_sender<LPCap>(&scenario);
            let payment = coin::mint_for_testing<OCT>(10000, test_scenario::ctx(&mut scenario));

            add_liquidity(&mut market, &lp_cap, payment, test_scenario::ctx(&mut scenario));

            assert!(total_liquidity(&market) == 10000);
            assert!(available_liquidity(&market) == 10000);

            test_scenario::return_shared(market);
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
            let mut market = test_scenario::take_shared<Market>(&scenario);
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
    #[expected_failure(abort_code = EMarketPaused)]
    fun test_add_liquidity_when_paused() {
        use one::test_scenario;
        use one::coin;

        let admin = @0xAD;
        let mut scenario = test_scenario::begin(admin);

        {
            init_for_testing(test_scenario::ctx(&mut scenario));
        };

        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut market = test_scenario::take_shared<Market>(&scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);

            set_paused(&mut market, &admin_cap, true);

            test_scenario::return_shared(market);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut market = test_scenario::take_shared<Market>(&scenario);
            let lp_cap = test_scenario::take_from_sender<LPCap>(&scenario);
            let payment = coin::mint_for_testing<OCT>(10000, test_scenario::ctx(&mut scenario));

            add_liquidity(&mut market, &lp_cap, payment, test_scenario::ctx(&mut scenario));

            test_scenario::return_shared(market);
            test_scenario::return_to_sender(&scenario, lp_cap);
        };

        test_scenario::end(scenario);
    }

}
