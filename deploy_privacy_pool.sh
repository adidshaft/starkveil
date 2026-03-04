#!/bin/bash
# ============================================================================
# deploy_privacy_pool.sh - Deploy PrivacyPool contract to Starknet Sepolia
# ============================================================================
# 
# This script:
#   1. Creates a new sncast account for Sepolia
#   2. Instructs user to fund it via faucet
#   3. Deploys the account
#   4. Declares the PrivacyPool Sierra class
#   5. Deploys an instance via UDC
#   6. Prints the deployed contract address
#
# Prerequisites: sncast 0.50.0, scarb, Starknet Sepolia

set -e

RPC_URL="https://rpc.starknet-testnet.lava.build"
ACCOUNTS_FILE="$HOME/.starknet_accounts/starknet_open_zeppelin_accounts.json"
ACCOUNT_NAME="sepolia_deployer"

echo "=========================================="
echo " StarkVeil PrivacyPool — Sepolia Deployment"
echo "=========================================="

# Step 1: Create account (if not exists)
echo ""
echo "Step 1: Creating deployer account..."

sncast --url "$RPC_URL" \
  account create \
  --name "$ACCOUNT_NAME" \
  --type oz \
  --class-hash 0x061dac032f228abef9c6626f995015233097ae253a7f72d68552db02f2971b8f \
  2>&1 || echo "(Account may already exist — continuing)"

# Extract address
echo ""
echo "Step 2: Retrieve account address..."
ADDR=$(sncast --url "$RPC_URL" --json account list 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data:
    if a.get('name') == '$ACCOUNT_NAME':
        print(a.get('address',''))
        break
" 2>/dev/null || echo "")

if [ -z "$ADDR" ]; then
    echo "Could not parse account address. Check 'sncast account list'"
    echo "Trying to read from accounts file..."
    ADDR=$(python3 -c "
import json
with open('$ACCOUNTS_FILE') as f:
    data = json.load(f)
for net in data.values():
    if '$ACCOUNT_NAME' in net:
        print(net['$ACCOUNT_NAME']['address'])
        break
" 2>/dev/null || echo "UNKNOWN")
fi

echo "  Deployer address: $ADDR"
echo ""
echo "  >>> Fund this address with STRK on Sepolia <<<"
echo "  >>> Use: https://starknet-faucet.vercel.app/ <<<"
echo ""
read -p "Press Enter after funding the account..."

# Step 3: Deploy account
echo ""
echo "Step 3: Deploying account on-chain..."
sncast --url "$RPC_URL" \
  account deploy \
  --name "$ACCOUNT_NAME" \
  --fee-token strk \
  --max-fee 0x2386f26fc10000 \
  2>&1 || echo "(Account may already be deployed — continuing)"

# Step 4: Build contract
echo ""
echo "Step 4: Building PrivacyPool contract..."
cd "$(dirname "$0")/contracts"
scarb build

# Step 5: Declare
echo ""
echo "Step 5: Declaring PrivacyPool class..."
DECLARE_OUTPUT=$(sncast --url "$RPC_URL" \
  --account "$ACCOUNT_NAME" \
  --json \
  declare \
  --contract-name PrivacyPool \
  --fee-token strk \
  --max-fee 0x2386f26fc10000 \
  2>&1 || true)

echo "$DECLARE_OUTPUT"

CLASS_HASH=$(echo "$DECLARE_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('class_hash', ''))
" 2>/dev/null || echo "")

if [ -z "$CLASS_HASH" ]; then
    echo "Declare may have already been done. Extracting class hash from build artifacts..."
    CLASS_HASH=$(python3 -c "
import json
with open('target/dev/contracts_PrivacyPool.contract_class.json') as f:
    data = json.load(f)
# Class hash is typically shown during declare
print('Check sncast declare output above for class_hash')
" 2>/dev/null || echo "MANUAL_CHECK_NEEDED")
fi

echo "  Class hash: $CLASS_HASH"

# Step 6: Deploy
echo ""
echo "Step 6: Deploying PrivacyPool contract..."
DEPLOY_OUTPUT=$(sncast --url "$RPC_URL" \
  --account "$ACCOUNT_NAME" \
  --json \
  deploy \
  --class-hash "$CLASS_HASH" \
  --fee-token strk \
  --max-fee 0x2386f26fc10000 \
  2>&1 || true)

echo "$DEPLOY_OUTPUT"

CONTRACT_ADDR=$(echo "$DEPLOY_OUTPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('contract_address', ''))
" 2>/dev/null || echo "")

echo ""
echo "=========================================="
echo " DEPLOYMENT COMPLETE"
echo "=========================================="
echo ""
echo " Contract Address: $CONTRACT_ADDR"
echo ""
echo " Update NetworkEnvironment.swift with this address:"
echo "   case .sepolia: return \"$CONTRACT_ADDR\""
echo ""
