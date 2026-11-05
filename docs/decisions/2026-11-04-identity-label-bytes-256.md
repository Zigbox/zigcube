# A certificate's identity labels total at most 256 bytes

*Decided 2026-11-04, by the slice (mTLS client slice 1, review NIT).*

The brief's per-label limits are 16 labels, 63-byte keys and 256-byte values. Together they would allow about 5 KiB of labels, which does not fit in `x509_cert_bytes_max` (1024). The slice adds a third limit, `x509_labels_bytes_max` = 256, on the keys and values added up:

- The largest certificate the writer can make stays under 1 KiB. Comptime asserts check this against the longest names.
- A single label can still use most of the budget. The comptime assert is `key + value > total / 2`.
- An issue that goes over the limit is refused with LabelsTooLarge (ZC-E0817). A parsed certificate that goes over it is refused with BadIdentity (ZC-E0809).

Until B1 fixes the label charset, this limit is provisional. Raising it means raising `x509_cert_bytes_max` too.

Where: `src/constants.zig` (`x509_labels_bytes_max`), `src/x509_identity.zig` (`check_labels`).
