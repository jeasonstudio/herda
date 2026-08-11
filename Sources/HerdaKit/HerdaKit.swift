import Foundation

/// Marker for the HerdaKit framework. Real types live in Protocol/, Runtime/, Terminal/.
public enum HerdaKit {
    /// Client protocol version this build speaks. Must match the bundled herdr binary.
    public static let protocolVersion: UInt32 = 19
}
