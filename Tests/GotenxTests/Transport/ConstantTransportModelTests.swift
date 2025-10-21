import Testing
import MLX
@testable import Gotenx

@Suite("ConstantTransportModel Tests")
struct ConstantTransportModelTests {

    @Test("ConstantTransportModel initialization")
    func testInitialization() {
        let model = ConstantTransportModel(
            chiIon: 1.0,
            chiElectron: 1.5,
            particleDiffusivity: 0.5,
            convectionVelocity: 0.0
        )

        #expect(model.name == "constant")
        #expect(model.chiIonValue == 1.0)
        #expect(model.chiElectronValue == 1.5)
    }

    @Test("ConstantTransportModel initialization from parameters")
    func testInitializationFromParams() {
        let params = TransportParameters(
            modelType: .constant,
            params: [
                "chi_ion": 2.0,
                "chi_electron": 2.5,
                "particle_diffusivity": 1.0,
                "convection_velocity": 0.5
            ]
        )

        let model = ConstantTransportModel(params: params)

        #expect(model.chiIonValue == 2.0)
        #expect(model.chiElectronValue == 2.5)
        #expect(model.particleDiffusivityValue == 1.0)
        #expect(model.convectionVelocityValue == 0.5)
    }

    @Test("ConstantTransportModel computes uniform coefficients")
    func testComputeCoefficients() {
        let model = ConstantTransportModel(
            chiIon: 1.0,
            chiElectron: 1.5
        )

        let profiles = CoreProfiles(
            ionTemperature: .full([10], value: Float(5.0)),
            electronTemperature: .full([10], value: Float(4.0)),
            electronDensity: .full([10], value: Float(3.0)),
            poloidalFlux: .full([10], value: Float(0.5))
        )

        let mesh = MeshConfig(
            nCells: 10,
            majorRadius: 3.0,
            minorRadius: 1.0,
            toroidalField: 2.5
        )
        let geometry = createGeometry(from: mesh)

        let params = TransportParameters(modelType: .constant)

        let coeffs = model.computeCoefficients(
            profiles: profiles,
            geometry: geometry,
            params: params
        )

        // Verify shape
        #expect(coeffs.chiIon.shape == [10])
        #expect(coeffs.chiElectron.shape == [10])

        // Verify values are constant
        let chiIonArray = coeffs.chiIon.value
        eval(chiIonArray)

        for i in 0..<10 {
            let value = chiIonArray[i].item(Float.self)
            #expect(abs(value - 1.0) < 1e-6)
        }
    }
}

@Suite("BohmGyroBohmTransportModel Tests")
struct BohmGyroBohmTransportModelTests {

    @Test("BohmGyroBohmTransportModel initialization")
    func testInitialization() {
        let model = BohmGyroBohmTransportModel(
            bohmCoeff: 1.0,
            gyroBhohmCoeff: 1.0
        )

        #expect(model.name == "bohm-gyrobohm")
        #expect(model.bohmCoeff == 1.0)
        #expect(model.gyroBhohmCoeff == 1.0)
    }

    @Test("BohmGyroBohmTransportModel computes diffusivities")
    func testComputeCoefficients() {
        let model = BohmGyroBohmTransportModel(
            bohmCoeff: 1.0,
            gyroBhohmCoeff: 1.0
        )

        let profiles = CoreProfiles(
            ionTemperature: .full([10], value: Float(5.0)),
            electronTemperature: .full([10], value: Float(4.0)),
            electronDensity: .full([10], value: Float(3.0)),
            poloidalFlux: .full([10], value: Float(0.5))
        )

        let mesh = MeshConfig(
            nCells: 10,
            majorRadius: 3.0,
            minorRadius: 1.0,
            toroidalField: 2.5
        )
        let geometry = createGeometry(from: mesh)

        let params = TransportParameters(modelType: .bohmGyrobohm)

        let coeffs = model.computeCoefficients(
            profiles: profiles,
            geometry: geometry,
            params: params
        )

        // Verify shape
        #expect(coeffs.chiIon.shape == [10])
        #expect(coeffs.chiElectron.shape == [10])

        // Verify values are positive
        let chiElectronArray = coeffs.chiElectron.value
        eval(chiElectronArray)

        for i in 0..<10 {
            let value = chiElectronArray[i].item(Float.self)
            #expect(value > 0.0)
        }
    }
}
