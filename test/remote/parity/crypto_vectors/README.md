# Remote Parity Crypto Vectors

This directory stores deterministic crypto conformance vectors used for
encrypted remote-control protocol validation.

Vector schema:

- `id`: stable vector identifier.
- `algorithm`: algorithm family.
- `key_hex`: symmetric key in hex.
- `nonce_hex`: nonce/iv in hex.
- `aad_hex`: additional authenticated data in hex.
- `plaintext_hex`: plaintext in hex.
- `ciphertext_hex`: expected ciphertext in hex.
- `tag_hex`: expected authentication tag in hex.

Note: Current vectors are scaffolding placeholders and should be replaced by
true kitty protocol-compatible vectors as part of Phase 2.
