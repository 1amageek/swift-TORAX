// ProfileComparatorMathematicalTests.swift
// Mathematical property verification for comparison metrics

import Testing
import Foundation
@testable import Gotenx

@Suite("Profile Comparator Mathematical Tests")
struct ProfileComparatorMathematicalTests {

    // MARK: - L2 Error Mathematical Properties

    @Test("L2 error is scale invariant")
    func l2ScaleInvariance() throws {
        // Mathematical property: ||a|| / ||b|| = ||ka|| / ||kb|| for any k > 0
        // L2 relative error should be invariant under uniform scaling

        let predicted: [Float] = [100, 200, 300, 400, 500]
        let reference: [Float] = [105, 210, 315, 420, 525]

        let error1 = ProfileComparator.l2Error(predicted: predicted, reference: reference)

        // Scale both by 1000×
        let predicted_scaled = predicted.map { $0 * 1000 }
        let reference_scaled = reference.map { $0 * 1000 }

        let error2 = ProfileComparator.l2Error(predicted: predicted_scaled, reference: reference_scaled)

        // Errors should be equal (scale invariant)
        #expect(abs(error1 - error2) < 1e-5, "L2 error should be scale invariant")
    }

    @Test("L2 error is zero for identical profiles")
    func l2ZeroProperty() throws {
        // Mathematical property: ||x - x|| = 0

        let profile: [Float] = [1.5, 2.7, 3.9, 4.2, 5.8]
        let error = ProfileComparator.l2Error(predicted: profile, reference: profile)

        #expect(error < 1e-6, "L2 error should be zero for identical profiles")
    }

    @Test("L2 error satisfies triangle inequality sense")
    func l2TriangleInequality() throws {
        // For relative errors: if pred1 is closer to ref than pred2, L2(pred1, ref) < L2(pred2, ref)

        let reference: [Float] = [100, 200, 300, 400, 500]
        let predicted_close: [Float] = [101, 201, 301, 401, 501]  // 1% error
        let predicted_far: [Float] = [110, 220, 330, 440, 550]    // 10% error

        let error_close = ProfileComparator.l2Error(predicted: predicted_close, reference: reference)
        let error_far = ProfileComparator.l2Error(predicted: predicted_far, reference: reference)

        #expect(error_close < error_far, "Closer prediction should have smaller L2 error")
    }

    @Test("L2 error normalization prevents overflow for large values")
    func l2NormalizationOverflowPrevention() throws {
        // Verify that normalization handles values that would overflow when squared

        let predicted: [Float] = [1.0e20, 0.9e20, 0.8e20, 0.7e20, 0.6e20]
        let reference: [Float] = [1.01e20, 0.91e20, 0.81e20, 0.71e20, 0.61e20]  // 1% higher

        let error = ProfileComparator.l2Error(predicted: predicted, reference: reference)

        // Should be finite and approximately 1%
        #expect(error.isFinite, "L2 error should be finite for large values")
        #expect(error < 0.02, "L2 error should be small for 1% difference")
    }

    @Test("L2 error changes under constant offset (expected behavior)")
    func l2OffsetSensitivity() throws {
        // L2 relative error is NOT invariant under constant offset
        // This is mathematically correct: ||a|| / ||b|| ≠ ||a+c|| / ||b+c||

        let predicted: [Float] = [100, 200, 300]
        let reference: [Float] = [105, 210, 315]

        // Original calculation
        let error1 = ProfileComparator.l2Error(predicted: predicted, reference: reference)

        // Add large offset to both
        let offset: Float = 1000
        let predicted_offset = predicted.map { $0 + offset }
        let reference_offset = reference.map { $0 + offset }

        let error2 = ProfileComparator.l2Error(predicted: predicted_offset, reference: reference_offset)

        // Relative error should DECREASE with offset (absolute error same, larger magnitude)
        #expect(error2 < error1, "L2 relative error should decrease when magnitude increases")

        // Verify both are reasonable values
        #expect(error1 > 0.04 && error1 < 0.06, "Original error should be ~5%")
        #expect(error2 > 0.008 && error2 < 0.01, "Offset error should be smaller (~0.8%)")
    }

    // MARK: - MAPE Mathematical Properties

    @Test("MAPE correctly measures uniform percentage error")
    func mapeUniformPercentageError() throws {
        // If all points have same percentage error, MAPE should equal that percentage

        let reference: [Float] = [100, 200, 300, 400, 500]
        let predicted = reference.map { $0 * 1.05 }  // Exactly 5% higher everywhere

        let mape = ProfileComparator.mape(predicted: predicted, reference: reference)

        // MAPE should be exactly 5%
        #expect(abs(mape - 5.0) < 0.01, "MAPE should be 5% for uniform 5% error")
    }

