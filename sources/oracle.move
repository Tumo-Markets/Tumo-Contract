module tumo_markets::oracle;

use one::clock::{Self, Clock};
use one::object::{Self, UID};
use one::transfer;
use one::tx_context::{Self, TxContext};

// --- Errors ---
const ENotAuthorized: u64 = 0;
const EInvalidPrice: u64 = 1;
const EStaleUpdate: u64 = 2;
const EInvalidInput: u64 = 3;

// --- Structs ---

/// Capability quản lý (Admin) - Được cấp cho người deploy contract
public struct AdminCap has key, store {
    id: UID,
}

public struct OracleConfig has key, store {
    id: UID,
    admin: address, // Địa chỉ admin dự phòng
    server: address, // Địa chỉ ví Server (Backend) được quyền update giá
}

/// Object lưu giá của từng Token
public struct PriceFeed<phantom CoinType> has key {
    id: UID,
    price: u64, // Giá (nhân với decimals)
    decimals: u8, // Số thập phân (ví dụ 9)
    last_updated: u64, // Timestamp lần update cuối (ms)
}

// --- Events ---

/// Event được bắn ra khi giá thay đổi để Indexer/BE theo dõi
public struct PriceUpdated has copy, drop {
    new_price: u64,
    timestamp: u64,
    updated_by: address,
}

fun init(ctx: &mut TxContext) {
    let admin = tx_context::sender(ctx);

    // Gửi AdminCap cho người deploy
    transfer::transfer(
        AdminCap {
            id: object::new(ctx),
        },
        admin,
    );

    // Chia sẻ OracleConfig để mọi người có thể đọc, nhưng chỉ Server mới dùng được trong logic
    transfer::share_object(OracleConfig {
        id: object::new(ctx),
        admin: admin,
        server: admin, // Mặc định server ban đầu là admin
    });
}

// --- Admin Functions ---

/// Thay đổi địa chỉ Server (Backend) được quyền update giá
public fun set_server(_: &AdminCap, config: &mut OracleConfig, new_server: address) {
    config.server = new_server;
}

/// Tạo một PriceFeed mới cho một Token mới (VD: Tạo object giá cho SUI)
public fun create_price_feed<CoinType>(
    _: &AdminCap,
    decimals: u8,
    ctx: &mut TxContext,
) {
    let feed = PriceFeed<CoinType> {
        id: object::new(ctx),
        price: 0, // Giá khởi điểm
        decimals,
        last_updated: 0,
    };
    // Chia sẻ object để ai cũng đọc được giá
    transfer::share_object(feed);
}

fun update_price_logic<CoinType>(
    feed: &mut PriceFeed<CoinType>,
    new_price: u64,
    clock: &Clock,
) {
    assert!(new_price > 0, EInvalidPrice);

    let current_timestamp = clock::timestamp_ms(clock);
    
    // 4. Kiểm tra timestamp không được cũ hơn lần update trước (tránh replay attack)
    assert!(current_timestamp >= feed.last_updated, EStaleUpdate);

    // 5. Update dữ liệu
    feed.price = new_price;
    feed.last_updated = current_timestamp;
}

public fun update_price<CoinType>(
    config: &OracleConfig,
    feeds: &mut vector<PriceFeed<CoinType>>,
    new_prices: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(config.server == tx_context::sender(ctx), ENotAuthorized);
    assert!(vector::length(feeds) == vector::length(&new_prices), EInvalidInput);

    let len = vector::length(feeds);
    let i = 0;
    while (i < len) {
        let feed = vector::borrow_mut(feeds, i);
        let new_price = new_prices[i];
        update_price_logic(feed, new_price, clock);
    }
}

public fun get_price<CoinType>(feed: &PriceFeed<CoinType>): (u64, u8, u64) {
    (feed.price, feed.decimals, feed.last_updated)
}

