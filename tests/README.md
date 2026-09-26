# tests

Offline tests. None of them need a cluster, a Helm repository or Azure; they run
from a clone and are part of `scripts/validate.sh`.

```bash
tests/run-all.sh              # everything that runs without extra binaries
tests/run-all.sh --against-cli   # also compare every flag with the installed CLIs
```

| Suite | What it covers | Requires |
|---|---|---|
| `cli-flags/` | Flags the pinned CLI version no longer accepts, in shell scripts, WorkflowTemplates and Markdown | python3 (PyYAML) |
| `helm4/` | `workflows/scripts/helm-addons.sh` end to end against a Helm 4 CLI | python3, jq, yq (mikefarah) |
| `shared-lib/` | The shared library block in `workflows/scripts/common.sh`: identical to the copy in tpg-aks-infra, retries, pod watch (including `--started-ok` for Vault) | jq |
| `sync-engine/` | The Argo CD sync engine (`app_sync_wait` in `workflows/scripts/lib.sh`) against a scripted Argo CD API | jq |
| `rollout/` | `rolloutMode` of tpg-day0, tpg-upgrade and tpg-patch (`workflows/scripts/plan-batches.sh`) | jq |
| `params/` | Input types: `workflows/params/types.yaml`, the generated policy, the WorkflowTemplates, the clusterMap key registry and the Type columns of `docs/workflow-commands.md` agree | python3 (PyYAML) |
| `cluster-map/` | clusterMap validation (`clustermap.py`, `validate-params.sh` per workflow), the `lib.sh` accessors, and the tpg-day0 version rule (FLEET_OVERRIDDEN, UPGRADE_REQUIRED, DOWNGRADE_NOT_ALLOWED, VERSION_UNKNOWN) | python3, jq, yq (mikefarah) |
| `patch/` | tpg-patch planning (`patch-plan.sh`): refused fields, `patchMode`, the `fleet.yaml` references, the postgresVersion guard, the dry run of the patched instance | helm (skipped without it), python3, jq, yq |
| `chart/` | `charts/tpg-instance`: Service exposure and its Azure annotations, `instance.serviceType` refused, `caBundle` only with `enableSSL: true` (and required then), the network policy objects, no empty NetworkPolicy peer list | helm (skipped without it), python3 (PyYAML), yq |
| `day0-plan/` | tpg-day0 and tpg-create-instance: the plan (`fleet-day0.sh`, the CA bundle placeholder), ownership from the Argo CD Application's resource list (`day0-precheck.sh`), `ORPHAN_CRD`, `OPERATOR_NOT_INSTALLED`, `HA_NODES_EXCEED_ZONES`, `AZURE_BACKUP_UNSUPPORTED`, the creation rules, `ALREADY_EXISTS`, `INSTANCE_EXISTS`, `fleet-commit.sh` (passed clusters only, `FLEET_CHANGED_DURING_RUN`), `blocked-gate.sh`, and the upgrade guard for absent instances | helm (skipped without it), python3, jq, yq |
| `network-policy/` | tpg-network-policy planning (`network-policy.sh plan`): `apply`, `update`, `remove`, clusterMap rules over the inputs, the postgresVersion guard, `CILIUM_NOT_AVAILABLE`, `DRY_RUN_REJECTED`, `ACNS_NOT_ENABLED`, `INSTANCE_NOT_FOUND`, invalid CIDRs, dry run | helm (skipped without it), python3, jq, yq |
| `submit/` | `scripts/submit/tpg-*.sh` through the numbered menus with stub `argo` and `kubectl`: type checks, optional inputs, map inputs, a pasted clusterMap, the kubectl fallback, Cancel | python3, jq, yq |
| `pgdata/` | `tools/pgdata/pgdata.py` against a throwaway local PostgreSQL (initdb on a free port): every command and format, and the refused input (types, identifiers, `--where`, writes through `--sql`) | PostgreSQL server binaries and psycopg 3 (skipped without them) |
| `admission/` | Both ValidatingAdmissionPolicies on a real kube-apiserver: the Workflow parameter types and the Application sync policy | envtest binaries (skipped without them), openssl |
| `ssa/` | Operator manifest patches and server-side apply field ownership (tpg-patch, Argo CD sync with and without RespectIgnoreDifferences, release) on a real kube-apiserver | envtest binaries (skipped without them), openssl, jq, yq |

`tpg-aks-infra/tests/verify/run.sh` covers `scripts/steps/60-verify.sh` and its
summary, and uses the stubs in `helm4/bin`, so both repositories test against
the same fakes. `tpg-aks-infra/tests/argocd-rbac/run.sh` checks the Argo CD
RBAC block with the real `argocd` CLI (skipped without it). `run-all.sh` runs
both when tpg-aks-infra is a sibling. `tpg-aks-infra/tests/shared-lib/run.sh`
is the same file as `shared-lib/run.sh` here.

