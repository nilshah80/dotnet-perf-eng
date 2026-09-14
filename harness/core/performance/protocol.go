package performance

import "fmt"

type ProtocolKind string

const (
	ProtocolGRPC      ProtocolKind = "grpc"
	ProtocolWebSocket ProtocolKind = "websocket"
	ProtocolMessaging ProtocolKind = "messaging"
	ProtocolBrowser   ProtocolKind = "browser-synthetic"
)

func ProtocolRunsBesideBackend(kind ProtocolKind) bool {
	return kind == ProtocolBrowser
}

func ValidateProtocol(kind ProtocolKind, implemented bool) error {
	switch kind {
	case ProtocolGRPC, ProtocolWebSocket, ProtocolMessaging, ProtocolBrowser:
	default:
		return fmt.Errorf("unknown protocol %s", kind)
	}
	if !implemented {
		return fmt.Errorf("protocol %s is not implemented in this revision", kind)
	}
	return nil
}
