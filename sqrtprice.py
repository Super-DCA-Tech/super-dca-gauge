import math

def calculate_sqrt_price(token0_reserve, token1_reserve, token0_decimals, token1_decimals):
    # Convert reserves to their lowest decimal representation
    token0_amount = token0_reserve * (10 ** token0_decimals)
    token1_amount = token1_reserve * (10 ** token1_decimals)

    # Calculate sqrt(price) * 2^96 using integer math to maintain precision
    # sqrtPriceX96 = sqrt(token1_amount / token0_amount) * 2^96
    # = sqrt( (token1_amount * 2^192) / token0_amount )
    # where 2^192 = (2^96)^2

    if token0_amount == 0:
        raise ValueError("Token0 reserve cannot be zero")

    numerator = token1_amount * (2**192)
    # Perform integer division
    price_ratio_scaled = numerator // token0_amount 
    
    # Calculate integer square root
    sqrt_price_x96 = math.isqrt(price_ratio_scaled)

    return sqrt_price_x96

def run_tests():
    print("\nRunning tests...")
    # Constants from lib/v4-core/test/utils/Constants.sol
    # SQRT_PRICE_X_Y means sqrt(X/Y) * 2^96
    # We'll use token0_reserve = Y, token1_reserve = X, and common decimals (e.g., 18)

    # Test case: SQRT_PRICE_1_1 = 79228162514264337593543950336
    # X=1, Y=1
    expected_1_1 = 79228162514264337593543950336
    actual_1_1 = calculate_sqrt_price(token0_reserve=1, token1_reserve=1, token0_decimals=18, token1_decimals=18)
    assert actual_1_1 == expected_1_1, f"Test SQRT_PRICE_1_1 failed: Expected {expected_1_1}, got {actual_1_1}"
    print("Test SQRT_PRICE_1_1 PASSED")

    # Test case: SQRT_PRICE_1_2 = 56022770974786139918731938227
    # X=1, Y=2
    expected_1_2 = 56022770974786139918731938227
    actual_1_2 = calculate_sqrt_price(token0_reserve=2, token1_reserve=1, token0_decimals=18, token1_decimals=18)
    assert actual_1_2 == expected_1_2, f"Test SQRT_PRICE_1_2 failed: Expected {expected_1_2}, got {actual_1_2}"
    print("Test SQRT_PRICE_1_2 PASSED")

    # Test case: SQRT_PRICE_1_4 = 39614081257132168796771975168
    # X=1, Y=4
    expected_1_4 = 39614081257132168796771975168
    actual_1_4 = calculate_sqrt_price(token0_reserve=4, token1_reserve=1, token0_decimals=18, token1_decimals=18)
    assert actual_1_4 == expected_1_4, f"Test SQRT_PRICE_1_4 failed: Expected {expected_1_4}, got {actual_1_4}"
    print("Test SQRT_PRICE_1_4 PASSED")

    # Test case: SQRT_PRICE_2_1 = 112045541949572279837463876454
    # X=2, Y=1
    expected_2_1 = 112045541949572279837463876454
    actual_2_1 = calculate_sqrt_price(token0_reserve=1, token1_reserve=2, token0_decimals=18, token1_decimals=18)
    assert actual_2_1 == expected_2_1, f"Test SQRT_PRICE_2_1 failed: Expected {expected_2_1}, got {actual_2_1}"
    print("Test SQRT_PRICE_2_1 PASSED")

    # Test case: SQRT_PRICE_4_1 = 158456325028528675187087900672
    # X=4, Y=1
    expected_4_1 = 158456325028528675187087900672
    actual_4_1 = calculate_sqrt_price(token0_reserve=1, token1_reserve=4, token0_decimals=18, token1_decimals=18)
    assert actual_4_1 == expected_4_1, f"Test SQRT_PRICE_4_1 failed: Expected {expected_4_1}, got {actual_4_1}"
    print("Test SQRT_PRICE_4_1 PASSED")

    # Test case: SQRT_PRICE_121_100 = 87150978765690771352898345369
    # X=121, Y=100
    expected_121_100 = 87150978765690771352898345369
    actual_121_100 = calculate_sqrt_price(token0_reserve=100, token1_reserve=121, token0_decimals=18, token1_decimals=18)
    assert actual_121_100 == expected_121_100, f"Test SQRT_PRICE_121_100 failed: Expected {expected_121_100}, got {actual_121_100}"
    print("Test SQRT_PRICE_121_100 PASSED")
    
    # Test case: SQRT_PRICE_99_100 = 78831026366734652303669917531
    # X=99, Y=100
    expected_99_100 = 78831026366734652303669917531
    actual_99_100 = calculate_sqrt_price(token0_reserve=100, token1_reserve=99, token0_decimals=18, token1_decimals=18)
    assert actual_99_100 == expected_99_100, f"Test SQRT_PRICE_99_100 failed: Expected {expected_99_100}, got {actual_99_100}"
    print("Test SQRT_PRICE_99_100 PASSED")

    # Test case: SQRT_PRICE_99_1000 = 24928559360766947368818086097
    # X=99, Y=1000
    expected_99_1000 = 24928559360766947368818086097
    actual_99_1000 = calculate_sqrt_price(token0_reserve=1000, token1_reserve=99, token0_decimals=18, token1_decimals=18)
    assert actual_99_1000 == expected_99_1000, f"Test SQRT_PRICE_99_1000 failed: Expected {expected_99_1000}, got {actual_99_1000}"
    print("Test SQRT_PRICE_99_1000 PASSED")

    # Test case: SQRT_PRICE_101_100 = 79623317895830914510639640423
    # X=101, Y=100
    expected_101_100 = 79623317895830914510639640423
    actual_101_100 = calculate_sqrt_price(token0_reserve=100, token1_reserve=101, token0_decimals=18, token1_decimals=18)
    assert actual_101_100 == expected_101_100, f"Test SQRT_PRICE_101_100 failed: Expected {expected_101_100}, got {actual_101_100}"
    print("Test SQRT_PRICE_101_100 PASSED")
    
    # Test case: SQRT_PRICE_1000_100 = 250541448375047931186413801569
    # X=1000, Y=100
    expected_1000_100 = 250541448375047931186413801569
    actual_1000_100 = calculate_sqrt_price(token0_reserve=100, token1_reserve=1000, token0_decimals=18, token1_decimals=18)
    assert actual_1000_100 == expected_1000_100, f"Test SQRT_PRICE_1000_100 failed: Expected {expected_1000_100}, got {actual_1000_100}"
    print("Test SQRT_PRICE_1000_100 PASSED")

    # Test case: SQRT_PRICE_1010_100 = 251791039410471229173201122529
    # X=1010, Y=100
    expected_1010_100 = 251791039410471229173201122529
    actual_1010_100 = calculate_sqrt_price(token0_reserve=100, token1_reserve=1010, token0_decimals=18, token1_decimals=18)
    assert actual_1010_100 == expected_1010_100, f"Test SQRT_PRICE_1010_100 failed: Expected {expected_1010_100}, got {actual_1010_100}"
    print("Test SQRT_PRICE_1010_100 PASSED")

    # Test case: SQRT_PRICE_10000_100 = 792281625142643375935439503360
    # X=10000, Y=100
    expected_10000_100 = 792281625142643375935439503360
    actual_10000_100 = calculate_sqrt_price(token0_reserve=100, token1_reserve=10000, token0_decimals=18, token1_decimals=18)
    assert actual_10000_100 == expected_10000_100, f"Test SQRT_PRICE_10000_100 failed: Expected {expected_10000_100}, got {actual_10000_100}"
    print("Test SQRT_PRICE_10000_100 PASSED")
    
    print("\nAll tests PASSED!")

if __name__ == "__main__":
    token0_reserve = 1000000000000000000 # 1 AAVE
    token1_reserve = 1000000000000000000000 # 1000 DCA
    token0_decimals = 18
    token1_decimals = 18

    sqrt_price = calculate_sqrt_price(token0_reserve, token1_reserve, token0_decimals, token1_decimals)   

    print(f"sqrtPriceX96 USDC/DCA: {sqrt_price}")
    print(f"sqrtPriceX96 (hex): {hex(sqrt_price)}")
    # run_tests()
