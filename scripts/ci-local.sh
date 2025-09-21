#!/bin/bash
set -e

echo "=== Super DCA Gauge - CI Local Runner ==="
echo "This script runs the same checks as the CI pipeline locally"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status
print_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✅ $2${NC}"
    else
        echo -e "${RED}❌ $2${NC}"
        exit 1
    fi
}

print_warning() {
    echo -e "${YELLOW}⚠️ $1${NC}"
}

# Check if we're in the right directory
if [ ! -f "foundry.toml" ]; then
    echo -e "${RED}❌ Not in project root directory. Please run from super-dca-gauge/${NC}"
    exit 1
fi

echo "Current directory: $(pwd)"
echo "Foundry version: $(forge --version | head -n1)"
echo

# Step 1: Clean build
echo "Step 1: Clean build"
forge clean
forge build --sizes
print_status $? "Clean build completed"
echo

# Step 2: Run tests with verbosity
echo "Step 2: Running test suite"
forge test -vv
print_status $? "All tests passed"
echo

# Step 3: Gas report
echo "Step 3: Gas usage report"
forge test --gas-report
print_status $? "Gas report generated"
echo

# Step 4: Coverage report
echo "Step 4: Code coverage analysis"
if command -v lcov &> /dev/null; then
    forge coverage --report lcov
    lcov --list coverage/lcov.info
    print_status $? "Coverage report generated with lcov"
else
    forge coverage
    print_warning "lcov not installed - using basic coverage report"
fi
echo

# Step 5: Check for common issues
echo "Step 5: Static analysis checks"

# Check for TODO/FIXME comments
echo "Checking for TODO/FIXME comments..."
TODO_COUNT=$(grep -r "TODO\|FIXME" src/ test/ script/ --include="*.sol" | wc -l)
if [ $TODO_COUNT -gt 0 ]; then
    print_warning "Found $TODO_COUNT TODO/FIXME comments"
    grep -r "TODO\|FIXME" src/ test/ script/ --include="*.sol" || true
else
    echo -e "${GREEN}✅ No TODO/FIXME comments found${NC}"
fi

# Check for hardcoded addresses (excluding known constants)
echo "Checking for hardcoded addresses..."
HARDCODED=$(grep -r "0x[0-9a-fA-F]\{40\}" src/ --include="*.sol" | grep -v "DCA_TOKEN\|CREATE2_DEPLOYER\|PERMIT2" | wc -l)
if [ $HARDCODED -gt 0 ]; then
    print_warning "Found $HARDCODED potential hardcoded addresses"
    grep -r "0x[0-9a-fA-F]\{40\}" src/ --include="*.sol" | grep -v "DCA_TOKEN\|CREATE2_DEPLOYER\|PERMIT2" || true
else
    echo -e "${GREEN}✅ No unexpected hardcoded addresses found${NC}"
fi

# Check contract sizes
echo "Checking contract sizes..."
forge build --sizes | grep -E "(SuperDCAGauge|SuperDCAStaking|SuperDCAListing)" || true

# Step 6: Documentation checks
echo
echo "Step 6: Documentation validation"

# Check if audit docs exist
if [ -f "docs/security/AUDIT_DOC.md" ]; then
    echo -e "${GREEN}✅ Security audit documentation exists${NC}"
else
    print_warning "Security audit documentation missing"
fi

# Check if README is up to date
if [ -f "README.md" ]; then
    echo -e "${GREEN}✅ README.md exists${NC}"
else
    print_warning "README.md missing"
fi

echo
echo "=== CI Local Check Summary ==="
echo -e "${GREEN}✅ All checks completed successfully${NC}"
echo "Your code is ready for CI pipeline"
echo

# Optional: Run specific test if provided
if [ $# -eq 1 ]; then
    echo "Running specific test: $1"
    forge test --match-test "$1" -vvv
fi