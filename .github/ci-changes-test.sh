#!/usr/bin/env bash
# Tests of .github/ci-changes.sh: a table of changed paths and the verdict each must get. The
# changes job runs it before it classifies, so a broken rule fails CI instead of skipping a job.
# Each row: EVENT|HEAD_REF|LABELS|paths (space separated)|expected `code store c0 c1 b1 smoke c2 mtls b3 b4` as T/F.
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
    s/mtls_interop=true/T/; s/mtls_interop=false/F/; s/demo_b3=true/T/; s/demo_b3=false/F/;
    s/demo_b4=true/T/; s/demo_b4=false/F/; s/ //g')
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: $event ${ref:+[$ref] }${labels:+[$labels] }${paths:-<no paths>}: want $want, got $got"
    failed=$((failed + 1))
  fi
}

# Verdict order: code store demo_c0 demo_c1 demo_b1 zigbox_smoke demo_c2 mtls_interop demo_b3 demo_b4.
PR=pull_request
# Documentation only: nothing runs.
check $PR x "" "README.md docs/core.md site/index.html" FFFFFFFFFF
check $PR x "" "docs/demos/c1.md" FFFFFFFFFF
# ...except src/ and web/ markdown, site/errors, and any code file.
check $PR x "" "src/README.md" TTTTTTTTTT
check $PR x "" "web/README.md" TFFFFFFFFF
check $PR x "" "site/errors/ZC-E0001.html" TFFFFFFFFF
check $PR x "" "README.md ops/sim-fleet/run.sh" TFFFFFFFFF
check $PR x "" "ops/sim-fleet/test-canary.sh ops/sim-fleet/test-crash-record.sh" TFFFFFFFFF
# Docs only, but asked for in full.
check $PR x "full-ci" "README.md" TTTTTTTTTT
check $PR claude/release-0.4 "" "README.md" TTTTTTTTTT
# Narrow: tests, simulations, the web console, the tools, the gate's own runner.
check $PR x "" "src/scheduler_test.zig" TFFFFFFFFF
check $PR x "" "src/sim_cluster.zig src/sim_swarm_main.zig" TFFFFFFFFF
check $PR x "" "web/app.js web/mock/c1.js tools/wasm_check.mjs" TFFFFFFFFF
check $PR x "" "src/tidy.zig src/testing/check.zig" TFFFFFFFFF
check $PR x "" "src/console_wasm.zig src/web_embed.zig" TFFFFFFFFF
# The relay teeth's agent roots run only in the check job (`zig build relay-teeth`).
check $PR x "" "src/zcube_agent_relay_teeth_outlive.zig src/zcube_agent_relay_teeth_unrelayed.zig" TFFFFFFFFF
# One demo, one smoke, the store suites' own files.
check $PR x "" "src/demo_c0_steps.zig" TFTFFFFFFF
check $PR x "" "src/demo_c1_fleet.zig docs/demos/c1.md" TFFTTFFFTT
check $PR x "" "src/demo_c1_state.zig" TFFTTFFFTT
check $PR x "" "src/demo_c0_state.zig" TFTTTFFFTT
check $PR x "" "src/demo_c1_partition.zig" TFFTFFFFFF
check $PR x "" "src/zigbox_runtime.zig" TFFFFTTFTT
check $PR x "" "ops/zigbox-smoke/guest.sh" TFFFFTFFFF
check $PR x "" "src/store_faults.zig src/store_failover.zig" TTFFFFFFFF
check $PR x "" "src/mtls_interop.zig" TFFFFFFTFF
check $PR x "" "ops/mtls-interop/InteropServer.java" TFFFFFFTFF
check $PR x "" "src/demo_c0.zig src/demo_c1.zig" TFTTFFFFFF
# Everything: the build, CI itself, the shared demo driver, the server, the agent, the store
# backends, the core, and any path no rule names (also a new directory).
check $PR x "" "build.zig" TTTTTTTTTT
check $PR x "" "build.zig.zon" TTTTTTTTTT
check $PR x "" ".github/workflows/ci.yml" TTTTTTTTTT
check $PR x "" ".github/ci-changes.sh" TTTTTTTTTT
check $PR x "" "src/demo_host.zig" TTTTTTTTTT
check $PR x "" "src/server.zig" TTTTTTTTTT
check $PR x "" "src/agent_loop.zig" TTTTTTTTTT
check $PR x "" "src/store_postgres.zig" TTTTTTTTTT
check $PR x "" "src/store.zig" TTTTTTTTTT
check $PR x "" "src/core.zig" TTTTTTTTTT
check $PR x "" "src/c1_teeth.zig" TTTTTTTTTT
# The sim job (which runs sim-fencing-teeth) runs on `code`: a change to the fencing arithmetic
# runs everything, one to the simulator alone runs the code jobs.
check $PR x "" "src/fencing.zig" TTTTTTTTTT
check $PR x "" "src/sim_cluster.zig src/sim_c1_teeth_oldrule_main.zig" TFFFFFFFFF
check $PR x "" "src/testing/fault_proxy.zig" TTTTTTTTTT
check $PR x "" "src/brand_new_file.zig" TTTTTTTTTT
check $PR x "" "newdir/file.txt" TTTTTTTTTT
check $PR x "" "fixtures/images.zon" TTTTTTTTTT
check $PR x "" "demo/up.sh" TTTTTTTTTT
# demo-c2: its own files, its docs (off), an unknown path (on), the label and a release branch (on).
check $PR x "" "src/demo_c2_steps.zig ops/demo-c2/run.sh" TFFFFFTFTT
check $PR x "" "docs/demos/c2.md" FFFFFFFFFF
check $PR x "" "src/never_heard_of_it.zig" TTTTTTTTTT
check $PR x "full-ci" "src/demo_c2.zig" TTTTTTTTTT
check $PR claude/release-0.5 "" "src/demo_c2.zig" TTTTTTTTTT
check $PR x "" "src/scheduler_test.zig src/demo_c2.zig" TFFFFFTFFF
# demo-b3: its own files, the files it shares (demo-b1's state, demo-c2's rig), the relay.
check $PR x "" "src/demo_b3_script.zig ops/demo-b3/guest.sh" TFFFFFFFTT
check $PR x "" "src/demo_c2_vms.zig" TFFFFFTFTT
check $PR x "" "src/demo_b1_state.zig" TFFFTFFFTT
check $PR x "" "src/relay.zig" TFFFFTTFTT
check $PR x "" "docs/demos/b3.md" FFFFFFFFFF
# demo-b4: its own script runs it alone; demo-b3's files and the TLS upstream run both.
check $PR x "" "src/demo_b4_script.zig" TFFFFFFFFT
check $PR x "" "src/demo_relay_tls.zig" TFFFFFFFTT
check $PR x "" "docs/demos/b4.md" FFFFFFFFFF
# A narrow path next to an unknown one runs everything; two narrow paths run the union.
check $PR x "" "src/scheduler_test.zig src/server.zig" TTTTTTTTTT
check $PR x "" "src/zigbox_map.zig src/demo_c1_steps.zig" TFFTFTTFTT
# Full: the label, a release branch, a push to main, an unlisted change.
check $PR x "full-ci" "src/scheduler_test.zig" TTTTTTTTTT
check $PR x "bug full-ci" "src/scheduler_test.zig" TTTTTTTTTT
check $PR x "full-cipher" "src/scheduler_test.zig" TFFFFFFFFF
check $PR claude/release-0.4 "" "src/scheduler_test.zig" TTTTTTTTTT
check $PR claude/ci-speed "" "src/scheduler_test.zig" TFFFFFFFFF
check push main "" "src/scheduler_test.zig" TTTTTTTTTT
check push main "" "web/app.js" TTTTTTTTTT
check push main "" "README.md" FFFFFFFFFF
check $PR x "" "" TTTTTTTTTT
check push main "" "" TTTTTTTTTT
# demo-b1's own files run demo-b1 only; docs/demos/b1.md is documentation.
check $PR x "" "src/demo_b1_nodes.zig docs/demos/b1.md" TFFFTFFFFF
check $PR x "" "src/demo_b1.zig src/demo_c1.zig" TFFTTFFFFF

if [ "$failed" -ne 0 ]; then
  echo "ci-changes-test: $failed of $n failed"
  exit 1
fi
echo "ci-changes-test: $n cases passed"
