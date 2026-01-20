import { Transaction } from "@onelabs/sui/transactions";
import { getFullnodeUrl, PaginatedCoins, SuiClient, SuiObjectResponse } from "@onelabs/sui/client";
import { signer } from "./elements";
import { sign } from "node:crypto";

/**
 * Điền các giá trị thực tế trước khi chạy
 */
export const PACKAGE_ID = "0x247654d14d0c7f1aeab5647bba02d69e2260ce54ae96d02c1a049505afccda92"; // package tumo_markets đã publish
export const ADMIN_CAP_ID = "0xf6fadf6d1f58b510a91278b43cf2d48f63b9ba7f2862b36977d5cb2dcdadb2ee"; // AdminCap object id
export const LP_CAP_ID = "0x9f2014bc1e56baf646fe4b54fba16f090393875e8b28ef04b26a0a75c4dfddb9"; // LPCap object id
export const OCT_TYPE = "0x0000000000000000000000000000000000000000000000000000000000000002::oct::OCT"; // nếu OCT là type riêng, chỉnh lại cho đúng
// export const USDH_TYPE = '0x2::coin_registry::Currency<0xdb178dd88808ca0718c6c9f19f7783a210f110abd05f72b76dde6e2e15bd86b2::usdh::USDH>'
export const USDH_TYPE = "0xdd0d096ded419429ca4cbe948aa01cedfc842eb151eb6a73af0398406a8cfb07::usdh::USDH";
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



    const [paymentCoinId] = tx.splitCoins(coinsToMerge[0].coinObjectId, [amount]);

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
        arguments: [tx.object(LP_CAP_ID), tx.pure.u64(amount)],
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
        arguments: [tx.object(ADMIN_CAP_ID)],
        typeArguments: [CoinType],
    });
    return tx;
}

// /**
//  * Open position
//  * - collateralCoinId: Coin<OCT> dùng làm collateral
//  * - size, entryPrice: u64
//  * - direction: 1 = long, 2 = short
//  */
// export function buildOpenPositionTx(
//   collateralCoinId: string,
//   size: bigint,
//   entryPrice: bigint,
//   direction: 1 | 2,
// ): Transaction {
//   const tx = new Transaction();
//   tx.moveCall({
//     target: `${PACKAGE_ID}::tumo_markets_core::open_position`,
//     arguments: [
//       tx.object(MARKET_ID),
//       tx.object(collateralCoinId),
//       tx.pure.u64(size),
//       tx.pure.u64(entryPrice),
//       tx.pure.u8(direction),
//       tx.object.clock(),
//       tx.txBlockData().gasData.owner,
//     ],
//     typeArguments: [OCT_TYPE],
//   });
//   return tx;
// }

// /**
//  * Close position
//  * - positionId: object Position
//  * - exitPrice: giá thoát u64
//  */
// export function buildClosePositionTx(positionId: string, exitPrice: bigint): Transaction {
//   const tx = new Transaction();
//   tx.moveCall({
//     target: `${PACKAGE_ID}::tumo_markets_core::close_position`,
//     arguments: [
//       tx.object(MARKET_ID),
//       tx.object(positionId),
//       tx.pure.u64(exitPrice),
//       tx.txBlockData().gasData.owner,
//     ],
//     typeArguments: [OCT_TYPE],
//   });
//   return tx;
// }

// /**
//  * Pause / Unpause market (admin)
//  */
// export function buildSetPausedTx(paused: boolean): Transaction {
//   const tx = new Transaction();
//   tx.moveCall({
//     target: `${PACKAGE_ID}::tumo_markets_core::set_paused`,
//     arguments: [
//       tx.object(MARKET_ID),
//       tx.object(ADMIN_CAP_ID),
//       tx.pure.bool(paused),
//     ],
//   });
//   return tx;
// }

// /**
//  * Transfer admin cap
//  */
// export function buildTransferAdminCapTx(newAdmin: string): Transaction {
//   const tx = new Transaction();
//   tx.moveCall({
//     target: `${PACKAGE_ID}::tumo_markets_core::transfer_admin`,
//     arguments: [tx.object(ADMIN_CAP_ID), tx.pure.address(newAdmin)],
//   });
//   return tx;
// }

// /**
//  * Transfer LP cap
//  */
// export function buildTransferLpCapTx(newLp: string): Transaction {
//   const tx = new Transaction();
//   tx.moveCall({
//     target: `${PACKAGE_ID}::tumo_markets_core::transfer_lp_cap`,
//     arguments: [tx.object(LP_CAP_ID), tx.pure.address(newLp)],
//   });
//   return tx;
// }

async function main() {
    // const rsCreateLiquidityPool = await client.signAndExecuteTransaction({
    //   transaction: buildCreateLiquidityPoolTx(USDH_TYPE),
    //   signer: signer,
    // });
    // console.log("Create Liquidity Pool result:");
    // console.log(rsCreateLiquidityPool);

    // const rsCreateMarket = await client.signAndExecuteTransaction({
    //   transaction: buildCreateMarketTx(OCT_TYPE),
    //   signer: signer,
    // });
    // console.log("Create Market result:");
    // console.log(rsCreateMarket);

    const coins = (await getCoinObject(USDH_TYPE));

    const result = await client.signAndExecuteTransaction({
        transaction: buildAddLiquidityTx("0x5b3b20f0d8eb53f35d8c715786f1c3ec02e61cab8d28032c50bcf0a5cc3e3911", coins, 10n**6n),
        signer: signer,
    });

    // // const result = await client.signAndExecuteTransaction({
    // //     transaction: buildRemoveLiquidityTx(10n**9n),
    // //     signer: signer,
    // // });

    console.log("Transaction result:");
    console.log(result);

    // console.log("OCT coins owned by signer:");
    // console.log(coins);
    // const marketData = await getMarketObjData('0xd953ea133ba28de5e70c8bf27840815d0012804fe2f4a197dbacb05ae9e3de0b');
    // console.log("Market object data:");
    // console.log(marketData);

    // const liquidityPoolData = await getLiquidityPoolObjData('0x0f86f22965a8564eb74e1dd304112265dca0bff235f3f083c3ce4877f33053be');
    // console.log("Liquidity Pool object data:");
    // console.log(liquidityPoolData);

    // const objects = await client.getOwnedObjects({
    //   owner: signer.getPublicKey().toSuiAddress(),
    //   options: { showType: true, showContent: true },
    //   filter: { StructType: OCT_TYPE },
    // });
    // console.log("OCT objects owned by signer:");
    // console.log(objects.data.map(object => (object as any).data.content.fields));
}

main();
