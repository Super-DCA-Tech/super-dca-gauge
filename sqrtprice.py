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
usdc_reserve = 1000000000000000000
usdt_reserve = 1700000000000000000000
usdc_decimals = 18
usdt_decimals = 18

sqrt_price = calculate_sqrt_price(usdc_reserve, usdt_reserve, usdc_decimals, usdt_decimals)

print(f"sqrtPriceX96: {sqrt_price}")
print(f"sqrtPriceX96 (hex): {hex(sqrt_price)}")
