import { Transaction } from "@onelabs/sui/transactions";
import { getFullnodeUrl, PaginatedCoins, SuiClient, SuiObjectResponse } from "@onelabs/sui/client";
import { signer } from "./elements";
import { sign } from "node:crypto";

/**
 * Điền các giá trị thực tế trước khi chạy
 */
import { ADMIN_CAP_ID, LP_CAP_ID, OCT_TYPE, PACKAGE_ID, USDH_TYPE, LIQUIDITY_POOL_ID, MARKET_OCT_ID, PRICE_FEED_CAP_ID , PRICE_FEED_ID} from "./object_id";
import { get } from "node:http";


export const client = new SuiClient({
    url: getFullnodeUrl("testnet"),
});

/**
 * Add liquidity: cần LPCap và Coin<OCT> (paymentCoinId)
 */
export function getCoinObject(coinType: string): Promise<PaginatedCoins> {
    const coins = client.getCoins({
        owner: signer.getPublicKey().toSuiAddress(),
        coinType: coinType,
    });
    return coins;
}
export function getMarketObjData(marketId: string): Promise<SuiObjectResponse> {
    const objInfo = client.getObject({
        id: marketId,
        options: { showDisplay: true, showType: true, showContent: true },
    });
    return objInfo;
}
export function getLiquidityPoolObjData(liquidityPoolId: string): Promise<SuiObjectResponse> {
    const objInfo = client.getObject({
        id: liquidityPoolId,
        options: { showDisplay: true, showType: true, showContent: true },
    });
    return objInfo;
}

// Lấy tất cả positions trong Market (Table là dynamic fields)
export async function getMarketPositions(marketId: string) {
    // Lấy Market object để tìm positions table ID
    const marketObj = await client.getObject({
        id: marketId,
        options: { showContent: true },
    });

    if (marketObj.data?.content?.dataType !== "moveObject") {
        throw new Error("Invalid market object");
    }

    const fields = (marketObj.data.content as any).fields;
    const positionsTableId = fields.positions.fields.id.id;

    // Lấy tất cả dynamic fields (positions) trong table
    const dynamicFields = await client.getDynamicFields({
        parentId: positionsTableId,
    });

    // Lấy chi tiết từng position
    const positions = await Promise.all(
        dynamicFields.data.map(async (field) => {
            const positionObj = await client.getDynamicFieldObject({
                parentId: positionsTableId,
                name: field.name,
            });
            return {
                owner: field.name.value, // address của owner
                position: (positionObj.data?.content as any)?.fields?.value?.fields,
            };
        })
    );

    return positions;
}

// Lấy position của một user cụ thể
export async function getUserPosition(marketId: string, userAddress: string) {
    const marketObj = await client.getObject({
        id: marketId,
        options: { showContent: true },
    });

    if (marketObj.data?.content?.dataType !== "moveObject") {
        throw new Error("Invalid market object");
    }

    const fields = (marketObj.data.content as any).fields;
    const positionsTableId = fields.positions.fields.id.id;

    try {
        const positionObj = await client.getDynamicFieldObject({
            parentId: positionsTableId,
            name: {
                type: "address",
                value: userAddress,
            },
        });
        return (positionObj.data?.content as any)?.fields?.value?.fields;
    } catch (e) {
        return null; // Position không tồn tại
    }
}

export function buildAddLiquidityTx(liquidity_pool: string, allCoins: PaginatedCoins, amount: bigint): Transaction {
    const coinsToMerge = allCoins.data;
    const tx = new Transaction();

    if (coinsToMerge.length >= 2) {
        // Sort coins by balance (optional, but good practice to merge smaller into larger)
        coinsToMerge.sort((a, b) => parseInt(b.balance) - parseInt(a.balance));

        const primaryCoin = coinsToMerge[0];
        const coinsToCombine = coinsToMerge.slice(1);

        // 2. Create a new transaction block
        tx.setSender(signer.getPublicKey().toSuiAddress());

        // 3. Merge the coins
        // The first coin is the destination; the rest are sources
        tx.mergeCoins(
            tx.object(primaryCoin.coinObjectId),
            coinsToCombine.map((coin) => tx.object(coin.coinObjectId)),
        );
    }



    const [paymentCoinId, _] = tx.splitCoins(coinsToMerge[0].coinObjectId, [amount]);

    tx.moveCall({
        target: `${PACKAGE_ID}::tumo_markets_core::add_liquidity`,
        arguments: [tx.object(liquidity_pool), tx.object(LP_CAP_ID), paymentCoinId],
        typeArguments: [USDH_TYPE],
    });
    return tx;
}

