import Foundation

/// En fjäder (massa–fjäder–dämpare) som löses **analytiskt**: tillståndet efter tiden `t`
/// räknas ut exakt i stället för att stegas fram numeriskt. Resultatet beror därför inte på
/// bildfrekvensen — 30, 60 och 120 bilder/s ger samma rörelse.
///
///     m·x'' + c·x' + k·x = 0,   ω₀ = √(k/m),   ζ = c / (2√(k·m))
///
/// `x` är avståndet till målet. ζ < 1 svänger lite förbi (underdämpad), ζ = 1 kommer fram
/// så fort som möjligt utan att svänga (kritiskt dämpad), ζ > 1 kryper fram (överdämpad).
public struct Spring: Equatable, Sendable {
    public var tension: Double   // k
    public var mass: Double      // m
    public var friction: Double  // c

    public init(tension: Double, mass: Double = 1, friction: Double) {
        self.tension = tension; self.mass = mass; self.friction = friction
    }

    public var omega0: Double { (tension / mass).squareRoot() }
    public var zeta: Double { friction / (2 * (tension * mass).squareRoot()) }

    /// Profiler från utredningen (Screen Studio-liknande, portade från Cap).
    public static let cursorDefault = Spring(tension: 170, mass: 1, friction: 20)
    public static let cursorSnappy = Spring(tension: 700, mass: 1, friction: 30)
    public static let cursorDrag = Spring(tension: 136, mass: 1.2, friction: 26)
    /// Betraktningsfönstrets panorering: överdämpad, så bilden aldrig studsar.
    public static let viewport = Spring(tension: 240, mass: 3.375, friction: 80)
    public static let zoomIn = Spring(tension: 200, mass: 1, friction: 26)
    public static let zoomOut = Spring(tension: 120, mass: 1, friction: 22)

    /// Avstånd och hastighet efter tiden `t`, från avstånd `x0` och hastighet `v0`.
    public func solve(displacement x0: Double, velocity v0: Double, t: Double) -> (x: Double, v: Double) {
        let w = omega0
        let z = zeta
        guard t > 0, w > 0 else { return (x0, v0) }
        if abs(z - 1) < 1e-6 {
            // Kritiskt dämpad.
            let e = exp(-w * t)
            let b = v0 + w * x0
            let x = e * (x0 + b * t)
            let v = e * (b - w * (x0 + b * t))
            return (x, v)
        } else if z < 1 {
            // Underdämpad.
            let wd = w * (1 - z * z).squareRoot()
            let e = exp(-z * w * t)
            let a = x0
            let b = (v0 + z * w * x0) / wd
            let c = cos(wd * t), s = sin(wd * t)
            let x = e * (a * c + b * s)
            let v = e * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s)
            return (x, v)
        } else {
            // Överdämpad.
            let r = (z * z - 1).squareRoot()
            let r1 = -w * (z - r)
            let r2 = -w * (z + r)
            let c2 = (v0 - r1 * x0) / (r2 - r1)
            let c1 = x0 - c2
            let e1 = exp(r1 * t), e2 = exp(r2 * t)
            return (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
        }
    }
}

/// En punkt eller ett värde som följer ett mål med en fjäder, steg för steg. Eftersom varje
/// steg löses exakt blir resultatet detsamma oavsett stegens längd, så länge målet bara byts
/// vid stegens gränser.
public struct SpringFollower: Sendable {
    public var position: Double
    public var velocity: Double = 0

    public init(_ position: Double) { self.position = position }

    public mutating func step(toward target: Double, dt: Double, spring: Spring) {
        let r = spring.solve(displacement: position - target, velocity: velocity, t: dt)
        position = target + r.x
        velocity = r.v
    }
}
