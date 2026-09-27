"""Small AUTH parsing helpers shared by the server and regression tests."""

from dataclasses import dataclass


@dataclass(frozen=True)
class ClientDHHello:
    nonce: int
    client_public: int
    wire_public: bytes
    canonical_public: bytes


def parse_client_dh_plaintext(
    plaintext: bytes,
    *,
    prime: int,
    width: int = 64,
) -> ClientDHHello:
    """Parse TCLS RSA plaintext containing a 4-byte nonce + DH public integer.

    TCLS serializes the DH bignum at minimal length, so a normal 64-byte value
    whose most-significant byte is zero arrives as 63 bytes on the wire.
    """
    data = bytes(plaintext)
    if width <= 0:
        raise ValueError("DH width must be positive")
    if not (5 <= len(data) <= 4 + width):
        raise ValueError(
            f"unexpected RSA plaintext length: {len(data)} "
            f"(expected 5..{4 + width})"
        )

    nonce = int.from_bytes(data[:4], "big")
    wire_public = data[4:]
    client_public = int.from_bytes(wire_public, "big")

    if not (1 < client_public < int(prime)):
        raise ValueError("invalid client DH public key")

    canonical_public = client_public.to_bytes(width, "big")
    return ClientDHHello(
        nonce=nonce,
        client_public=client_public,
        wire_public=wire_public,
        canonical_public=canonical_public,
    )
