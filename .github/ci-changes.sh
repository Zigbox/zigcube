#!/usr/bin/env bash
# Decides which jobs ci.yml runs. Reads the changed paths, one per line, on stdin and writes
# `name=true|false` lines (to $GITHUB_OUTPUT, or stdout when that is unset):
#
#   code          format, build, test, tidy, errors-site, the memory and SQLite store suites, the
#                 smokes, the wasm checks and the simulations
#   store         the Postgres store suite and the store fault tests
#   demo_c0       demo-c0 on SQLite and on Postgres
#   demo_c1       demo-c1 on SQLite and on Postgres
#   demo_b1       demo-b1 on SQLite and on Postgres
#   zigbox_smoke  the Zigbox runtime on a real host (QEMU/KVM)
#   demo_c2       demo-c2 (four VMs, KVM, GHCR images)
#   mtls_interop  mtls-interop (stock openssl and JDK servers)
#   demo_b3       demo-b3 (one VM, KVM, a GHCR image)
#   demo_b4       demo-b4 (demo-b3's rig and driver, B4's script)
#
# Environment: EVENT (github.event_name), HEAD_REF (the PR's head branch), LABELS (the PR's labels,
# space separated). See docs/decisions/2026-11-04-ci-affected-demos.md.
#
# The rules err toward running. A path no rule below names runs everything. A rule narrows only
# where the path cannot reach a binary a job runs: tests of the code, the simulations, the web
# console, the tools, one demo's own driver, one smoke's own driver. `code` is true for every
# change that is not documentation only, so format, tidy, build and the unit tests always run.
set -euo pipefail

jobs=(store demo_c0 demo_c1 demo_b1 zigbox_smoke demo_c2 mtls_interop demo_b3 demo_b4)
declare -A want=()

want_all() { local j; for j in "${jobs[@]}"; do want[$j]=1; done; }
# demo-b4 is demo-b3's driver and rig with another script: whatever runs demo-b3 runs it too.
want_one() { want[$1]=1; if [ "$1" = demo_b3 ]; then want[demo_b4]=1; fi; }

# Documentation only: a file ending in `.md` outside web/ and src/, or anything under site/ outside
# site/errors/ (the error pages are generated from the diagnostic registry and checked by the
# errors-site step). A `.zig`, `.zon` or `.sh` file is code wherever it is, because
# `zig fmt --check .` and tidy read every one in the tree.
is_docs() {
  case "$1" in
    web/* | src/* | site/errors/*) return 1 ;;
    *.zig | *.zon | *.sh) return 1 ;;
    site/*) return 0 ;;
    *.md) return 0 ;;
  esac
  return 1
}

classify() {
  case "$1" in
    # What every job is built from, or CI itself, and what a demo's start scripts run.
    build.zig | build.zig.zon | .github/* | fixtures/* | demo/*) want_all; return ;;
    # The shared driver of both demos.
    src/demo_host.zig) want_all; return ;;
    # The files of one demo: that demo only (docs/demos/*.md is documentation).
    # demo-b1 imports demo_c1_state.zig, which imports demo_c1_fleet.zig and demo_c0_state.zig.
    src/demo_c0_state.zig) want_one demo_c0; want_one demo_c1; want_one demo_b1; want_one demo_b3; return ;;
    src/demo_c1_state.zig | src/demo_c1_fleet.zig) want_one demo_c1; want_one demo_b1; want_one demo_b3; return ;;
    src/demo_c0*.zig) want_one demo_c0; return ;;
    src/demo_c1*.zig) want_one demo_c1; return ;;
    # demo-b3 imports demo_b1_state.zig (so demo_b1_fleet.zig, demo_c1_state.zig and what they import), and demo_c2_steps.zig and demo_c2_vms.zig (its rig).
    src/demo_b1_state.zig | src/demo_b1_fleet.zig) want_one demo_b1; want_one demo_b3; return ;;
    src/demo_b1*.zig) want_one demo_b1; return ;;
    src/demo_c2_steps.zig | src/demo_c2_vms.zig) want_one demo_c2; want_one demo_b3; return ;;
    src/demo_c2*.zig | ops/demo-c2/*) want_one demo_c2; return ;;
    src/demo_b3*.zig | src/demo_relay_tls.zig | ops/demo-b3/*) want_one demo_b3; return ;;
    src/demo_b4*.zig) want_one demo_b4; return ;;
    # The Zigbox runtime adapter: its smoke and demo-c2, which runs it on real VMs. The C0 and C1
    # demos run FakeRuntime; a compile error in the adapter still fails the build job.
    src/zigbox_* | src/relay*.zig) want_one zigbox_smoke; want_one demo_c2; want_one demo_b3; return ;;
    # The mTLS interop harness and its Java server.
    src/mtls_interop.zig | ops/mtls-interop/*) want_one mtls_interop; return ;;
    # The smoke's own files.
    ops/zigbox-smoke/*) want_one zigbox_smoke; return ;;
    # The store suites' own files (the backends themselves are the server and run everything).
    src/store_conformance.zig | src/store_harness.zig | src/store_mutant.zig | \
      src/store_faults.zig | src/store_failover.zig) want_one store; return ;;
    # Not part of any job but the build, test, tidy and wasm ones: the web console and its
    # checks, the tools, the simulations and their runners, tests of the code, the gate's own
    # runner, the generated error pages' tool, the smokes' own drivers, the cloud container's
    # hook, the fleet's host side, the site's generated pages.
    web/* | tools/* | .claude/* | ops/sim-fleet/* | ops/demo-c2-images/* | site/errors/* | \
      src/console_*.zig | src/web_embed.zig | src/sim_*.zig | src/tests.zig | src/tidy.zig | \
      src/errors_site.zig | src/testdata/* | src/testing/check.zig | src/wasm_core.zig | \
      src/*_test.zig | src/agent_smoke.zig | src/local_smoke.zig | src/swarm_smoke.zig | \
      src/bench_watch.zig | src/zcube_agent_teeth.zig | src/zcube_agent_relay_teeth_*.zig) return ;;
  esac
  want_all
}

docs_only=1
count=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  count=$((count + 1))
  # A documentation path never widens the set; it only keeps `docs_only` true.
  if ! is_docs "$path"; then
    docs_only=0
    classify "$path"
  fi
done

# Everything runs for: a pull request from a release branch, one labelled full-ci, a push to main,
# and a change whose paths could not be listed (nothing on stdin is not "documentation only").
# The one exception is the old rule: a push to main that changes only documentation skips the
# jobs, as it always did (such a push is mostly a status commit).
full=0
case "${HEAD_REF:-}" in claude/release-*) full=1 ;; esac
case " ${LABELS:-} " in *" full-ci "*) full=1 ;; esac
if [ "${EVENT:-pull_request}" != pull_request ]; then full=1; fi
if [ "$count" -eq 0 ]; then full=1; docs_only=0; fi
if [ "$docs_only" -eq 1 ] && [ "${EVENT:-pull_request}" != pull_request ]; then full=0; fi
# A documentation-only pull request is full only when asked for (release branch or full-ci).
if [ "$docs_only" -eq 1 ] && [ "$full" -eq 0 ]; then skip=1; else skip=0; fi

emit() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

if [ "$skip" -eq 1 ]; then
  emit code false
  for j in "${jobs[@]}"; do emit "$j" false; done
elif [ "$full" -eq 1 ]; then
  emit code true
  for j in "${jobs[@]}"; do emit "$j" true; done
else
  emit code true
  for j in "${jobs[@]}"; do emit "$j" "$([ -n "${want[$j]:-}" ] && echo true || echo false)"; done
fi
