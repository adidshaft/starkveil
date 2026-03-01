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
