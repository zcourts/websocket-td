class WsError < StandardError
end
class ConnectError < WsError
end
class WsProtocolError < WsError
end
class BadMessageTypeError < WsError
end
