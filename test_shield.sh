#!/bin/bash
set -e

RPC_URL="https://api.cartridge.gg/x/starknet/sepolia"
ACCOUNT_NAME="sepolia_deployer"

STRK_CONTRACT="0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"
PRIVACY_POOL="0x02d69236620a877ce24413b34dd45115bc72fd4cca8e3445546a9ce3d5be0abc"

AMOUNT_LOW="0x16345785d8a0000" # 0.1 STRK
AMOUNT_HIGH="0x0"
COMMITMENT="0x5217091dfec63f0513351a00820896fd2eaca65690848373cf9c2840480ee7f"
MEMO="0x123"

# Approve STRK
echo "Approving..."
sncast --account $ACCOUNT_NAME invoke --url $RPC_URL \
  --contract-address $STRK_CONTRACT \
  --function approve \
  --calldata $PRIVACY_POOL $AMOUNT_LOW $AMOUNT_HIGH \
  --l1-gas-price 51026796854554 \
  --l1-data-gas-price 359025539 \
  --l2-gas-price 205026796854554

# Shield
echo "Shielding..."
sncast --account $ACCOUNT_NAME invoke --url $RPC_URL \
  --contract-address $PRIVACY_POOL \
  --function shield \
  --calldata $STRK_CONTRACT $AMOUNT_LOW $AMOUNT_HIGH $COMMITMENT $MEMO \
  --l1-gas-price 51026796854554 \
  --l1-data-gas-price 359025539 \
  --l2-gas-price 205026796854554
