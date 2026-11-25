#if os(macOS)
import Foundation
import Network
import RailwayCore

// The app opens the loopback port only for a user-initiated handoff. The one
// resource is the public timetable snapshot; requests cannot name files.
@MainActor
final class BrowserTimetableShare {
    static let shared = BrowserTimetableShare()
    private var listener: NWListener?
    private var lifetime: Task<Void,Never>?
    private var activeID: UUID?
    private var connections = [ObjectIdentifier:NWConnection]()
    private let origin = "https://wongary.github.io"

    func start(id: UUID, library: TimetableLibraryStore) async throws {
        stop()
        activeID=id
        if library.lulu == nil {await library.synchronizeLulu()}
        guard activeID==id else{return}
        guard let timetable=library.lulu else {throw DataError.invalid(library.message ?? "本机没有路路通时刻库")}
        let payload=try await Task.detached {try JSONEncoder().encode(timetable)}.value
        guard activeID==id else{return}
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:18765)
        let server=try NWListener(using:parameters)
        listener=server
        server.newConnectionHandler={ [weak self] connection in
            Task { @MainActor in
                guard let self,self.activeID==id,self.connections.count<8 else {connection.cancel();return}
                self.connections[ObjectIdentifier(connection)]=connection
                connection.start(queue:.main)
                self.receive(connection,id:id,previous:Data(),payload:payload)
            }
        }
        server.start(queue:.main)
        lifetime=Task {
            try? await Task.sleep(for:.seconds(90))
            if !Task.isCancelled,activeID==id {stop()}
        }
    }
    private func stop() {
        lifetime?.cancel();lifetime=nil
        listener?.cancel();listener=nil;activeID=nil
        connections.values.forEach { $0.cancel() };connections.removeAll()
    }
    private func finish(_ connection:NWConnection) {
        connection.cancel();connections.removeValue(forKey:ObjectIdentifier(connection))
    }
    private func receive(_ connection:NWConnection,id:UUID,previous:Data,payload:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] part,_,closed,error in
            Task { @MainActor in
                guard let self,self.activeID==id,error==nil,let part else {self?.finish(connection);return}
                let head=previous+part
                guard head.count<=8192,let text=String(data:head,encoding:.utf8) else {self.finish(connection);return}
                guard let end=text.range(of:"\r\n\r\n") else {
                    if closed {self.finish(connection)} else {self.receive(connection,id:id,previous:head,payload:payload)}
                    return
                }
                let rows=text[..<end.lowerBound].components(separatedBy:"\r\n")
                let target="/timetable/"+id.uuidString.lowercased()
                let preflight=rows.first=="OPTIONS \(target) HTTP/1.1"
                let fields=rows.dropFirst().map { $0.lowercased().replacingOccurrences(of:": ",with:":") }
                guard preflight || rows.first=="GET \(target) HTTP/1.1",fields.contains("origin:"+self.origin),
                      fields.contains("host:127.0.0.1:18765") else { self.finish(connection);return }
                let body=preflight ? Data() : payload
                let headers=["HTTP/1.1 200 OK","Access-Control-Allow-Origin: "+self.origin,
                    "Access-Control-Allow-Methods: GET, OPTIONS","Access-Control-Allow-Private-Network: true",
                    "Content-Type: application/json","Cache-Control: no-store","Connection: close","Content-Length: \(body.count)","",""]
                connection.send(content:Data(headers.joined(separator:"\r\n").utf8)+body,completion:.contentProcessed { [weak self] error in
                    Task { @MainActor in
                        self?.finish(connection)
                        if !preflight,error==nil,self?.activeID==id {self?.stop()}
                    }
                })
            }
        }
    }
}
#endif
