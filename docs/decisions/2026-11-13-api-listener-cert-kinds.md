# The API listener takes a set of certificate kinds

Date: 2026-11-13. Decided by the supervisor; built in B7 slice 3.

## Decision

`tls_server.Config.client_kinds` is a required `x509.Kinds` (an `EnumSet` of `x509.Kind`), not one
kind with an optional second. The API listener (`server_tls.zig`) takes `{node, client}`; a
workload sidecar would take `{workload}`. There is no default: a listener that does not say what
it takes fails to compile.

The leaf is parsed once and verified against its own kind when the set holds it, else against
the set's first kind, which fails. The handshake is not retried kind by kind. A refusal is
ZC-E0819, and its cause names every kind taken: "the client's certificate is a server
certificate; this use needs a node certificate or a client certificate".

## Why

Slice 3 first added `client_kind_also`, a second optional kind. That does not grow past two kinds,
and its refusal named only the first kind. A set is the same check with an honest message.

## Merging with slice 1's fix

Slice 1's fix (573ca43) makes `Config.client_kind` required. When it merges, `client_kinds`
replaces `client_kind`: every server config sets `client_kinds` explicitly, and none sets the
old field.
