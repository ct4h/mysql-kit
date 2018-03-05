import Bits
import Foundation

/// Protocol::HandshakeResponse
///
/// Depending on the servers support for the CLIENT_PROTOCOL_41 capability and the clients
/// understanding of that flag the client has to send either a Protocol::HandshakeResponse41
/// or Protocol::HandshakeResponse320.
///
/// Handshake Response Packet sent by 4.1+ clients supporting CLIENT_PROTOCOL_41 capability,
/// if the server announced it in its Initial Handshake Packet. Otherwise (talking to an old server)
/// the Protocol::HandshakeResponse320 packet must be used.
///
/// https://dev.mysql.com/doc/internals/en/connection-phase-packets.html#packet-Protocol::HandshakeResponse
struct MySQLHandshakeResponse41 {
    /// capability_flags (4)
    /// capability flags of the client as defined in Protocol::CapabilityFlags
    var capabilities: MySQLCapabilities

    /// max_packet_size (4)
    /// max size of a command packet that the client wants to send to the server
    var maxPacketSize: UInt32

    /// character_set (1)
    /// connection's default character set as defined in Protocol::CharacterSet.
    var characterSet: Byte

    /// username (string.fix_len)
    /// name of the SQL account which client wants to log in this string should be interpreted using the character set indicated by character set field.
    var username: String

    /// auth-response (string.NUL)
    /// opaque authentication response data generated by Authentication Method indicated by the plugin name field.
    var authResponse: Data

    /// database (string.NUL)
    /// initial database for the connection -- this string should be interpreted using the character set indicated by character set field.
    var database: String

    /// auth plugin name (string.NUL)
    /// the Authentication Method used by the client to generate auth-response value in this packet. This is an UTF-8 string.
    var authPluginName: String

    /// Creates a new `MySQLHandshakeResponse41`
    init(capabilities: MySQLCapabilities, maxPacketSize: UInt32, characterSet: Byte, username: String, authResponse: Data, database: String, authPluginName: String) {
        self.capabilities = capabilities
        self.maxPacketSize = maxPacketSize
        self.characterSet = characterSet
        self.username = username
        self.authResponse = authResponse
        self.database = database
        self.authPluginName = authPluginName
    }

    /// Serializes the `MySQLHandshakeResponse41` into a buffer.
    func serialize(into buffer: inout ByteBuffer) {
        buffer.write(integer: capabilities.raw, endianness: .little)
        buffer.write(integer: maxPacketSize, endianness: .little)
        buffer.write(integer: characterSet, endianness: .little)
        /// string[23]     reserved (all [0])
        buffer.write(bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        buffer.write(nullTerminated: username)
        assert(capabilities.get(CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA) == false, "CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA not supported")
        if capabilities.get(CLIENT_SECURE_CONNECTION) {
            assert(authResponse.count < Byte.max, "auth response too large")
            buffer.write(integer: Byte(authResponse.count), endianness: .little)
            buffer.write(bytes: authResponse)
        } else {
            // null terminated
            buffer.write(bytes: authResponse)
            buffer.write(integer: Byte(0))
        }
        if capabilities.get(CLIENT_CONNECT_WITH_DB) {
            buffer.write(nullTerminated: database)
        } else {
            assert(database == "", "CLIENT_CONNECT_WITH_DB not enabled")
        }
        if capabilities.get(CLIENT_PLUGIN_AUTH) {
            buffer.write(nullTerminated: authPluginName)
        } else {
            assert(authPluginName == "", "CLIENT_PLUGIN_AUTH not enabled")
        }
        assert(capabilities.get(CLIENT_CONNECT_ATTRS) == false, "CLIENT_CONNECT_ATTRS not supported")
    }
}
