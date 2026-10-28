"""CMM Computer Use reuse layer: transport client and MCP adapter.

The native engine is ``CMMComputerUse.app`` in ``apps/apple/CMMComputerUse``;
this package only talks to it. See ``README.md``.
"""

from .client import (  # noqa: F401
    ACTION_KINDS,
    BRIDGE_BUNDLE_ID,
    BRIDGE_NAME,
    ERROR_CODES,
    POLICIES,
    PROTOCOL_VERSION,
    BridgeClient,
    BridgeError,
    BridgeProtocolError,
    BridgeUnavailable,
    default_socket_path,
)

__all__ = [
    "ACTION_KINDS",
    "BRIDGE_BUNDLE_ID",
    "BRIDGE_NAME",
    "ERROR_CODES",
    "POLICIES",
    "PROTOCOL_VERSION",
    "BridgeClient",
    "BridgeError",
    "BridgeProtocolError",
    "BridgeUnavailable",
    "default_socket_path",
]
