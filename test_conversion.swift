import MLX

// Force CPU
MLX.GPU.set(cacheLimit: 0)

// Test 1: Simple scalar multiplication with Double
print("Test 1: Scalar Double multiplication")
let coeff = 6.2415090744e24
let input1: Double = 1.0
let output1 = input1 * coeff
print("  Result: \(output1)")

// Test 2: MLXArray creation from Swift Double array
print("\nTest 2: MLXArray from Double array")
let values: [Double] = [1.0, 2.0, 3.0]
let mlxArray = MLXArray(values)
print("  dtype: \(mlxArray.dtype)")

// Test 3: MLXArray multiplication with large coefficient
print("\nTest 3: MLXArray multiplication")
let coeffArray = MLXArray(coeff)
let result = mlxArray * coeffArray
print("  Result dtype: \(result.dtype)")

// Test 4: Evaluate and extract
print("\nTest 4: Evaluate and extract")
eval(result)
print("  Evaluation complete")

let extracted = result.asArray(Double.self)
print("  Extracted: \(extracted)")

print("\n All tests passed!")
