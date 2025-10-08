import SwiftUI

/// A pill-shaped button that displays update status and provides access to update actions.
struct UpdatePill: View {
    /// The update view model that provides the current state and information
    @ObservedObject var model: UpdateViewModel
    
    /// The actions that can be performed on updates
    let actions: UpdateUIActions
    
    /// Whether the update popover is currently visible
    @State private var showPopover = false
    
    var body: some View {
        if model.state != .idle {
            pillButton
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    UpdatePopoverView(model: model, actions: actions)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
    
    /// The pill-shaped button view that displays the update badge and text
    @ViewBuilder
    private var pillButton: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 6) {
                UpdateBadge(model: model)
                    .frame(width: 14, height: 14)
                
                Text(model.text)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(model.backgroundColor)
            )
            .foregroundColor(model.foregroundColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.stateTooltip)
    }
}
