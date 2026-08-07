import Foundation

/// Marker for the HerdrKit framework. Real types live in Protocol/, Runtime/, Terminal/.
public enum HerdrKit {
    /// Client protocol version this build speaks. Must match the bundled herdr binary.
    public static let protocolVersion: UInt32 = 19
}
