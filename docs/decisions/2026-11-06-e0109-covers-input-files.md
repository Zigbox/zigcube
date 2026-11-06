# ZC-E0109 covers any file a command names

Date: 2026-11-06. Decided by the supervisor on the review of #140 (B1 slice 7).

`zcube job run --input-file` raised `ZC-E0109` ("the service file can't be read") for an input
file that is not there. Registering a new code was the other option. Decision: no new code. E0109's
summary is now "a file named on the command line can't be read" and its explanation names both
cases (the service file of `apply`, the input file of `job run`). A file that is too large or not
UTF-8 is still `ZC-E0111`. The `while` line says which file ("reading the input file of job run").

The registry text changed in `src/diag/codes.zig`, the site page (`zig build errors-site`), the
mock's `web/mock/codes.js`, `docs/cli.md` and the E0109 goldens. DIAGNOSTICS.md does not quote
the old text. Zigbox's copy is unaffected (E0109 is a Zigcube code).
