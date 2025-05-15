import math

def calculate_sqrt_price(token0_reserve, token1_reserve, token0_decimals, token1_decimals):
    # Convert reserves to their lowest decimal representation
    token0_amount = token0_reserve * (10 ** token0_decimals)
    token1_amount = token1_reserve * (10 ** token1_decimals)

    # Calculate the price ratio
    price_ratio = token1_amount / token0_amount

    # Calculate the square root of the price ratio
    sqrt_price = math.sqrt(price_ratio)

    # Convert to sqrtPriceX96 format (multiply by 2^96)
    sqrt_price_x96 = int(sqrt_price * (2 ** 96))

    return sqrt_price_x96

# Example usage
usdc_reserve = 6300000 # 6.3 USDC
eth_reserve = 100000000000000000 # 0.01 ETH
dca_reserve = 473600000000000000000 # 473.6 DCA
usdc_decimals = 6
eth_decimals = 18
dca_decimals = 18

sqrt_price = calculate_sqrt_price(usdc_reserve, dca_reserve, usdc_decimals, dca_decimals)   
sqrt_price_eth = calculate_sqrt_price(eth_reserve, dca_reserve, eth_decimals, dca_decimals)

print(f"sqrtPriceX96 USDC/DCA: {sqrt_price}")
print(f"sqrtPriceX96 (hex): {hex(sqrt_price)}")
print(f"sqrtPriceX96 ETH/DCA: {sqrt_price_eth}")
print(f"sqrtPriceX96 (hex): {hex(sqrt_price_eth)}")
