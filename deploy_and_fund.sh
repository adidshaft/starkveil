#!/bin/bash
set -e

# Configuration
RPC_URL="https://api.cartridge.gg/x/starknet/sepolia"
ACCOUNT_NAME="sepolia_deployer"

echo "=== 1. Deploying New PrivacyPool Contract ==="
cd contracts

CLASS_HASH=$(sncast --account $ACCOUNT_NAME declare --url $RPC_URL --contract-name PrivacyPool | grep class_hash | awk '{print $2}')
if [ -z "$CLASS_HASH" ]; then
    echo "Contract already declared. Fetching class hash..."
    # Fallback to known class hash if already declared
    CLASS_HASH="0x06f55e881019ffa68fdffed5fa0bc2ebb9cb1b8366ba44ab63dd5985f8cc7dec"
fi
echo "Class Hash: $CLASS_HASH"

echo "Deploying instance..."
DEPLOY_OUT=$(sncast --account $ACCOUNT_NAME deploy --url $RPC_URL --class-hash $CLASS_HASH)
CONTRACT_ADDRESS=$(echo "$DEPLOY_OUT" | grep "Contract Address:" | awk '{print $3}')

if [ -z "$CONTRACT_ADDRESS" ]; then
    echo "Deployment failed."
    echo "$DEPLOY_OUT"
    exit 1
fi

echo "✅ New PrivacyPool deployed at: $CONTRACT_ADDRESS"

echo "\n=== 2. Updating Swift App Configuration ==="
cd ..
sed -i '' "s/contractAddress = \".*\"/contractAddress = \"$CONTRACT_ADDRESS\"/g" ios/StarkVeil/StarkVeil/Core/NetworkEnvironment.swift
echo "✅ Updated NetworkEnvironment.swift"

echo "\n=== 3. Ready for End-to-End Testing ==="
echo "Please perform these steps:"
echo "1. Delete the StarkVeil app from your simulator/device."
echo "2. Rebuild and launch the app in Xcode."
echo "3. Create a NEW wallet or recover your existing one."
echo "4. Fund your wallet address with Sepolia STRK from https://starknet-faucet.vercel.app/"
echo "5. Try the Shield -> Transfer -> Unshield flow."
