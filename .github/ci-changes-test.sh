#!/usr/bin/env bash
# Tests of .github/ci-changes.sh: a table of changed paths and the verdict each must get. The
# changes job runs it before it classifies, so a broken rule fails CI instead of skipping a job.
# Each row: EVENT|HEAD_REF|LABELS|paths (space separated)|expected `code store c0 c1 b1 smoke c2 mtls b3` as T/F.
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
failed=0
n=0

check() {
  local event=$1 ref=$2 labels=$3 paths=$4 want=$5 got out
  # GITHUB_OUTPUT is set on a runner; unset, the script writes to stdout.
  out=$(printf '%s\n' ${paths} | env -u GITHUB_OUTPUT EVENT="$event" HEAD_REF="$ref" \
    LABELS="$labels" "$dir/ci-changes.sh" | tr '\n' ' ')
  got=$(echo "$out" | sed -E 's/code=true/T/; s/code=false/F/; s/store=true/T/; s/store=false/F/;
    s/demo_c0=true/T/; s/demo_c0=false/F/; s/demo_c1=true/T/; s/demo_c1=false/F/;
    s/demo_b1=true/T/; s/demo_b1=false/F/;
    s/zigbox_smoke=true/T/; s/zigbox_smoke=false/F/; s/demo_c2=true/T/; s/demo_c2=false/F/;
    s/mtls_interop=true/T/; s/mtls_interop=false/F/; s/demo_b3=true/T/; s/demo_b3=false/F/; s/ //g')
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: $event ${ref:+[$ref] }${labels:+[$labels] }${paths:-<no paths>}: want $want, got $got"
    failed=$((failed + 1))
  fi
}

# Verdict order: code store demo_c0 demo_c1 demo_b1 zigbox_smoke demo_c2 mtls_interop demo_b3.
PR=pull_request
# Documentation only: nothing runs.
check $PR x "" "README.md docs/core.md site/index.html" FFFFFFFFF
check $PR x "" "docs/demos/c1.md" FFFFFFFFF
# ...except src/ and web/ markdown, site/errors, and any code file.
check $PR x "" "src/README.md" TTTTTTTTT
check $PR x "" "web/README.md" TFFFFFFFF
check $PR x "" "site/errors/ZC-E0001.html" TFFFFFFFF
check $PR x "" "README.md ops/sim-fleet/run.sh" TFFFFFFFF
check $PR x "" "ops/sim-fleet/test-canary.sh ops/sim-fleet/test-crash-record.sh" TFFFFFFFF
# Docs only, but asked for in full.
check $PR x "full-ci" "README.md" TTTTTTTTT
check $PR claude/release-0.4 "" "README.md" TTTTTTTTT
# Narrow: tests, simulations, the web console, the tools, the gate's own runner.
check $PR x "" "src/scheduler_test.zig" TFFFFFFFF
check $PR x "" "src/sim_cluster.zig src/sim_swarm_main.zig" TFFFFFFFF
check $PR x "" "web/app.js web/mock/c1.js tools/wasm_check.mjs" TFFFFFFFF
check $PR x "" "src/tidy.zig src/testing/check.zig" TFFFFFFFF
check $PR x "" "src/console_wasm.zig src/web_embed.zig" TFFFFFFFF
# One demo, one smoke, the store suites' own files.
check $PR x "" "src/demo_c0_steps.zig" TFTFFFFFF
check $PR x "" "src/demo_c1_fleet.zig docs/demos/c1.md" TFFTTFFFT
check $PR x "" "src/demo_c1_state.zig" TFFTTFFFT
check $PR x "" "src/demo_c0_state.zig" TFTTTFFFT
check $PR x "" "src/demo_c1_partition.zig" TFFTFFFFF
check $PR x "" "src/zigbox_runtime.zig" TFFFFTTFT
check $PR x "" "ops/zigbox-smoke/guest.sh" TFFFFTFFF
check $PR x "" "src/store_faults.zig src/store_failover.zig" TTFFFFFFF
check $PR x "" "src/mtls_interop.zig" TFFFFFFTF
check $PR x "" "ops/mtls-interop/InteropServer.java" TFFFFFFTF
check $PR x "" "src/demo_c0.zig src/demo_c1.zig" TFTTFFFFF
# Everything: the build, CI itself, the shared demo driver, the server, the agent, the store
# backends, the core, and any path no rule names (also a new directory).
check $PR x "" "build.zig" TTTTTTTTT
check $PR x "" "build.zig.zon" TTTTTTTTT
check $PR x "" ".github/workflows/ci.yml" TTTTTTTTT
check $PR x "" ".github/ci-changes.sh" TTTTTTTTT
check $PR x "" "src/demo_host.zig" TTTTTTTTT
check $PR x "" "src/server.zig" TTTTTTTTT
check $PR x "" "src/agent_loop.zig" TTTTTTTTT
check $PR x "" "src/store_postgres.zig" TTTTTTTTT
check $PR x "" "src/store.zig" TTTTTTTTT
check $PR x "" "src/core.zig" TTTTTTTTT
check $PR x "" "src/c1_teeth.zig" TTTTTTTTT
# The sim job (which runs sim-fencing-teeth) runs on `code`: a change to the fencing arithmetic
# runs everything, one to the simulator alone runs the code jobs.
check $PR x "" "src/fencing.zig" TTTTTTTTT
check $PR x "" "src/sim_cluster.zig src/sim_c1_teeth_oldrule_main.zig" TFFFFFFFF
# B5 slice 3: the trust world and its tooth are simulator files.
check $PR x "" "src/sim_trust.zig src/sim_c1_teeth_job_untrusted_main.zig" TFFFFFFFF
check $PR x "" "src/testing/fault_proxy.zig" TTTTTTTTT
check $PR x "" "src/brand_new_file.zig" TTTTTTTTT
check $PR x "" "newdir/file.txt" TTTTTTTTT
check $PR x "" "fixtures/images.zon" TTTTTTTTT
check $PR x "" "demo/up.sh" TTTTTTTTT
# demo-c2: its own files, its docs (off), an unknown path (on), the label and a release branch (on).
check $PR x "" "src/demo_c2_steps.zig ops/demo-c2/run.sh" TFFFFFTFT
check $PR x "" "docs/demos/c2.md" FFFFFFFFF
check $PR x "" "src/never_heard_of_it.zig" TTTTTTTTT
check $PR x "full-ci" "src/demo_c2.zig" TTTTTTTTT
check $PR claude/release-0.5 "" "src/demo_c2.zig" TTTTTTTTT
check $PR x "" "src/scheduler_test.zig src/demo_c2.zig" TFFFFFTFF
# demo-b3: its own files, the files it shares (demo-b1's state, demo-c2's rig), the relay.
check $PR x "" "src/demo_b3_script.zig ops/demo-b3/guest.sh" TFFFFFFFT
check $PR x "" "src/demo_c2_vms.zig" TFFFFFTFT
check $PR x "" "src/demo_b1_state.zig" TFFFTFFFT
check $PR x "" "src/relay.zig" TFFFFTTFT
check $PR x "" "docs/demos/b3.md" FFFFFFFFF
# A narrow path next to an unknown one runs everything; two narrow paths run the union.
check $PR x "" "src/scheduler_test.zig src/server.zig" TTTTTTTTT
check $PR x "" "src/zigbox_map.zig src/demo_c1_steps.zig" TFFTFTTFT
# Full: the label, a release branch, a push to main, an unlisted change.
check $PR x "full-ci" "src/scheduler_test.zig" TTTTTTTTT
check $PR x "bug full-ci" "src/scheduler_test.zig" TTTTTTTTT
check $PR x "full-cipher" "src/scheduler_test.zig" TFFFFFFFF
check $PR claude/release-0.4 "" "src/scheduler_test.zig" TTTTTTTTT
check $PR claude/ci-speed "" "src/scheduler_test.zig" TFFFFFFFF
check push main "" "src/scheduler_test.zig" TTTTTTTTT
check push main "" "web/app.js" TTTTTTTTT
check push main "" "README.md" FFFFFFFFF
check $PR x "" "" TTTTTTTTT
check push main "" "" TTTTTTTTT
# demo-b1's own files run demo-b1 only; docs/demos/b1.md is documentation.
check $PR x "" "src/demo_b1_nodes.zig docs/demos/b1.md" TFFFTFFFF
check $PR x "" "src/demo_b1.zig src/demo_c1.zig" TFFTTFFFF

if [ "$failed" -ne 0 ]; then
  echo "ci-changes-test: $failed of $n failed"
  exit 1
fi
echo "ci-changes-test: $n cases passed"
