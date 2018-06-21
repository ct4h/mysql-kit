import Crypto
import NIOOpenSSL

final class MySQLConnectionHandler: ChannelInboundHandler {
    enum ConnectionState {
        case nascent
        case waiting
        case callback(Promise<Void>, (MySQLPacket) throws -> Bool)
    }
    
    /// See `ChannelInboundHandler`.
    typealias InboundIn = MySQLPacket
    
    /// See `ChannelInboundHandler`.
    typealias OutboundOut = MySQLPacket
    
    let config: MySQLDatabaseConfig
    var state: ConnectionState
    var readyForQuery: Promise<Void>?
    
    init(config: MySQLDatabaseConfig) {
        self.config = config
        self.state = .nascent
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        do {
            try handlePacket(ctx: ctx, packet: unwrapInboundIn(data))
        } catch {
            errorCaught(ctx: ctx, error: error)
        }
    }
    
    // MARK: Private
    
    private func handlePacket(ctx: ChannelHandlerContext, packet: MySQLPacket) throws {
        // print("✅ \(packet) \(state)")
        switch state {
        case .nascent:
            switch packet {
            case .handshakev10(let handshake):
                switch config.transport.storage {
                case .cleartext: try writeHandshakeResponse(ctx: ctx, handshake: handshake)
                case .tls(let tlsConfig): try writeSSLRequest(ctx: ctx, using: tlsConfig, handshake: handshake)
                }
            case .ok:
                state = .waiting
                readyForQuery?.succeed()
                self.readyForQuery = nil
            case .fullAuthenticationRequest:
                guard config.transport.isTLS else {
                    throw MySQLError(
                        identifier: "fullAuthRequired",
                        reason: "Full authentication not supported over insecure connections.",
                        possibleCauses: [
                            "Using 'caching_sha2_password' auth plugin (default in MySQL >= 8.0.4) over an insecure (no SSL) connection."
                        ],
                        suggestedFixes: [
                            "Use a secure MySQLTransportConfig option in your MySQLDatabaseConfig.",
                            "Use a MySQL auth plugin that does not require full authentication (like 'mysql_native_password').",
                            "Use MySQL < 8.0.4."
                        ],
                        documentationLinks: [
                            "https://mysqlserverteam.com/mysql-8-0-4-new-default-authentication-plugin-caching_sha2_password/"
                        ]
                    )
                }
                let packet: MySQLPacket = .plaintextPassword(config.password!)
                // if auth write fail, we need to fail the rfq promise
                let writePromise = ctx.eventLoop.newPromise(Void.self)
                writePromise.futureResult.whenFailure { error in
                    self.readyForQuery?.fail(error: error)
                    self.readyForQuery = nil
                }
                ctx.writeAndFlush(wrapOutboundOut(packet), promise: writePromise)
            case .err(let err):
                let error = err.makeError()
                readyForQuery?.fail(error: error)
                self.readyForQuery = nil
            default: fatalError("Unsupported packet during connect: \(packet)")
            }
        case .waiting:
            switch packet {
            case .ok: break
            default: fatalError("Unexpected packet: \(packet)")
            }
        case .callback(let promise, let callback):
            do {
                if try callback(packet) {
                    state = .waiting
                    promise.succeed()
                } else {
                    // continue parsing
                }
            } catch {
                state = .waiting
                promise.fail(error: error)
            }
        }
    }
    
