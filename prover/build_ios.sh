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

# Create XCFramework
echo "Creating XCFramework bundle..."
rm -rf target/StarkVeilProver.xcframework
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libstarkveil_prover.a \
    -library target/aarch64-apple-ios-sim/release/libstarkveil_prover.a \
    -output target/StarkVeilProver.xcframework

echo "Build successful! The XCFramework is located at:"
echo "- target/StarkVeilProver.xcframework"
