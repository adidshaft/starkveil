#!/bin/bash

# Exit on error
set -e

echo "Building StarkVeil Prover for iOS..."

# Ensure we have the target architectures
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim

# Build for both targets
echo "Building aarch64-apple-ios (Physical Device)..."
cargo build --target aarch64-apple-ios --release

echo "Building aarch64-apple-ios-sim (Simulator)..."
cargo build --target aarch64-apple-ios-sim --release

# Note: In a complete production setup, we would use `xcodebuild -create-xcframework` 
# here to bundle the .a files into an XCFramework for easier Xcode integration.
# For this phase, we ensure the static libraries compile successfully.

echo "Build successful! The static libraries are located in:"
echo "- target/aarch64-apple-ios/release/libstarkveil_prover.a"
echo "- target/aarch64-apple-ios-sim/release/libstarkveil_prover.a"
