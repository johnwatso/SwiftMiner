import AppKit
import SwiftUI

/// A button that offers a friend invitation through the standard macOS share
/// sheet.
///
/// SwiftUI's `ShareLink` discards the `subject` and `message` it is given on
/// macOS, so Mail opened with an empty subject line and nothing but the raw
/// invitation URL in the body. `NSSharingServicePicker` presents the same
/// system share sheet, and it does let the invitation carry an email subject
/// and a formatted body alongside the URL.
struct InvitationShareButton<Label: View>: View {
    let invitation: SwiftMinerInvitation
    @ViewBuilder var label: () -> Label

    @State private var shareRequest = 0

    var body: some View {
        Button { shareRequest += 1 } label: { label() }
            .background(InvitationSharePresenter(invitation: invitation, shareRequest: shareRequest))
    }
}

/// Anchors the share sheet to the button and carries the invitation into it.
private struct InvitationSharePresenter: NSViewRepresentable {
    let invitation: SwiftMinerInvitation
    let shareRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ anchor: NSView, context: Context) {
        guard shareRequest > 0, shareRequest != context.coordinator.presentedRequest else { return }
        context.coordinator.presentedRequest = shareRequest
        context.coordinator.present(invitation, from: anchor)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate {
        var presentedRequest = 0
        private var picker: NSSharingServicePicker?
        private var subject = ""

        func present(_ invitation: SwiftMinerInvitation, from anchor: NSView) {
            subject = invitation.subject

            // The formatted body is what Mail composes; the URL is what
            // Messages, AirDrop, and Copy take, and what the share sheet
            // unfurls into its link preview.
            let picker = NSSharingServicePicker(items: [invitation.richBody, invitation.invitationURL])
            picker.delegate = self
            self.picker = picker
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            sharingServicesForItems items: [Any],
            proposedSharingServices proposedServices: [NSSharingService]
        ) -> [NSSharingService] {
            for service in proposedServices {
                service.subject = subject
            }
            return proposedServices
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            service?.subject = subject
            picker = nil
        }
    }
}
