import BridgeCore
import BridgeProtocol
import Foundation

final class SessionEndpoint: NSObject, WMWorkspaceBridge {
    private let session = BridgeSession()

    func negotiateVersion(_ version: Int, reply: @escaping (Int, String?) -> Void) {
        reply(BridgeSession.version, session.negotiate(version: version))
    }

    func pingEpoch(_ epoch: String, sequence: UInt64, reply: @escaping (Bool, UInt64) -> Void) {
        reply(session.accept(epoch: epoch, sequence: sequence), sequence)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WMWorkspaceBridge.self)
        connection.exportedObject = SessionEndpoint()
        connection.resume()
        return true
    }
}

do {
    let team = try SigningIdentity.ownTeamID()
    guard let requirement = SigningIdentity.requirement(identifier: SigningIdentity.browserID, teamID: team) else {
        throw NSError(domain: "WinMuxBrowser.Signing", code: 2)
    }
    let delegate = ListenerDelegate()
    let listener = NSXPCListener(machServiceName: SigningIdentity.serviceName)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate
    listener.resume()
    // This M0 control-plane process intentionally does not start AX management:
    // the existing WinMux may still own native windows during qualification.
    withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
} catch {
    FileHandle.standardError.write(Data("Helper refused to start: \(error.localizedDescription)\n".utf8))
    exit(1)
}