    private func writeHandshakeResponse(ctx: ChannelHandlerContext, handshake: MySQLPacket.HandshakeV10) throws {
        let authPlugin = handshake.authPluginName ?? "mysql_native_password"
        let authResponse: Data
        switch authPlugin {
        case "mysql_native_password":
            guard handshake.capabilities.contains(.CLIENT_SECURE_CONNECTION) else {
                throw MySQLError(identifier: "authproto", reason: "Pre-4.1 auth protocol is not supported or safe.")
            }
            guard let password = config.password else {
                throw MySQLError(identifier: "password", reason: "Password required for auth plugin.")
            }
            guard handshake.authPluginData.count >= 20 else {
                throw MySQLError(identifier: "salt", reason: "Server-supplied salt too short.")
            }
            let salt = Data(handshake.authPluginData[..<20])
            let passwordHash = try SHA1.hash(password)
            let passwordDoubleHash = try SHA1.hash(passwordHash)
            var hash = try SHA1.hash(salt + passwordDoubleHash)
            for i in 0..<20 {
                hash[i] = hash[i] ^ passwordHash[i]
            }
            authResponse = hash
        case "caching_sha2_password":
            guard let password = config.password else {
                throw MySQLError(identifier: "password", reason: "Password required for auth plugin.")
            }
            
            // XOR(SHA256(PASSWORD), SHA256(SHA256(SHA256(PASSWORD)), seed_bytes))
            //
            // XOR(
            //     SHA256(PASSWORD),
            //     SHA256(
            //         SHA256(
            //             SHA256(PASSWORD)
            //         ),
            //         seed_bytes
            //     )
            // )
            var hash = try SHA256.hash(password)
            let hash2x = try SHA256.hash(hash)
            let hash2xsalt = try SHA256.hash(hash2x + handshake.authPluginData)
            hash.xor(hash2xsalt)
            authResponse = hash
        default: throw MySQLError(identifier: "authPlugin", reason: "Unsupported auth plugin: '\(authPlugin)'.")
        }
        let response = MySQLPacket.HandshakeResponse41(
            capabilities: config.capabilities,
            maxPacketSize: 1_024,
            characterSet: config.characterSet,
            username: config.username,
            authResponse: authResponse,
            database: config.database,
            authPluginName: authPlugin
        )
        // if auth write fail, we need to fail the rfq promise
        let writePromise = ctx.eventLoop.newPromise(Void.self)
        writePromise.futureResult.whenFailure { error in
            self.readyForQuery?.fail(error: error)
            self.readyForQuery = nil
        }
        ctx.writeAndFlush(wrapOutboundOut(.handshakeResponse41(response)), promise: writePromise)
    }
    
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        switch state {
        case .nascent:
            readyForQuery?.fail(error: error)
            readyForQuery = nil
        case .callback(let promise, _):
            self.state = .waiting
            promise.fail(error: error)
        case .waiting:
            ERROR("Error while waiting: \(error).")
        }
    }
    
    /// Ask the server if it supports SSL and adds a new OpenSSLClientHandler to pipeline if it does
    /// This will throw an error if the server does not support SSL
    private func writeSSLRequest(ctx: ChannelHandlerContext, using tlsConfig: TLSConfiguration, handshake: MySQLPacket.HandshakeV10) throws {
        var capabilities = config.capabilities
        capabilities.insert(.CLIENT_SSL)
        let promise = ctx.eventLoop.newPromise(Void.self)
        ctx.writeAndFlush(wrapOutboundOut(.sslRequest(.init(
            capabilities: capabilities,
            maxPacketSize: 1_024,
            characterSet: config.characterSet
        ))), promise: promise)
        
        let sslContext = try SSLContext(configuration: tlsConfig)
        let handler = try OpenSSLClientHandler(context: sslContext)
        let sslReady = promise.futureResult.map {
            return ctx.channel.pipeline.add(handler: handler, first: true)
        }
        
        sslReady.whenSuccess { _ in
            do {
                try self.writeHandshakeResponse(ctx: ctx, handshake: handshake)
            } catch {
                self.readyForQuery?.fail(error: error)
                self.readyForQuery = nil
            }
        }
        sslReady.whenFailure { error in
            self.readyForQuery?.fail(error: error)
            self.readyForQuery = nil
        }
    }
}


extension Data {
    public mutating func xor(_ key: Data) {
        for i in 0..<self.count {
            self[i] ^= key[i]
        }
    }
}
