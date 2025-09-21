#!/bin/bash
set -e

echo "=== Super DCA Gauge - Clean Machine Setup ==="
echo

# Check prerequisites
echo "Checking prerequisites..."

# Check if foundry is installed
if ! command -v forge &> /dev/null; then
    echo "❌ Foundry not found. Installing..."
    
    # Install foundry
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc
    foundryup
    
    # Verify installation
    if ! command -v forge &> /dev/null; then
        echo "❌ Foundry installation failed"
        exit 1
    fi
    echo "✅ Foundry installed successfully"
else
    echo "✅ Foundry found: $(forge --version | head -n1)"
fi

# Check git
if ! command -v git &> /dev/null; then
    echo "❌ Git not found. Please install git first."
    exit 1
fi
echo "✅ Git found: $(git --version)"

# Initialize submodules if needed
echo
echo "Setting up repository dependencies..."
if [ -f ".gitmodules" ] && [ ! -f "lib/forge-std/foundry.toml" ]; then
    echo "Initializing git submodules..."
    git submodule update --init --recursive
    echo "✅ Submodules initialized"
else
    echo "✅ Submodules already initialized"
fi

# Install dependencies and build
echo
echo "Building project..."
forge build

if [ $? -eq 0 ]; then
    echo "✅ Build successful"
else
    echo "❌ Build failed"
    exit 1
fi

# Create .env.example if it doesn't exist
if [ ! -f ".env.example" ]; then
    echo
    echo "Creating .env.example template..."
    cat > .env.example << 'EOF'
# Deployment Configuration
DEPLOYER_PRIVATE_KEY=0x... # Private key for deployment (DO NOT COMMIT REAL KEYS)
BASE_RPC_URL=https://mainnet.base.org
OPTIMISM_RPC_URL=https://mainnet.optimism.io
UNICHAIN_RPC_URL=https://rpc.unichain.org

# Contract Addresses (update after deployment)
GAUGE_ADDRESS=0x...
STAKING_ADDRESS=0x...
LISTING_ADDRESS=0x...
DCA_TOKEN_ADDRESS=0xb1599CDE32181f48f89683d3C5Db5C5D2C7C93cc

# Operation Parameters
USER_TO_SET_INTERNAL=0x...
IS_INTERNAL=true
EOF
    echo "✅ Created .env.example template"
fi

echo
echo "=== Setup Complete ==="
echo "Next steps:"
echo "1. Copy .env.example to .env and fill in your values"
echo "2. Run tests: forge test -vv"
echo "3. Check coverage: forge coverage"
echo "4. Deploy contracts using scripts in script/ directory"
echo