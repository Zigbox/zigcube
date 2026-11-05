# A certificate is valid from not_before − skew, inclusive, to not_after + skew, exclusive

*Decided 2026-11-04, by the slice (mTLS client slice 1, review NIT).*

Verification takes the wall time `now` as an argument and allows `peer_clock_skew_ms` (60 s) in each direction:

- `not_before > now + skew` is refused as NotYetValid (ZC-E0811).
- `now >= not_after + skew` is refused as Expired (ZC-E0811).

At the edges, `now == not_before - skew` is accepted, and `now == not_after + skew` is refused.

RFC 5280 calls both ends inclusive. Excluding the end means a certificate never overlaps its successor's first millisecond. It also means a lifetime bound of exactly `ttl` gives `ttl + 2 * skew` of acceptance, never one millisecond more.

Times are read only in their canonical form:

- UTCTime for the years 1970 to 2049, and GeneralizedTime for 2050 on (RFC 5280 4.1.2.5).
- Seconds always present, `Z` always present, no fractions.
- No second 60, and no day the calendar lacks.

The writer switches forms at 2050.

Where: `src/x509.zig` (`check_window`, `read_time`, `write_time`), the time rows in `src/x509_test.zig` and `src/x509_near_miss.zig`.
