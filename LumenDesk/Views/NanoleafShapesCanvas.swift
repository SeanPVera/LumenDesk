import SwiftUI

extension NanoleafRGB {
    /// The panel colour as SwiftUI draws it: the exact bytes a Shapes panel
    /// is sent, nothing re-derived.
    var swiftUIColor: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}
