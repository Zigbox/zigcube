# O3 assumed: Botpike computes tree digests with `zbx pull` itself

*Assumed 2026-11-12, by the supervisor, under the owner's standing request to make sane
assumptions and record them. The owner has not answered O3. If the owner answers differently,
a new decision supersedes this one.*

O3 (`docs/briefs/botpike-first-customer.md`) asks how Botpike gets the tree digest it signs. It
offers two options:

- Botpike runs `zbx pull` on its own admission host.
- Zigcube adds a resolve call.

The brief recommends the first, and B5 (`docs/briefs/b5.md`) is written on that assumption:

- Botpike pulls, signs with `zbx sign <tree>`, and sends the output of `zbx trust export` as the
  job's `signatures`.
- Zigcube's API gains no resolve call.

Reason: the resolve call would make the server pull images, which is new work for it, and B5
does not need it. Should the owner pick the resolve call, it is one more B5 slice; nothing
already built changes.