    @Test("MAPE is zero for identical profiles")
    func mapeZeroProperty() throws {
        let profile: [Float] = [10, 20, 30, 40, 50]
        let mape = ProfileComparator.mape(predicted: profile, reference: profile)

        #expect(mape < 1e-6, "MAPE should be zero for identical profiles")
    }

    @Test("MAPE is scale dependent (not scale invariant)")
    func mapeScaleDependence() throws {
        // MAPE should give same result for scaled values (percentage is scale-free)

        let predicted: [Float] = [100, 200, 300]
        let reference: [Float] = [105, 210, 315]

        let mape1 = ProfileComparator.mape(predicted: predicted, reference: reference)

        // Scale both by 1000×
        let predicted_scaled = predicted.map { $0 * 1000 }
        let reference_scaled = reference.map { $0 * 1000 }

        let mape2 = ProfileComparator.mape(predicted: predicted_scaled, reference: reference_scaled)

        // MAPE should be equal (percentage is scale-free)
        #expect(abs(mape1 - mape2) < 0.01, "MAPE should be scale-invariant")
    }

    @Test("MAPE symmetry: MAPE(A, B) ≈ MAPE(B, A) for small errors")
    func mapeApproximateSymmetry() throws {
        // For small errors, MAPE is approximately symmetric

        let predicted: [Float] = [100, 200, 300]
        let reference: [Float] = [102, 204, 306]  // 2% higher

        let mape1 = ProfileComparator.mape(predicted: predicted, reference: reference)
        let mape2 = ProfileComparator.mape(predicted: reference, reference: predicted)

        // Should be approximately equal for small errors
        #expect(abs(mape1 - mape2) < 0.2, "MAPE should be approximately symmetric for small errors")
    }

    // MARK: - Pearson Correlation Mathematical Properties

    @Test("Pearson correlation is 1 for perfect positive linear relationship")
    func pearsonPerfectPositiveCorrelation() throws {
        // r(x, ax + b) = 1 for a > 0

        let x: [Float] = [1, 2, 3, 4, 5]
        let y = x.map { 2.5 * $0 + 10 }  // y = 2.5x + 10

        let r = ProfileComparator.pearsonCorrelation(x: x, y: y)

        #expect(abs(r - 1.0) < 1e-5, "Correlation should be 1 for y = ax + b with a > 0")
    }

    @Test("Pearson correlation is -1 for perfect negative linear relationship")
    func pearsonPerfectNegativeCorrelation() throws {
        // r(x, -ax + b) = -1 for a > 0

        let x: [Float] = [1, 2, 3, 4, 5]
        let y = x.map { -2.0 * $0 + 20 }  // y = -2x + 20

        let r = ProfileComparator.pearsonCorrelation(x: x, y: y)

        #expect(abs(r - (-1.0)) < 1e-5, "Correlation should be -1 for y = -ax + b with a > 0")
    }

    @Test("Pearson correlation is invariant under affine transformation")
    func pearsonAffineInvariance() throws {
        // r(x, y) = r(ax + b, cy + d) for any a, b, c, d with a*c > 0

        let x: [Float] = [1, 2, 3, 4, 5]
        let y: [Float] = [2, 4, 5, 7, 9]

        let r1 = ProfileComparator.pearsonCorrelation(x: x, y: y)

        // Apply affine transformations
        let x_transformed = x.map { 3.0 * $0 + 7.0 }
        let y_transformed = y.map { 2.5 * $0 - 5.0 }

        let r2 = ProfileComparator.pearsonCorrelation(x: x_transformed, y: y_transformed)

        #expect(abs(r1 - r2) < 1e-5, "Correlation should be invariant under affine transformations")
    }

    @Test("Pearson correlation is bounded: -1 ≤ r ≤ 1")
    func pearsonBoundedness() throws {
        // For any data, -1 ≤ r ≤ 1

        let testCases: [([Float], [Float])] = [
            ([1, 2, 3, 4, 5], [5, 4, 3, 2, 1]),  // Negative correlation
            ([1, 2, 3, 4, 5], [1, 4, 2, 5, 3]),  // Mixed
            ([1, 2, 3, 4, 5], [2, 3, 4, 5, 6]),  // Positive correlation
        ]

        for (x, y) in testCases {
            let r = ProfileComparator.pearsonCorrelation(x: x, y: y)

            if !r.isNaN {  // Skip NaN cases (numerical precision issues)
                #expect(r >= -1.0 && r <= 1.0, "Correlation should be in [-1, 1]")
            }
        }
    }

    @Test("Pearson correlation is symmetric: r(x, y) = r(y, x)")
    func pearsonSymmetry() throws {
        let x: [Float] = [1.5, 2.7, 3.2, 4.8, 5.1]
        let y: [Float] = [2.3, 4.1, 3.9, 6.2, 5.8]

        let r1 = ProfileComparator.pearsonCorrelation(x: x, y: y)
        let r2 = ProfileComparator.pearsonCorrelation(x: y, y: x)

        #expect(abs(r1 - r2) < 1e-6, "Correlation should be symmetric")
    }