The envtest binaries (etcd, kube-apiserver, kubectl) come from
`setup-envtest use 1.34.1` (controller-runtime); set `KUBEBUILDER_ASSETS` to
their folder.

## cli-flags

A removed CLI flag is invisible to yamllint, shellcheck and kubeconform. It
fails at run time, inside a workflow step, halfway through a deployment. That is
how `helm list -a` reached the fleet: the workflow tools image moved to
`alpine/k8s:1.35.8`, which ships Helm 4, and Helm 4 removed `-a`.

`check_cli_flags.py` reads the commands out of the repository and applies
`rules.yaml`, which lists per tool and subcommand the flags that are gone or
renamed, why, and what to write instead. Add a rule whenever a pinned image
moves to a new major CLI version, and add a line to
`fixtures/violations.sh` for it: `run.sh` asserts that every rule fires exactly
once there and that nothing fires in `fixtures/clean.md`, so a rule that stops
matching, or one that matches too much, fails the suite.

`--against-cli` goes further and asks every installed binary for its own flags
(`<tool> <subcommand> --help`), then reports each flag the repository uses that
the binary does not know. It catches changes nobody has written a rule for yet.
Tools that are not installed are skipped, so it is safe to run anywhere.

## helm4

`bin/helm` and `bin/kubectl` are stubs. The helm stub parses flags the way Helm
4 does: `helm list -a` exits 1 with `unknown shorthand flag: 'a'`, exactly as
the real binary does in the tools image, and `helm registry login` rejects a
host with a path. Cluster and release state come from JSON files, so the add-on
pre-check can be driven through all of its outcomes: `DRY_RUN`, `UP_TO_DATE`,
`SKIPPED_EXISTS`, `SKIPPED_NEWER`, `REUSED_EXISTING` and `BLOCKED`.

The last case in the suite runs `helm list -a` against the stub and fails if it
is accepted, so a green suite cannot mean "the stub accepts anything".

## shared-lib

`workflows/scripts/common.sh` (tpg-fleet) and `scripts/lib/common.sh`
(tpg-aks-infra) carry the same block, between `# >>> tpg-shared >>>` and
`# <<< tpg-shared <<<`: the retrying `kubectl`, `helm`, `az` and `argocd`
wrappers (`tpg_retry`), `pods_watch`, the Helm release pre-check and install
(`hr_*`) and `monitoring_flowing`. The suite

1. fails when the two copies differ (edit one, then run `tests/shared-lib/sync.sh`
   in that repository to copy the block to the other);
2. drives `tpg_retry` with stub commands: a transient API error is retried and
   the output appears once; a NotFound or a `helm --wait` timeout is not
   retried; `-f -` input is given to every attempt, while a command that does
   not read standard input leaves the caller's loop input alone; a `create` that
   reached the server before the connection dropped counts as created;
   `kubectl exec` is never retried; the retry log does not print arguments;
3. drives `pods_watch` with pod lists: ready pods pass,
   `CreateContainerConfigError` fails at once, `CrashLoopBackOff` is tolerated
   for `POD_WATCH_PERSIST_SECONDS` (60) and then fails, an unschedulable pod fails
   after `POD_WATCH_PENDING_SECONDS` (300) with the scheduler's message, an init
   container failure is named, and the failure prints the pod's events and logs
   (with `--previous` for a restarted container).

## sync-engine

The workflows sync Applications through `app_sync_wait`. The suite scripts the
Argo CD API responses and proves that the previous operation's `Succeeded` is
not taken as the answer, that an admission webhook denial fails at once with
`SYNC_REJECTED` after one request (the upgrade used to record `SUCCEEDED`
there), that a transient error is synced again, that an Application that stays
OutOfSync fails with `SYNC_DRIFT`, and that a stuck operation ends with
`SYNC_TIMEOUT`.

## rollout

`plan-batches.sh` with a stub `lib.sh`: `canary` (the wave-0 cluster alone,
then batches of `maxParallel` per wave), `batches` (no canary) and `all` (one
batch), and an unknown mode fails.

The sync-engine suite also covers `MANUAL_SYNC_DETECTED`: an Application whose
last operation was started by someone other than `workflow-bot` is reported as
a warning and the sync goes ahead.

## params

Argo Workflows parameters have no type, so `workflows/params/types.yaml`
declares one per input and `workflows/params/generate.py` turns it into the
ValidatingAdmissionPolicy `workflows/admission/workflow-parameters.yaml`. The
suite fails when:

- the generated file is out of date (`generate.py --check`);
- a WorkflowTemplate input has no type, or a type names an input the template
  does not have;
- a template default does not match its own type, or an enum differs from the
  template's `enum`;
- `workflows/params/cluster-map-keys.yaml` names a workflow without a
  `clusterMap` input, a key has an unknown type, or its default input ("flag")
  is not an input of that workflow;
- a row of an input table in `docs/workflow-commands.md` shows a Type other than
  the `display` of its type, or an input has no row.

