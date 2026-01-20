import * as dotenv from 'dotenv';
import { SuiClient, getFullnodeUrl } from '@onelabs/sui/client';
import { Ed25519Keypair } from '@onelabs/sui/keypairs/ed25519';
import { fromB64 } from '@onelabs/sui/utils';
dotenv.config();

const suiClient = new SuiClient({ url: getFullnodeUrl('testnet') });
const mnemonic = process.env.MNEMONIC!;
const signer = Ed25519Keypair.deriveKeypair(mnemonic, "m/44'/784'/0'/0'/0'");

export { suiClient, signer }