// /**
//  * Remove liquidity: trả về Coin<OCT>
//  */
export function buildRemoveLiquidityTx(amount: bigint): Transaction {
    const tx = new Transaction();
    const coin = tx.moveCall({
        target: `${PACKAGE_ID}::tumo_markets_core::remove_liquidity`,
        arguments: [tx.object(LIQUIDITY_POOL_ID), tx.object(LP_CAP_ID), tx.pure.u64(amount)],
        typeArguments: [USDH_TYPE],
    });

    tx.transferObjects([coin], signer.getPublicKey().toSuiAddress());
    return tx;
}

export function buildCreateLiquidityPoolTx(CoinType: string): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: `${PACKAGE_ID}::tumo_markets_core::create_liquidity_pool`,
        arguments: [tx.object(ADMIN_CAP_ID)],
        typeArguments: [CoinType],
    });
    return tx;
}

export function buildCreateMarketTx(CoinType: string): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: `${PACKAGE_ID}::tumo_markets_core::create_market`,
        arguments: [tx.object(ADMIN_CAP_ID), tx.pure.u8(5)],
        typeArguments: [CoinType],
    });
    return tx;
}

export function buildOpenPositionTx(direction: number, amount_collateral: bigint, leverage: number, allCoins: PaginatedCoins): Transaction {
    const tx = new Transaction();
    let coinsToMerge = allCoins.data;
    let size = amount_collateral * BigInt(leverage);

    if (coinsToMerge.length >= 2) {
        // Sort coins by balance (optional, but good practice to merge smaller into larger)
        coinsToMerge.sort((a, b) => parseInt(b.balance) - parseInt(a.balance));

        const primaryCoin = coinsToMerge[0];
        const coinsToCombine = coinsToMerge.slice(1);

        // 2. Create a new transaction block
        tx.setSender(signer.getPublicKey().toSuiAddress());

        // 3. Merge the coins
        // The first coin is the destination; the rest are sources
        tx.mergeCoins(
            tx.object(primaryCoin.coinObjectId),
            coinsToCombine.map((coin) => tx.object(coin.coinObjectId)),
        );
    }
    let [paymentCollateral, _] = tx.splitCoins(coinsToMerge[0].coinObjectId, [amount_collateral]);
    
    tx.moveCall({
        target: `${PACKAGE_ID}::tumo_markets_core::open_position`,
        arguments: [
            tx.object(MARKET_OCT_ID), 
            tx.object(LIQUIDITY_POOL_ID), 
            paymentCollateral, 
            tx.object(PRICE_FEED_ID),
            tx.pure.u64(size), // is_long
            tx.pure.u8(direction), // margin
            tx.object("0x6")
        ],
        typeArguments: [USDH_TYPE, OCT_TYPE],
    });
    return tx;
}

export function buildClosePosition(): Transaction {
    const tx = new Transaction();
    
    const coin = tx.moveCall({
        target: `${PACKAGE_ID}::tumo_markets_core::close_position`,
        arguments: [
            tx.object(MARKET_OCT_ID), 
            tx.object(LIQUIDITY_POOL_ID), 
            tx.object(PRICE_FEED_ID),
            tx.object("0x6")
        ],
        typeArguments: [USDH_TYPE, OCT_TYPE],
    });
    tx.transferObjects([coin], signer.getPublicKey().toSuiAddress());
    return tx;
}

export function buildCreatePriceFeedTx(): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: `${PACKAGE_ID}::oracle::create_price_feed`,
        arguments: [tx.object(PRICE_FEED_CAP_ID)],
        typeArguments: [OCT_TYPE],
    })
    return tx;
}

