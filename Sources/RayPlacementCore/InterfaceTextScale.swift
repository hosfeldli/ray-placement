import Foundation

public enum InterfaceTextScale {
    public static func normalized(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return min(1.4, max(0.85, (value * 20).rounded() / 20))
    }
}
