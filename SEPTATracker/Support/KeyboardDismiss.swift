import SwiftUI
import UIKit

/// A "hide keyboard" button that floats just above the keyboard while it's showing.
/// Works for `.searchable` fields too, where a `.keyboard` toolbar doesn't reliably appear.
private struct KeyboardDismissButton: ViewModifier {
    @State private var keyboardVisible = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if keyboardVisible {
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 36)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator)))
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.2)) { keyboardVisible = false }
            }
    }
}

extension View {
    /// Adds a floating "hide keyboard" button above the keyboard.
    func keyboardDismissButton() -> some View { modifier(KeyboardDismissButton()) }
}