## cluster-map

`clustermap.py` and `validate-params.sh` for every workflow that takes
`clusterMap`: unknown keys with a suggestion, wrong types, keys a workflow does
not accept, missing required values (map key or input), a cluster without
instances, `clusterMap` together with `clusters` or `instances`, `confirm` of
the delete workflows (in any order), a `mode=backup` restore without an in-place target, YAML and JSON input, and a Postgres version written as a
number (`16.10`). It also runs `fleet-day0.sh` with stub clusters to prove the
version rule of tpg-day0: an input that nothing runs yet replaces the value in
`fleet.yaml`, and a running operator or instance of another version blocks the
cluster.

## patch

Runs `patch-plan.sh` with the real `lib.sh` and chart, and stubs for Git, the
run ConfigMap, the Argo CD API and the target cluster: refused fields (each
message names the owning workflow), `patchMode` `append`, `replace` and
`remove` in `fleet.yaml`, the clusterMap `postgresVersion` guard, and the
server-side dry-run document, rendered by `helm template`, which carries the
merged patch. It is skipped when `helm` is not installed. `scripts/validate.sh`
also renders the chart with the example patch files of
`clusters/fleet.example.yaml`.

## chart

Renders `charts/tpg-instance` with `helm template` for each case and checks the
objects with PyYAML: the three exposures and their annotations, the refusal of
`instance.serviceType` and of an unknown exposure, `caBundle` with and without
`enableSSL`, the network policy objects with and without ACNS, and that every
NetworkPolicy ingress rule has a non-empty peer list and that no peer is made of
empty selectors only (an empty peer list, an empty peer or `namespaceSelector: {}`
alone allows every source; `podSelector: {}` alone, the instance namespace, is
the one exception).

## day0-plan

Runs `fleet-day0.sh`, `day0-precheck.sh`, `fleet-commit.sh`, `blocked-gate.sh`,
`operator-upgrade.sh` and `discover.sh` with the real `lib.sh`, `clustermap.py` and chart, and
a stub target selected per case by scenario variables (`S_OPERATOR`,
`S_TRACKED`, `S_CRD_TRACKED`, `S_APPRES`, `S_RUNNING`, `S_ZONES`, `S_AZURE`,
`S_CRDS`, `S_CA`, `S_ACNS`, `S_API_ERR`, described at the top of the file). The
case that started Round 12 is case 1: a tpg-day0 re-run adding an instance to a
cluster whose Postgres CRDs carry no tracking annotation but are listed by the
operator Application (the operator Deployment itself must carry the annotation).
Case 7 checks that the plan carries the CA bundle as a placeholder (21 instances
stay under 16 KiB) and that the commit writes the PEM; case 11 runs `discover.sh`
after a plan that blocked an instance.

## network-policy

Runs `network-policy.sh plan` with the real chart; the rendered policies are
sent to a stub `kubectl apply --dry-run=server` that can refuse them
(`S_REJECT`). Checks the `network` entry written for each mode, the records
(`precheck`, `plan`, `result`) and that a blocked cluster is not written.
The apply phase (`network-policy.sh apply`: the sync, `archive_check`, the probe
pods) needs a cluster with Cilium and is covered by the lab checks V48 to V50
of the tpg-fleet README, not by this suite.

## submit

Runs the submit scripts with stdin from a here-document, so they use the
numbered menus, in a `PATH` that holds only the tools they need, a stub
`kubectl` (registered clusters, `create -f`) and, where the case wants it, a stub
`argo` that records its arguments.

## pgdata

Starts a PostgreSQL server with `initdb` and `pg_ctl` in a temporary directory
(as `nobody` when the suite runs as root), on a free port, UTF8, and runs every
`pgdata.py` command against it. Skipped without the server binaries or psycopg.

## admission and ssa

Both suites start etcd and kube-apiserver from the envtest binaries
(`tests/envtest/apiserver.sh`) with the Argo CD v3.5.3 Application CRD and the
Argo Workflows v4.1.3 Workflow CRD.

`admission` applies the two policies and submits Workflows and Application
updates as different users: a Workflow with every default passes for each
template; a wrong type, an unknown input, an old input name and a malformed
`clusterMap` are rejected with the input and its type, and `clusters=all` is
refused where a list of names is expected; Workflows of other templates are not
affected. A new operation on a target Application is accepted only from
argocd-server on behalf of `workflow-bot` (or `workflow-bot:apiKey`); switching
on automated sync is refused; the controller clearing the operation, status and
annotation updates, and hub Applications are not affected.

`ssa` applies operator manifest patches with the functions the workflows use:
two files merge into one server-side apply (the later file wins), a sync with
RespectIgnoreDifferences keeps the patched values, a sync without it (operator
upgrade) takes them back and `operator_patch_diffs` names every override, a
removed patch file releases only the fields the patch alone set, and applying
the files one by one with one field manager would lose the first file's fields.
