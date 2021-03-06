//
//  HttpHandlers+WebSockets.swift
//  Swifter
//
//  Copyright © 2014-2016 Damian Kołakowski. All rights reserved.
//

#if os(Linux)
    import Glibc
#else
    import Foundation
#endif

public func websocket(
        text: ((WebSocketSession, String) -> Void)?,
    _ binary: ((WebSocketSession, [UInt8]) -> Void)?) -> (HttpRequest -> HttpResponse) {
    return { r in
        guard r.hasTokenForHeader("upgrade", token: "websocket") else {
            return .BadRequest(.Text("Invalid value of 'Upgrade' header: \(r.headers["upgrade"])"))
        }
        guard r.hasTokenForHeader("connection", token: "upgrade") else {
            return .BadRequest(.Text("Invalid value of 'Connection' header: \(r.headers["connection"])"))
        }
        guard let secWebSocketKey = r.headers["sec-websocket-key"] else {
            return .BadRequest(.Text("Invalid value of 'Sec-Websocket-Key' header: \(r.headers["sec-websocket-key"])"))
        }
        let protocolSessionClosure: (Socket -> Void) = { socket in
            let session = WebSocketSession(socket)
            var fragmentedOpCode = WebSocketSession.OpCode.Close
            var payload = [UInt8]() // Used for fragmented frames.
            do {
                while true {
                    let frame = try session.readFrame()
                    switch frame.opcode {
                    case .Continue:
                        // There is no message to continue, failed immediatelly.
                        if fragmentedOpCode == .Close {
                            socket.shutdwn()
                        }
                        frame.opcode = fragmentedOpCode
                        if frame.fin {
                            payload.appendContentsOf(frame.payload)
                            frame.payload = payload
                            // Clean the buffer.
                            payload = []
                            // Reset the OpCode.
                            fragmentedOpCode = WebSocketSession.OpCode.Close
                        }
                        fallthrough
                    case .Text:
                        if let handleText = text {
                            if frame.fin {
                                if payload.count > 0 {
                                    throw WebSocketSession.Error.ProtocolError("Continuing fragmented frame cannot have an operation code.")
                                }
                                var textFramePayload = frame.payload.map { Int8(bitPattern: $0) }
                                textFramePayload.append(0)
                                if let text = String(UTF8String: textFramePayload) {
                                    handleText(session, text)
                                }
                            } else {
                                payload.appendContentsOf(frame.payload)
                                fragmentedOpCode = .Text
                            }
                        }
                    case .Binary:
                        if let handleBinary = binary {
                            if frame.fin {
                                if payload.count > 0 {
                                    throw WebSocketSession.Error.ProtocolError("Continuing fragmented frame cannot have an operation code.")
                                }
                                handleBinary(session, frame.payload)
                            } else {
                                payload.appendContentsOf(frame.payload)
                                fragmentedOpCode = .Binary
                            }
                        }
                    case .Close:
                        throw WebSocketSession.Control.Close
                    case .Ping:
                        if frame.payload.count > 125 {
                            throw WebSocketSession.Error.ProtocolError("payload gretter than 125 octets.")
                        } else {
                            session.writeFrame(ArraySlice(frame.payload), .Pong)
                        }
                    case .Pong:
                        break
                    }
                }
            } catch let error {
                switch error {
                case WebSocketSession.Control.Close:
                    // Normal close
                    break
                case WebSocketSession.Error.UnknownOpCode:
                    print("Unknown Op Code: \(error)")
                default:
                    print("Unkown error \(error)")
                }
                // If an error occurs, send the close handshake.
                session.writeCloseFrame()
            }
        }
        let secWebSocketAccept = String.toBase64((secWebSocketKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").SHA1())
        let headers = [ "Upgrade": "WebSocket", "Connection": "Upgrade", "Sec-WebSocket-Accept": secWebSocketAccept]
        return HttpResponse.SwitchProtocols(headers, protocolSessionClosure)
    }
}

public class WebSocketSession: Hashable, Equatable  {
    
    public enum Error: ErrorType { case UnknownOpCode(String), UnMaskedFrame, ProtocolError(String) }
    public enum OpCode: UInt8 { case Continue = 0x00, Close = 0x08, Ping = 0x09, Pong = 0x0A, Text = 0x01, Binary = 0x02 }
    public enum Control: ErrorType { case Close }
    
    public class Frame {
        public var opcode = OpCode.Close
        public var fin = false
        public var rsv1: UInt8 = 0
        public var rsv2: UInt8 = 0
        public var rsv3: UInt8 = 0
        public var payload = [UInt8]()
    }

    private let socket: Socket
    
    public init(_ socket: Socket) {
        self.socket = socket
    }
    
    deinit {
        writeCloseFrame()
        socket.shutdwn()
    }
    
    public func writeText(text: String) -> Void {
        self.writeFrame(ArraySlice(text.utf8), OpCode.Text)
    }

    public func writeBinary(binary: [UInt8]) -> Void {
        self.writeBinary(ArraySlice(binary))
    }
    
    public func writeBinary(binary: ArraySlice<UInt8>) -> Void {
        self.writeFrame(binary, OpCode.Binary)
    }
    
    private func writeFrame(data: ArraySlice<UInt8>, _ op: OpCode, _ fin: Bool = true) {
        let finAndOpCode = UInt8(fin ? 0x80 : 0x00) | op.rawValue
        let maskAndLngth = encodeLengthAndMaskFlag(UInt64(data.count), false)
        do {
            try self.socket.writeUInt8([finAndOpCode])
            try self.socket.writeUInt8(maskAndLngth)
            try self.socket.writeUInt8(data)
        } catch {
            print(error)
        }
    }
    
    private func writeCloseFrame() {
        writeFrame(ArraySlice("".utf8), .Close)
    }
    
    private func encodeLengthAndMaskFlag(len: UInt64, _ masked: Bool) -> [UInt8] {
        let encodedLngth = UInt8(masked ? 0x80 : 0x00)
        var encodedBytes = [UInt8]()
        switch len {
        case 0...125:
            encodedBytes.append(encodedLngth | UInt8(len));
        case 126...UInt64(UINT16_MAX):
            encodedBytes.append(encodedLngth | 0x7E);
            encodedBytes.append(UInt8(len >> 8 & 0xFF));
            encodedBytes.append(UInt8(len >> 0 & 0xFF));
        default:
            encodedBytes.append(encodedLngth | 0x7F);
            encodedBytes.append(UInt8(len >> 56 & 0xFF));
            encodedBytes.append(UInt8(len >> 48 & 0xFF));
            encodedBytes.append(UInt8(len >> 40 & 0xFF));
            encodedBytes.append(UInt8(len >> 32 & 0xFF));
            encodedBytes.append(UInt8(len >> 24 & 0xFF));
            encodedBytes.append(UInt8(len >> 16 & 0xFF));
            encodedBytes.append(UInt8(len >> 08 & 0xFF));
            encodedBytes.append(UInt8(len >> 00 & 0xFF));
        }
        return encodedBytes
    }
    
    public func readFrame() throws -> Frame {
        let frm = Frame()
        let fst = try socket.read()
        frm.fin = fst & 0x80 != 0
        frm.rsv1 = fst & 0x40
        frm.rsv2 = fst & 0x20
        frm.rsv3 = fst & 0x10
        guard frm.rsv1 == 0 && frm.rsv2 == 0 && frm.rsv3 == 0
            else {
            throw Error.ProtocolError("Reserved frame bit has not been negocitated.")
        }
        let opc = fst & 0x0F
        guard let opcode = OpCode(rawValue: opc) else {
            // "If an unknown opcode is received, the receiving endpoint MUST _Fail the WebSocket Connection_."
            // http://tools.ietf.org/html/rfc6455#section-5.2 ( Page 29 )
            throw Error.UnknownOpCode("\(opc)")
        }
        if frm.fin == false {
            switch opcode {
            case .Ping, .Pong, .Close:
                // Control frames must not be fragmented
                // https://tools.ietf.org/html/rfc6455#section-5.5 ( Page 35 )
                throw Error.ProtocolError("control frames must not be framgemted.")
            default:
                break
            }
        }
        frm.opcode = opcode
        let sec = try socket.read()
        let msk = sec & 0x80 != 0
        guard msk else {
            // "...a client MUST mask all frames that it sends to the server."
            // http://tools.ietf.org/html/rfc6455#section-5.1
            throw Error.UnMaskedFrame
        }
        var len = UInt64(sec & 0x7F)
        if len == 0x7E {
            let b0 = UInt64(try socket.read())
            let b1 = UInt64(try socket.read())
            len = UInt64(littleEndian: b0 << 8 | b1)
        } else if len == 0x7F {
            let b0 = UInt64(try socket.read())
            let b1 = UInt64(try socket.read())
            let b2 = UInt64(try socket.read())
            let b3 = UInt64(try socket.read())
            let b4 = UInt64(try socket.read())
            let b5 = UInt64(try socket.read())
            let b6 = UInt64(try socket.read())
            let b7 = UInt64(try socket.read())
            len = UInt64(littleEndian: b0 << 54 | b1 << 48 | b2 << 40 | b3 << 32 | b4 << 24 | b5 << 16 | b6 << 8 | b7)
        }
        let mask = [try socket.read(), try socket.read(), try socket.read(), try socket.read()]
        for i in 0..<len {
            frm.payload.append(try socket.read() ^ mask[Int(i % 4)])
        }
        return frm
    }
    
    public var hashValue: Int {
        get {
            return socket.hashValue
        }
    }
}

public func ==(webSocketSession1: WebSocketSession, webSocketSession2: WebSocketSession) -> Bool {
    return webSocketSession1.socket == webSocketSession2.socket
}
