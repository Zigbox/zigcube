#!/usr/bin/env bash
# Tests of .github/ci-changes.sh: a table of changed paths and the verdict each must get. The
# changes job runs it before it classifies, so a broken rule fails CI instead of skipping a job.
# Each row: EVENT|HEAD_REF|LABELS|paths (space separated)|expected `code store c0 c1 b1 smoke c2 mtls b3 b7 b5 b6 b4 jepsen` as T/F.
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
    s/demo_b7=true/T/; s/demo_b7=false/F/;
    s/demo_b5=true/T/; s/demo_b5=false/F/;
    s/demo_b6=true/T/; s/demo_b6=false/F/;
    s/demo_b4=true/T/; s/demo_b4=false/F/; s/jepsen=true/T/; s/jepsen=false/F/; s/ //g')
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: $event ${ref:+[$ref] }${labels:+[$labels] }${paths:-<no paths>}: want $want, got $got"
    failed=$((failed + 1))
  fi
}

# Verdict order: code store demo_c0 demo_c1 demo_b1 zigbox_smoke demo_c2 mtls_interop demo_b3
# demo_b7 demo_b5 demo_b6 demo_b4 jepsen.
PR=pull_request
# Documentation only: nothing runs.
check $PR x "" "README.md docs/core.md site/index.html" FFFFFFFFFFFFFF
check $PR x "" "docs/demos/c1.md" FFFFFFFFFFFFFF
# ...except src/ and web/ markdown, site/errors, and any code file.
check $PR x "" "src/README.md" TTTTTTTTTTTTTT
check $PR x "" "web/README.md" TFFFFFFFFFFFFF
check $PR x "" "site/errors/ZC-E0001.html" TFFFFFFFFFFFFF
check $PR x "" "README.md ops/sim-fleet/run.sh" TFFFFFFFFFFFFF
check $PR x "" "ops/sim-fleet/test-canary.sh ops/sim-fleet/test-crash-record.sh" TFFFFFFFFFFFFF
# Docs only, but asked for in full.
check $PR x "full-ci" "README.md" TTTTTTTTTTTTTT
check $PR claude/release-0.4 "" "README.md" TTTTTTTTTTTTTT
# Narrow: tests, simulations, the web console, the tools, the gate's own runner.
check $PR x "" "src/scheduler_test.zig" TFFFFFFFFFFFFF
check $PR x "" "src/sim_cluster.zig src/sim_swarm_main.zig" TFFFFFFFFFFFFF
check $PR x "" "web/app.js web/mock/c1.js tools/wasm_check.mjs" TFFFFFFFFFFFFF
check $PR x "" "src/tidy.zig src/testing/check.zig" TFFFFFFFFFFFFF
check $PR x "" "src/console_wasm.zig src/web_embed.zig" TFFFFFFFFFFFFF
# The relay teeth's agent roots run only in the check job (`zig build relay-teeth`).
check $PR x "" "src/zcube_agent_relay_teeth_outlive.zig src/zcube_agent_relay_teeth_unrelayed.zig" TFFFFFFFFFFFFF
# One demo, one smoke, the store suites' own files.
check $PR x "" "src/demo_c0_steps.zig" TFTFFFFFFFFFFF
check $PR x "" "src/demo_c1_fleet.zig docs/demos/c1.md" TFFTTFFFTTTTTF
check $PR x "" "src/demo_c1_state.zig" TFFTTFFFTTTTTF
check $PR x "" "src/demo_c0_state.zig" TFTTTFFFTTTTTF
check $PR x "" "src/demo_c1_partition.zig" TFFTFFFFFFFFFF
check $PR x "" "src/zigbox_runtime.zig" TFFFFTTFTFTFTF
check $PR x "" "ops/zigbox-smoke/guest.sh" TFFFFTFFFFFFFF
check $PR x "" "src/store_faults.zig src/store_failover.zig" TTFFFFFFFFFFFF
check $PR x "" "src/mtls_interop.zig" TFFFFFFTFFFFFF
check $PR x "" "ops/mtls-interop/InteropServer.java" TFFFFFFTFFFFFF
check $PR x "" "src/demo_c0.zig src/demo_c1.zig" TFTTFFFFFFFFFF
# The TLS server sits behind zcube-server's listener since B7 slice 3: it runs everything.
check $PR x "" "src/tls_server.zig src/tls_server_test.zig src/tls_testclient.zig" TTTTTTTTTTTTTT
# Everything: the build, CI itself, the shared demo driver, the server, the agent, the store
# backends, the core, and any path no rule names (also a new directory).
check $PR x "" "build.zig" TTTTTTTTTTTTTT
check $PR x "" "build.zig.zon" TTTTTTTTTTTTTT
check $PR x "" ".github/workflows/ci.yml" TTTTTTTTTTTTTT
check $PR x "" ".github/actions/zig-cache/action.yml" TTTTTTTTTTTTTT
check $PR x "" ".github/ci-changes.sh" TTTTTTTTTTTTTT
check $PR x "" "src/demo_host.zig" TTTTTTTTTTTTTT
check $PR x "" "src/harness_tls.zig" TTTTTTTTTTTTTT
check $PR x "" "src/server.zig" TTTTTTTTTTTTTT
check $PR x "" "src/agent_loop.zig" TTTTTTTTTTTTTT
check $PR x "" "src/store_postgres.zig" TTTTTTTTTTTTTT
check $PR x "" "src/store.zig" TTTTTTTTTTTTTT
check $PR x "" "src/core.zig" TTTTTTTTTTTTTT
check $PR x "" "src/c1_teeth.zig" TTTTTTTTTTTTTT
# The sim job (which runs sim-fencing-teeth) runs on `code`: a change to the fencing arithmetic
# runs everything, one to the simulator alone runs the code jobs.
check $PR x "" "src/fencing.zig" TTTTTTTTTTTTTT
check $PR x "" "src/sim_cluster.zig src/sim_c1_teeth_oldrule_main.zig" TFFFFFFFFFFFFF
# B5 slice 3: the trust world and its tooth are simulator files.
check $PR x "" "src/sim_trust.zig src/sim_c1_teeth_job_untrusted_main.zig" TFFFFFFFFFFFFF
# The Jepsen client, recipe and tarball tool run the code job and the jepsen job only.
check $PR x "" "src/jepsen_client.zig src/jepsen_history.zig src/zcube_jepsen_client.zig" TFFFFFFFFFFFFT
check $PR x "" "ops/jepsen/zigcube.sh ops/jepsen/test-recipe.sh src/dist.zig" TFFFFFFFFFFFFT
check $PR x "" "ops/jepsen/postgres.sh ops/jepsen/test-postgres.sh" TFFFFFFFFFFFFT
check $PR x "" "src/dist.zig" TFFFFFFFFFFFFT
check $PR x "" "ops/jepsen/fault.sh src/scheduler_test.zig" TFFFFFFFFFFFFT
# ops/jepsen/README.md is a .md outside src/ and web/: documentation, nothing runs.
check $PR x "" "ops/jepsen/README.md" FFFFFFFFFFFFFF
# Anything that runs everything runs the jepsen job too.
check $PR x "" "src/server.zig" TTTTTTTTTTTTTT
check $PR x "" "src/testing/fault_proxy.zig" TTTTTTTTTTTTTT
check $PR x "" "src/brand_new_file.zig" TTTTTTTTTTTTTT
check $PR x "" "newdir/file.txt" TTTTTTTTTTTTTT
check $PR x "" "fixtures/images.zon" TTTTTTTTTTTTTT
check $PR x "" "demo/up.sh" TTTTTTTTTTTTTT
# demo-c2: its own files, its docs (off), an unknown path (on), the label and a release branch (on).
check $PR x "" "src/demo_c2_steps.zig ops/demo-c2/run.sh" TFFFFFTFTFTFTF
check $PR x "" "docs/demos/c2.md" FFFFFFFFFFFFFF
check $PR x "" "src/never_heard_of_it.zig" TTTTTTTTTTTTTT
check $PR x "full-ci" "src/demo_c2.zig" TTTTTTTTTTTTTT
check $PR claude/release-0.5 "" "src/demo_c2.zig" TTTTTTTTTTTTTT
check $PR x "" "src/scheduler_test.zig src/demo_c2.zig" TFFFFFTFFFFFFF
# demo-b3: its own files, the files it shares (demo-b1's state, demo-c2's rig), the relay.
check $PR x "" "src/demo_b3_script.zig ops/demo-b3/guest.sh" TFFFFFFFTFFFTF
# demo-b5: its own files, and the rig and state it shares with demo-b3; its docs (off).
check $PR x "" "src/demo_b5.zig src/demo_b5_script.zig ops/demo-b5/guest.sh" TFFFFFFFFFTFFF
check $PR x "" "docs/demos/b5.md" FFFFFFFFFFFFFF
check $PR x "" "src/demo_c2_vms.zig" TFFFFFTFTFTFTF
check $PR x "" "src/demo_c2_check.zig" TFFFFFTFTFTFTF
check $PR x "" "src/demo_b1_state.zig" TFFFTFFFTTTTTF
check $PR x "" "src/relay.zig" TFFFFTTTTFTFTF
check $PR x "" "docs/demos/b3.md" FFFFFFFFFFFFFF
# A narrow path next to an unknown one runs everything; two narrow paths run the union.
check $PR x "" "src/scheduler_test.zig src/server.zig" TTTTTTTTTTTTTT
check $PR x "" "src/zigbox_map.zig src/demo_c1_steps.zig" TFFTFTTFTFTFTF
# Full: the label, a release branch, a push to main, an unlisted change.
check $PR x "full-ci" "src/scheduler_test.zig" TTTTTTTTTTTTTT
check $PR x "bug full-ci" "src/scheduler_test.zig" TTTTTTTTTTTTTT
check $PR x "full-cipher" "src/scheduler_test.zig" TFFFFFFFFFFFFF
check $PR claude/release-0.4 "" "src/scheduler_test.zig" TTTTTTTTTTTTTT
check $PR claude/ci-speed "" "src/scheduler_test.zig" TFFFFFFFFFFFFF
check push main "" "src/scheduler_test.zig" TTTTTTTTTTTTTT
check push main "" "web/app.js" TTTTTTTTTTTTTT
check push main "" "README.md" FFFFFFFFFFFFFF
check $PR x "" "" TTTTTTTTTTTTTT
check push main "" "" TTTTTTTTTTTTTT
# demo-b7's own files run demo-b7 only; docs/demos/b7.md is documentation.
check $PR x "" "src/demo_b7.zig src/demo_b7_steps.zig docs/demos/b7.md" TFFFFFFFFTFFFF
# The interop harness, its server rows and the Java client run mtls-interop only.
check $PR x "" "src/mtls_interop_server.zig ops/mtls-interop/InteropClient.java" TFFFFFFTFFFFFF
# demo-b1's own files run demo-b1 only; docs/demos/b1.md is documentation.
check $PR x "" "src/demo_b1_nodes.zig docs/demos/b1.md" TFFFTFFFFFFFFF
check $PR x "" "src/demo_b1.zig src/demo_c1.zig" TFFTTFFFFFFFFF
# demo-b6's own files run demo-b6 only; it shares demo-b1's state and fleet, so they run it too.
check $PR x "" "src/demo_b6_steps.zig docs/demos/b6.md" TFFFFFFFFFFTFF
check $PR x "" "src/demo_b1_fleet.zig" TFFFTFFFTTTTTF
# B4 slice 4: the relay's TLS half and the supervisor that secures it also run mtls-interop
# (relay) and demo-b4 (with demo-b3); demo-b4's own script runs it alone; the TLS upstream runs both.
check $PR x "" "src/relay_secure.zig" TFFFFTTTTFTFTF
check $PR x "" "src/zigbox_supervisor.zig" TFFFFTTFTFTFTF
check $PR x "" "src/demo_b4_script.zig" TFFFFFFFFFFFTF
check $PR x "" "src/demo_relay_tls.zig" TFFFFFFFTFFFTF
check $PR x "" "docs/demos/b4.md" FFFFFFFFFFFFFF

if [ "$failed" -ne 0 ]; then
  echo "ci-changes-test: $failed of $n failed"
  exit 1
fi
echo "ci-changes-test: $n cases passed"
