#!/usr/bin/env bash
# Tests of .github/ci-changes.sh: a table of changed paths and the verdict each must get. The
# changes job runs it before it classifies, so a broken rule fails CI instead of skipping a job.
# Each row: EVENT|HEAD_REF|LABELS|paths (space separated)|expected `code store c0 c1 b1 smoke c2 mtls b3 b7 b5 b6 b4 jepsen release` as T/F.
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
    s/demo_b4=true/T/; s/demo_b4=false/F/; s/jepsen=true/T/; s/jepsen=false/F/;
    s/release=true/T/; s/release=false/F/; s/ //g')
  n=$((n + 1))
  if [ "$got" != "$want" ]; then
    echo "FAIL: $event ${ref:+[$ref] }${labels:+[$labels] }${paths:-<no paths>}: want $want, got $got"
    failed=$((failed + 1))
  fi
}

# Verdict order: code store demo_c0 demo_c1 demo_b1 zigbox_smoke demo_c2 mtls_interop demo_b3
# demo_b7 demo_b5 demo_b6 demo_b4 jepsen release.
PR=pull_request
# Documentation only: nothing runs.
check $PR x "" "README.md docs/core.md site/index.html" FFFFFFFFFFFFFFF
check $PR x "" "docs/demos/c1.md" FFFFFFFFFFFFFFF
# ...except src/ and web/ markdown, site/errors, and any code file.
check $PR x "" "src/README.md" TTTTTTTTTTTTTTT
check $PR x "" "web/README.md" TFFFFFFFFFFFFFF
check $PR x "" "site/errors/ZC-E0001.html" TFFFFFFFFFFFFFF
check $PR x "" "README.md ops/sim-fleet/run.sh" TFFFFFFFFFFFFFF
check $PR x "" "ops/sim-fleet/test-canary.sh ops/sim-fleet/test-crash-record.sh" TFFFFFFFFFFFFFF
# Docs only, but asked for in full.
check $PR x "full-ci" "README.md" TTTTTTTTTTTTTTT
check $PR claude/release-0.4 "" "README.md" TTTTTTTTTTTTTTT
# Narrow: tests, simulations, the web console, the tools, the gate's own runner.
check $PR x "" "src/scheduler_test.zig" TFFFFFFFFFFFFFF
check $PR x "" "src/sim_cluster.zig src/sim_swarm_main.zig" TFFFFFFFFFFFFFF
check $PR x "" "web/app.js web/mock/c1.js tools/wasm_check.mjs" TFFFFFFFFFFFFFF
check $PR x "" "src/tidy.zig src/testing/check.zig" TFFFFFFFFFFFFFF
check $PR x "" "src/console_wasm.zig src/web_embed.zig" TFFFFFFFFFFFFFF
# The relay teeth's agent roots run only in the check job (`zig build relay-teeth`).
check $PR x "" "src/zcube_agent_relay_teeth_outlive.zig src/zcube_agent_relay_teeth_unrelayed.zig" TFFFFFFFFFFFFFF
# One demo, one smoke, the store suites' own files.
check $PR x "" "src/demo_c0_steps.zig" TFTFFFFFFFFFFFF
check $PR x "" "src/demo_c1_fleet.zig docs/demos/c1.md" TFFTTFFFTTTTTFF
check $PR x "" "src/demo_c1_state.zig" TFFTTFFFTTTTTFF
check $PR x "" "src/demo_c0_state.zig" TFTTTFFFTTTTTFF
check $PR x "" "src/demo_c1_partition.zig" TFFTFFFFFFFFFFF
check $PR x "" "src/zigbox_runtime.zig" TFFFFTTFTFTFTFF
check $PR x "" "ops/zigbox-smoke/guest.sh" TFFFFTFFFFFFFFF
check $PR x "" "src/store_faults.zig src/store_failover.zig" TTFFFFFFFFFFFFF
check $PR x "" "src/mtls_interop.zig" TFFFFFFTFFFFFFF
check $PR x "" "ops/mtls-interop/InteropServer.java" TFFFFFFTFFFFFFF
check $PR x "" "src/demo_c0.zig src/demo_c1.zig" TFTTFFFFFFFFFFF
# The TLS server sits behind zcube-server's listener since B7 slice 3: it runs everything.
check $PR x "" "src/tls_server.zig src/tls_server_test.zig src/tls_testclient.zig" TTTTTTTTTTTTTTT
# C5 slice 1: the public path shares the TLS server with B7's listeners, so its files run
# everything; its browser check runs in the mtls-interop job, and its fixture recorder runs the
# code job only.
check $PR x "" "src/edge_host.zig src/tls_server_public_test.zig src/public_tls_listener.zig" TTTTTTTTTTTTTTT
check $PR x "" "tools/public_tls_check.mjs" TFFFFFFTFFFFFFF
check $PR x "" "tools/record_client_hello.mjs" TFFFFFFFFFFFFFF
# Everything: the build, CI itself, the shared demo driver, the server, the agent, the store
# backends, the core, and any path no rule names (also a new directory).
check $PR x "" "build.zig" TTTTTTTTTTTTTTT
check $PR x "" "build.zig.zon" TTTTTTTTTTTTTTT
check $PR x "" ".github/workflows/ci.yml" TTTTTTTTTTTTTTT
check $PR x "" ".github/actions/zig-cache/action.yml" TTTTTTTTTTTTTTT
check $PR x "" ".github/ci-changes.sh" TTTTTTTTTTTTTTT
check $PR x "" "src/demo_host.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/harness_tls.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/server.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/agent_loop.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/store_postgres.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/store.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/core.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/c1_teeth.zig" TTTTTTTTTTTTTTT
# The sim job (which runs sim-fencing-teeth) runs on `code`: a change to the fencing arithmetic
# runs everything, one to the simulator alone runs the code jobs.
check $PR x "" "src/fencing.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/sim_cluster.zig src/sim_c1_teeth_oldrule_main.zig" TFFFFFFFFFFFFFF
# B5 slice 3: the trust world and its tooth are simulator files.
check $PR x "" "src/sim_trust.zig src/sim_c1_teeth_job_untrusted_main.zig" TFFFFFFFFFFFFFF
# The Jepsen client and recipe run the code job and the jepsen job only; the tarball tool
# (src/dist.zig) also packs the release, so it runs the release job too.
check $PR x "" "src/jepsen_client.zig src/jepsen_history.zig src/zcube_jepsen_client.zig" TFFFFFFFFFFFFTF
check $PR x "" "ops/jepsen/zigcube.sh ops/jepsen/test-recipe.sh src/dist.zig" TFFFFFFFFFFFFTT
check $PR x "" "ops/jepsen/postgres.sh ops/jepsen/test-postgres.sh" TFFFFFFFFFFFFTF
check $PR x "" "src/dist.zig" TFFFFFFFFFFFFTT
check $PR x "" "ops/jepsen/fault.sh src/scheduler_test.zig" TFFFFFFFFFFFFTF
# ops/jepsen/README.md is a .md outside src/ and web/: documentation, nothing runs.
check $PR x "" "ops/jepsen/README.md" FFFFFFFFFFFFFFF
# Anything that runs everything runs the jepsen job too.
check $PR x "" "src/server.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/testing/fault_proxy.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/brand_new_file.zig" TTTTTTTTTTTTTTT
check $PR x "" "newdir/file.txt" TTTTTTTTTTTTTTT
check $PR x "" "fixtures/images.zon" TTTTTTTTTTTTTTT
check $PR x "" "demo/up.sh" TTTTTTTTTTTTTTT
# demo-c2: its own files, its docs (off), an unknown path (on), the label and a release branch (on).
check $PR x "" "src/demo_c2_steps.zig ops/demo-c2/run.sh" TFFFFFTFTFTFTFF
check $PR x "" "docs/demos/c2.md" FFFFFFFFFFFFFFF
check $PR x "" "src/never_heard_of_it.zig" TTTTTTTTTTTTTTT
check $PR x "full-ci" "src/demo_c2.zig" TTTTTTTTTTTTTTT
check $PR claude/release-0.5 "" "src/demo_c2.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/scheduler_test.zig src/demo_c2.zig" TFFFFFTFFFFFFFF
# demo-b3: its own files, the files it shares (demo-b1's state, demo-c2's rig), the relay.
check $PR x "" "src/demo_b3_script.zig ops/demo-b3/guest.sh" TFFFFFFFTFFFTFF
# demo-b5: its own files, and the rig and state it shares with demo-b3; its docs (off).
check $PR x "" "src/demo_b5.zig src/demo_b5_script.zig ops/demo-b5/guest.sh" TFFFFFFFFFTFFFF
check $PR x "" "docs/demos/b5.md" FFFFFFFFFFFFFFF
check $PR x "" "src/demo_c2_vms.zig" TFFFFFTFTFTFTFF
check $PR x "" "src/demo_c2_check.zig" TFFFFFTFTFTFTFF
check $PR x "" "src/demo_b1_state.zig" TFFFTFFFTTTTTFF
check $PR x "" "src/relay.zig" TFFFFTTTTFTFTFF
check $PR x "" "docs/demos/b3.md" FFFFFFFFFFFFFFF
# A narrow path next to an unknown one runs everything; two narrow paths run the union.
check $PR x "" "src/scheduler_test.zig src/server.zig" TTTTTTTTTTTTTTT
check $PR x "" "src/zigbox_map.zig src/demo_c1_steps.zig" TFFTFTTFTFTFTFF
# Full: the label, a release branch, a push to main, an unlisted change.
check $PR x "full-ci" "src/scheduler_test.zig" TTTTTTTTTTTTTTT
check $PR x "bug full-ci" "src/scheduler_test.zig" TTTTTTTTTTTTTTT
check $PR x "full-cipher" "src/scheduler_test.zig" TFFFFFFFFFFFFFF
check $PR claude/release-0.4 "" "src/scheduler_test.zig" TTTTTTTTTTTTTTT
check $PR claude/ci-speed "" "src/scheduler_test.zig" TFFFFFFFFFFFFFF
check push main "" "src/scheduler_test.zig" TTTTTTTTTTTTTTT
check push main "" "web/app.js" TTTTTTTTTTTTTTT
check push main "" "README.md" FFFFFFFFFFFFFFF
check $PR x "" "" TTTTTTTTTTTTTTT
check push main "" "" TTTTTTTTTTTTTTT
# demo-b7's own files run demo-b7 only; docs/demos/b7.md is documentation.
check $PR x "" "src/demo_b7.zig src/demo_b7_steps.zig docs/demos/b7.md" TFFFFFFFFTFFFFF
# The interop harness, its server rows and the Java client run mtls-interop only.
check $PR x "" "src/mtls_interop_server.zig ops/mtls-interop/InteropClient.java" TFFFFFFTFFFFFFF
# demo-b1's own files run demo-b1 only; docs/demos/b1.md is documentation.
check $PR x "" "src/demo_b1_nodes.zig docs/demos/b1.md" TFFFTFFFFFFFFFF
check $PR x "" "src/demo_b1.zig src/demo_c1.zig" TFFTTFFFFFFFFFF
# demo-b6's own files run demo-b6 only; it shares demo-b1's state and fleet, so they run it too.
check $PR x "" "src/demo_b6_steps.zig docs/demos/b6.md" TFFFFFFFFFFTFFF
check $PR x "" "src/demo_b1_fleet.zig" TFFFTFFFTTTTTFF
# B4 slice 4: the relay's TLS half and the supervisor that secures it also run mtls-interop
# (relay) and demo-b4 (with demo-b3); demo-b4's own script runs it alone; the TLS upstream runs both.
check $PR x "" "src/relay_secure.zig" TFFFFTTTTFTFTFF
check $PR x "" "src/zigbox_supervisor.zig" TFFFFTTFTFTFTFF
check $PR x "" "src/demo_b4_script.zig" TFFFFFFFFFFFTFF
check $PR x "" "src/demo_relay_tls.zig" TFFFFFFFTFFFTFF
check $PR x "" "docs/demos/b4.md" FFFFFFFFFFFFFFF
# The release workflow, its scripts and actions run the release job only; src/dist.zig packs
# both the Jepsen tarball and the release; build.zig and the rest of .github still run all.
check $PR x "" ".github/workflows/release.yml" TFFFFFFFFFFFFFT
check $PR x "" ".github/release-libs.sh .github/release-check.sh" TFFFFFFFFFFFFFT
check $PR x "" ".github/actions/setup-gh/action.yml .github/actions/find-draft/action.yml" TFFFFFFFFFFFFFT
check $PR x "" "ops/jepsen/zigcube.sh" TFFFFFFFFFFFFTF
check $PR x "" ".github/workflows/ci.yml" TTTTTTTTTTTTTTT
check $PR x "" ".github/actions/setup-zig/action.yml" TTTTTTTTTTTTTTT
check $PR x "" "docs/releases/automation.md" FFFFFFFFFFFFFFF
# A release's notes are not documentation only: they run everything, on a pull request and on main.
check $PR x "" "docs/releases/0.6.0.md" TTTTTTTTTTTTTTT
check $PR x "" "docs/releases/0.6.0.md README.md site/index.html" TTTTTTTTTTTTTTT
check push main "" "docs/releases/0.6.0.md" TTTTTTTTTTTTTTT

if [ "$failed" -ne 0 ]; then
  echo "ci-changes-test: $failed of $n failed"
  exit 1
fi
echo "ci-changes-test: $n cases passed"
