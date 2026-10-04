import AppKit
import Foundation

// Review surface for an authenticated local client request. The caller resolves
// the target name from EventKit and supplies the current scope at decision time.
@MainActor
final class ExactActionApprovalUI {
    func review(
        _ proposal: ActionProposal,
        clientName: String,
        targetName: String,
        existingItemDescription: String?,
        in window: NSWindow,
        gate: ExactActionApproval,
        currentScope: @escaping () -> BridgeScope,
        completion: @escaping (Result<ApprovedAction, ActionApprovalError>) -> Void
    ) {
        precondition(proposal.command.isWrite)
        if proposal.itemID != nil &&
            (existingItemDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
            gate.cancel(ticketID: proposal.ticketID)
            completion(.failure(.invalidRequest))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Approve this one Calendar or Reminders change?"
        alert.informativeText = description(
            proposal, clientName: clientName, targetName: targetName,
            existingItemDescription: existingItemDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Approve Once")
        alert.addButton(withTitle: "Cancel")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(gate.approve(
                    ticketID: proposal.ticketID,
                    displayedDigest: proposal.digest,
                    scope: currentScope(),
                    now: Date().timeIntervalSince1970,
                    uptime: ProcessInfo.processInfo.systemUptime))
            } else {
                gate.cancel(ticketID: proposal.ticketID)
                completion(.failure(.cancelled))
            }
        }
    }

    private func description(_ proposal: ActionProposal, clientName: String, targetName: String,
                             existingItemDescription: String?) -> String {
        var lines = [
            "Client: \(String(reflecting: clientName))",
            "Action: \(proposal.command.rawValue)",
            "Collection: \(String(reflecting: targetName)) [\(proposal.targetID)]",
        ]
        if let title = proposal.title { lines.append("Proposed title: \(String(reflecting: title))") }
        if let itemID = proposal.itemID { lines.append("Item ID: \(itemID)") }
        if let existingItemDescription {
            lines.append("Current item: \(String(reflecting: existingItemDescription))")
        }
        if let start = proposal.startsAt {
            lines.append("Start: \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: start)))")
        }
        if let end = proposal.endsAt {
            lines.append("End: \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: end)))")
        }
        lines.append("Request digest: \(proposal.digest)")
        lines.append("This approval expires after five minutes and applies once.")
        return lines.joined(separator: "\n")
    }
}
