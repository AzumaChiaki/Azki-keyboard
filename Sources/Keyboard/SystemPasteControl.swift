// SPDX-License-Identifier: MIT
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class KeyboardPasteContext {
    weak var controller: KeyboardViewController?
    init(controller: KeyboardViewController) { self.controller = controller }
}

/// Each rendered control keeps an immutable document ticket. Replacing the ticket
/// creates a new receiver, so a delayed system callback cannot adopt a new field.
@MainActor
struct SystemPasteControl: UIViewRepresentable {
    let pasteContext: KeyboardPasteContext
    let ticket: KeyboardInputTicket

    func makeCoordinator() -> PasteReceiver { PasteReceiver(context: pasteContext, ticket: ticket) }

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .large
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        control.accessibilityIdentifier = "AzkiSystemPasteControl"
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {
        control.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
    }

    @MainActor
    final class PasteReceiver: UIResponder {
        let context: KeyboardPasteContext
        let ticket: KeyboardInputTicket

        init(context: KeyboardPasteContext, ticket: KeyboardInputTicket) {
            self.context = context
            self.ticket = ticket
            super.init()
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])
        }

        override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
            itemProviders.count == 1
                && itemProviders[0].hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                && itemProviders[0].canLoadObject(ofClass: NSString.self)
        }

        override func paste(itemProviders: [NSItemProvider]) {
            context.controller?.receivePaste(itemProviders, ticket: ticket)
        }
    }
}
