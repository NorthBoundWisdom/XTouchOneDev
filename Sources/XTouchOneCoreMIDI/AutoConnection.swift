/// Chooses an input for automatic, listen-only attachment from already validated online devices.
public enum XTouchOneAutoConnection {
    public static func selectInput(preferred: Int32?, online: [Int32]) -> Int32? {
        if let preferred { return online.contains(preferred) ? preferred : nil }
        return online.count == 1 ? online.first : nil
    }
}