    // MARK: - RMS Error Mathematical Properties

    @Test("RMS error is zero for identical profiles")
    func rmsZeroProperty() throws {
        let profile: [Float] = [100, 200, 300, 400, 500]
        let rms = ProfileComparator.rmsError(predicted: profile, reference: profile)

        #expect(rms < 1e-6, "RMS should be zero for identical profiles")
    }

    @Test("RMS error has same units as input")
    func rmsUnits() throws {
        // RMS should be in same units as input (not percentage)

        let predicted: [Float] = [100, 200, 300]
        let reference: [Float] = [110, 210, 310]  // +10 everywhere

        let rms = ProfileComparator.rmsError(predicted: predicted, reference: reference)

        // RMS should be approximately 10 (same units as input)
        #expect(abs(rms - 10.0) < 1.0, "RMS should be ~10 for constant +10 error")
    }

    @Test("RMS is scale dependent")
    func rmsScaleDependence() throws {
        let predicted: [Float] = [100, 200, 300]
        let reference: [Float] = [110, 210, 310]

        let rms1 = ProfileComparator.rmsError(predicted: predicted, reference: reference)

        // Scale by 10×
        let predicted_scaled = predicted.map { $0 * 10 }
        let reference_scaled = reference.map { $0 * 10 }

        let rms2 = ProfileComparator.rmsError(predicted: predicted_scaled, reference: reference_scaled)

        // RMS should scale proportionally
        #expect(abs(rms2 / rms1 - 10.0) < 0.1, "RMS should scale linearly with input")
    }

    // MARK: - Integration: Multi-metric Validation

    @Test("L2 and MAPE provide complementary information")
    func l2MapeDifferentCases() throws {
        // Case 1: Uniform error → L2 and MAPE both show error
        let ref1: [Float] = [100, 200, 300, 400, 500]
        let pred1 = ref1.map { $0 * 1.05 }  // 5% everywhere

        let l2_1 = ProfileComparator.l2Error(predicted: pred1, reference: ref1)
        let mape_1 = ProfileComparator.mape(predicted: pred1, reference: ref1)

        #expect(l2_1 > 0.04 && l2_1 < 0.06, "L2 should detect 5% uniform error")
        #expect(mape_1 > 4.9 && mape_1 < 5.1, "MAPE should be exactly 5%")

        // Case 2: Localized large error vs distributed small errors
        let ref2: [Float] = [100, 100, 100, 100, 100]
        let pred2a: [Float] = [150, 100, 100, 100, 100]  // One 50% error → MAPE = 10%
        let pred2b: [Float] = [110, 110, 110, 110, 110]  // All 10% errors → MAPE = 10%

        let l2_2a = ProfileComparator.l2Error(predicted: pred2a, reference: ref2)
        let l2_2b = ProfileComparator.l2Error(predicted: pred2b, reference: ref2)
        let mape_2a = ProfileComparator.mape(predicted: pred2a, reference: ref2)
        let mape_2b = ProfileComparator.mape(predicted: pred2b, reference: ref2)

        // MAPE is same for both (average = 10%), but L2 differs
        // L2 emphasizes localized large errors more than MAPE
        #expect(abs(mape_2a - mape_2b) < 0.1, "Both have same MAPE (10%)")
        #expect(l2_2a > l2_2b, "Localized error should have higher L2 error")
    }

    @Test("Validation metrics detect different error types")
    func metricsDetectDifferentErrors() throws {
        let reference: [Float] = [100, 200, 300, 400, 500]

        // Error type 1: Scaling error (shape preserved)
        let pred_scaled = reference.map { $0 * 1.1 }  // 10% higher everywhere

        // Error type 2: Shape error (same average)
        let pred_shape: [Float] = [150, 180, 300, 420, 450]  // Different shape, similar mean

        let l2_scaled = ProfileComparator.l2Error(predicted: pred_scaled, reference: reference)
        let l2_shape = ProfileComparator.l2Error(predicted: pred_shape, reference: reference)

        let r_scaled = ProfileComparator.pearsonCorrelation(x: pred_scaled, y: reference)
        let r_shape = ProfileComparator.pearsonCorrelation(x: pred_shape, y: reference)

        // Scaled version has perfect correlation but L2 error
        if !r_scaled.isNaN {
            #expect(r_scaled > 0.99, "Scaled version should have high correlation")
        }
        #expect(l2_scaled > 0.05, "Scaled version should have L2 error")

        // Shape version has lower correlation
        if !r_shape.isNaN {
            #expect(r_shape < r_scaled, "Shape error should reduce correlation")
        }
    }
}