// Cập nhật giá cho PriceFeed (cần gọi trước khi open_position)
export function buildUpdatePriceTx(newPrice: bigint): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: `${PACKAGE_ID}::oracle::update_price`,
        arguments: [
            tx.object(PRICE_FEED_CAP_ID),
            tx.object(PRICE_FEED_ID),
            tx.pure.u64(newPrice),
            tx.object("0x6"), // Clock
        ],
        typeArguments: [OCT_TYPE],
    });
    return tx;
}

async function main() {
    
    let coins = await getCoinObject(USDH_TYPE);

    /** Test CreateLiquidityPool */
    // const rsCreateLiquidityPool = await client.signAndExecuteTransaction({
    //   transaction: buildCreateLiquidityPoolTx(USDH_TYPE),
    //   signer: signer,
    // });
    // console.log("Create Liquidity Pool result:");
    // console.log(rsCreateLiquidityPool);

    /** Test CreateMarket */
    // const rsCreateMarket = await client.signAndExecuteTransaction({
    //   transaction: buildCreateMarketTx(OCT_TYPE),
    //   signer: signer,
    // });
    // console.log("Create Market result:");
    // console.log(rsCreateMarket);

    /** Test AddLiquidity */
    // const rsAddLiquidity = await client.signAndExecuteTransaction({
    //     transaction: buildAddLiquidityTx(LIQUIDITY_POOL_ID, coins, 10n**9n),
    //     signer: signer,
    // });
    // console.log("Add Liquidity result:");
    // console.log(rsAddLiquidity);

    /** Test RemoveLiquidity */
    // const rsRemoveLiquidity = await client.signAndExecuteTransaction({
    //     transaction: buildRemoveLiquidityTx(10n**6n),
    //     signer: signer,
    // });
    // console.log("Remove Liquidity result:");
    // console.log(rsRemoveLiquidity);

    /**Create Price Feed */
    // const rsCreatePriceFeed = await client.signAndExecuteTransaction({
    //     transaction: buildCreatePriceFeedTx(),
    //     signer: signer,
    // });
    // console.log("Create Price Feed result:");
    // console.log(rsCreatePriceFeed);

    /** Update Price - CẦN GỌI TRƯỚC KHI OPEN POSITION */
    // Giá = 1_000_000 (1 USD với 6 decimals)
    // const rsUpdatePrice = await client.signAndExecuteTransaction({
    //     transaction: buildUpdatePriceTx(1_000_000n),
    //     signer: signer,
    // });
    // console.log("Update Price result:");
    // console.log(rsUpdatePrice);

    /** Test OpenPosition */
    const rsUpdatePrice1 = await client.signAndExecuteTransaction({
        transaction: buildUpdatePriceTx(1_000_000n),
        signer: signer,
    });
    const rsOpenPosition = await client.signAndExecuteTransaction({
        transaction: buildOpenPositionTx(1, 10n**6n, 5, coins),
        signer: signer,
    });
    console.log("Open Position result:");
    console.log(rsOpenPosition);
    
    const rsUpdatePrice = await client.signAndExecuteTransaction({
        transaction: buildUpdatePriceTx(900_000n),
        signer: signer,
    });

    /** Lấy tất cả positions trong Market */
    const allPositions = await getMarketPositions(MARKET_OCT_ID);
    console.log("All Positions in Market:");
    console.log(JSON.stringify(allPositions, null, 2));

    /** Lấy position của user hiện tại */
    const myAddress = signer.getPublicKey().toSuiAddress();
    const myPosition = await getUserPosition(MARKET_OCT_ID, myAddress);
    console.log(`\nMy Position (${myAddress}):`);
    console.log(JSON.stringify(myPosition, null, 2));

    
    /** Close Position */
    const rsClosePosition = await client.signAndExecuteTransaction({
        transaction: buildClosePosition(), // direction=0 (close), amount_collateral=0, leverage=1
        signer: signer,
    });
    console.log("Close Position result:");
    console.log(rsClosePosition);
}

main();
