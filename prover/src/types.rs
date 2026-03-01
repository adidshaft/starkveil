use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Note {
    pub value: String, // String to handle large U256 numbers via JSON
    pub asset_id: String,
    pub owner_ivk: String,
    pub memo: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Nullifier {
    pub nullifier_hash: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct TransferPayload {
    pub proof: Vec<String>, // Mock felt252 array
    pub nullifiers: Vec<String>,
    pub new_commitments: Vec<String>,
    pub fee: String,
}

#[derive(Serialize, Deserialize, Debug)]
pub enum FFIResult {
    // Previously this held a pre-serialized JSON String, forcing Swift to
    // parse twice. Now embeds the typed payload directly so the Swift caller
    // only decodes one JSON layer.
    Success(TransferPayload),
    Error(String),
}

pub const ZERO_HASHES_20: [&str; 21] = [
    "0x0",
    "0x293d3e8a80f400daaaffdd5932e2bcc8814bab8f414a75dcacf87318f8b14c5",
    "0x296ec483967ad3fbe3407233db378b6284cc1fcc78d62457b97a4be6744ad0d",
    "0x4127be83b42296fe28f98f8fdda29b96e22e5d90501f7d31b84e729ec2fac3f",
    "0x33883305ab0df1ab7610153578a4d510b845841b84d90ed993133ce4ce8f827",
    "0x40e4093fe5af73becf6507f475a529a78e49f604539ea5f3547059b5e7f1076",
    "0x55dac7437527a89b6c03ecb7141193e30a38f87324f3da22f3b8ce7411a88cd",
    "0x1ec859a19ca9ab8d8663eb85a09cfb902326fc14b3a2121569ed2847a9c22bf",
    "0x765e137cda6685830cf14ec5298f46097e78a3be06aa15beced907f1a22d9fd",
    "0x5d25d6b8f11e34542cc850407899926bd61e253dd776477996151f6554f3da1",
    "0x4a21358c3e754766216b4c93ecfae222e86822f746e706e563f3a05ef398959",
    "0x754ef42b3e3b74dfa72b4d3a1d209e42bb1ca97ff2c88ff1855345f5b357e48",
    "0x2bcb136aacbdb24b04af1e4bb0b3ffbb498fb4e18eed0a9ea6d67d1e364483b",
    "0x5217091dfec63f0513351a00820896fd2eaca65690848373cf9c2840480ee7f",
    "0x16e1846f39b0d2925c60d7e0e99a304ed5e1ddf1244dc7d93046c2ce6510cdf",
    "0x3a7e107c9eef537905902c3c3acc6204353c06e8916274c97c56725ff2e3b95",
    "0xb2d71ff5f414c577fb3e1d946ed639e1e84f31c53c6a7af1b8f97522be62ca",
    "0x7672e9549873d8f291e72a50ae711641339836f38eebb8bbd219f311ea36d07",
    "0x384bf7a44fc20b2de2c7c0655256b2cc64cecd66cacf75821d9716d08ef4326",
    "0x688a48d473aaa2ecfa9bfe6fc46d0bf3d755f380db6b9e7fa9c792f5e9353c6",
    "0x2dbdbece8787cd765854509dbff122cd2ca371f2d7a15550cdc513950311734"
];
