# agent-ops design

Design for the agent reference implementation, its tests, and its delivery loop. The deterministic runtime and source-level eval path are implemented; image and k3s validation are the current milestone.

The system is intended to build hands-on expertise, provide demonstrable consulting experience, and serve as a client-adaptable deployment pattern.

Host, namespace, and deploy commands stay as documented in `workspace.md` and `README.md`. This file is the product shape those commands will carry.

## Decisions

1. One runtime process runs many agents. An agent is a spec in git, not its own Deployment.
2. Tests, GitHub Actions evals, and the cluster pod call the same turn function. The cluster is a place to run that function, not a second implementation.
3. The same suite runs against source and against a build. Source is the fast check. The build check runs the image produced from `services/runtime/Dockerfile` on the Ubuntu host after `./ssh-ubuntu.sh build`. Passing source does not stand in for that image.
4. The Mac does not run Docker. `docker build` and `docker run` for this loop happen on the Ubuntu k3s host. GitHub-hosted runners can build that same Dockerfile later for the merge gate. They do not SSH to the Ubuntu host, push to `localhost:5000`, or helm-upgrade anything. The laptop cluster is not reachable from `ubuntu-latest`, and it is shared with RAGline.
5. A merge does not require a live model. Fixture evals are the required check, including fixture evals against the image once the Dockerfile exists. Live-model evals are a separate workflow that uses Actions secrets, and that workflow also runs them against the image.
6. The first agent is deterministic and has no tools and no model key. The deploy loop and CI can go green before any provider is wired up.
7. v1 language is Python 3.12 and pytest. `scripts/render-local-secret-values.sh` already uses Python. A framework can wait until the turn contract is real.
8. The runtime holds provider keys, so v1 exposure is ClusterIP plus `kubectl port-forward`. An open node port waits until requests carry a bearer token. Port 8000 stays RAGline's.

## System

```text
agents/<name>/agent.yaml          spec: instructions, tools, limits, provider
        │
        ▼
runtime.turn(agent, input)         one function
        │
        ├── pytest                 fake provider, no network
        ├── eval CLI, in-process   source tree
        ├── eval CLI, HTTP         a built image, or the pod serving that image
        └── HTTP POST /turns       the process inside the image
```

| Piece | Role |
| --- | --- |
| Agent spec | Name, instructions, tool allowlist, limits, provider. Loaded from `agents/`. |
| Turn | One call: input in, output plus a trace out. |
| Provider | Fake, OpenAI, or Azure OpenAI. Selected by the spec. Missing keys fail that provider only. |
| Tools | Named functions the spec allows. v1 ships an empty tool list. |
| Eval case | Input plus scorers for one agent. |
| Runtime service | `services/runtime`. Image `agent-ops-runtime`. Deployment `agent-ops-runtime`. |
| Helm chart | `charts/agent-ops`. One Deployment until a second process is actually required. |

Foundry, or any other external runtime, is a later provider behind `turn`. Evals keep calling `turn`, so a runtime swap does not rewrite the suite.

## Agent spec

Path: `agents/<name>/agent.yaml`.

```yaml
name: hello
version: 0
provider: fake          # fake | openai | azure_openai
model: ""               # required when provider is not fake
instructions: |
  Reply with the single word hello.
tools: []
limits:
  max_turns: 1
  timeout_seconds: 30
  max_output_chars: 2000
```

Rules:

- `name` matches the directory name.
- `provider: fake` returns scripted output from the spec or from the eval case. It is the CI default.
- `tools` is an allowlist. The runtime rejects a tool the spec does not name.
- `version` increments when instructions or tools change. Eval reports record it.
- Secrets are not fields on the spec. The provider reads `OPENAI_API_KEY` or `AZURE_OPENAI_API_KEY` from the environment.

First specs, in order:

| Agent | Provider | Purpose |
| --- | --- | --- |
| `hello` | `fake` | Prove spec load, turn, fixture eval, image, Helm, smoke. |
| `reply` | `openai` or `azure_openai` | One live model, no tools. Chosen when the first key is available. |
| a later tool agent | live | One tool, after `reply` has a baseline. |

A supervisor that calls other agents waits until one live agent has a committed baseline. v1 has no memory, no PVC, and no background jobs.

## Turn contract

```json
{
  "agent": "hello",
  "input": "hi",
  "case_id": "hello-hi"
}
```

```json
{
  "agent": "hello",
  "agent_version": 0,
  "output": "hello",
  "tool_calls": [],
  "usage": { "input_tokens": 0, "output_tokens": 0 },
  "trace_id": "01J...",
  "error": null
}
```

`error` is a string code (`timeout`, `provider`, `tool_denied`, `bad_spec`) or null. Scorers see a failed turn as a failed case. The HTTP handler returns 200 with `error` set for agent failures, and 4xx only for a malformed request or an unknown agent. That keeps eval accounting in one place.

Logs are one JSON object per turn: `trace_id`, `agent`, `agent_version`, `provider`, `case_id`, `error`, token counts, latency. Logs omit the raw prompt, the raw output, and any key.

`POST /turns` on the pod accepts the same body. `GET /healthz` returns 200 when the process can load specs. It does not call a provider.

## Evals

An eval case is a YAML file under `evals/cases/<agent>/`.

```yaml
id: hello-hi
agent: hello
status: active        # active | draft
input: "hi"
scorers:
  - name: contains
    value: "hello"
```

| Scorer | v1 | Behavior |
| --- | --- | --- |
| `contains` | yes | Output contains a string. |
| `exact` | yes | Output equals a string after trim. |
| `schema` | yes | Output parses as JSON with required keys. |
| `max_chars` | yes | Output length is within the spec limit. |
| `error_code` | yes | Turn `error` equals an expected code. |
| judge model | later | A second model grades the output. It is non-deterministic and costs money, so it does not gate v1. |

`status: draft` runs and shows up in the report. It does not change the pass rate that CI gates on.

Baseline file: `evals/baselines/<agent>.json`, committed. It stores the latest accepted result for each `active` case: case id, pass/fail, scorer names, agent version, provider, model. CI fails when an `active` case in the baseline no longer passes. Adding a case does not edit the baseline by itself. Updating a baseline is a separate commit with the report attached to the PR so a quieter prompt cannot silently lower the bar.

The eval CLI takes a target. Cases and scorers stay the same for every target.

```text
python -m agent_ops.eval --suite evals/cases --provider fake
python -m agent_ops.eval --suite evals/cases --provider live --agent reply
python -m agent_ops.eval --suite evals/cases --provider fake --target http://127.0.0.1:8080
```

`--provider fake` never reads a model network. `--provider live` uses the provider on each spec and skips specs whose key is absent, recording `skipped` rather than `failed`. `--target` defaults to in-process. An `http://` target sends each case to `POST /turns` on a running build.

Two checks apply to every image, local or CI:

1. **In the image.** `docker run --rm <image> python -m agent_ops.eval --provider fake` runs the suite with the package, specs, and cases baked into that image. A checkout that passes and an image that omitted `agents/` or `evals/` will disagree here.
2. **Against the image.** Start the image, then point `--target http://...` at it. This is the server wiring the pod will use. After a rollout, the same command points at `kubectl port-forward` for that release.

The command writes `eval-report.json` and a short text summary. The report contains case id, pass/fail, scorer, agent version, provider, model, trace id, and `target` (`inproc` or the image ref). It does not contain API keys or full prompts.

## GitHub Actions

Two workflows. Both use GitHub-hosted `ubuntu-latest`. Neither has cluster credentials.

### `test` — required on every pull request and on `main`

```text
checkout
setup Python 3.12
install the package (no provider SDKs required for this job)
pytest
python -m agent_ops.eval --provider fake
docker build -f services/runtime/Dockerfile -t agent-ops-runtime:ci .
docker run --rm agent-ops-runtime:ci python -m agent_ops.eval --provider fake
docker run -d --name runtime-ci -p 8080:8080 agent-ops-runtime:ci
python -m agent_ops.eval --provider fake --target http://127.0.0.1:8080
helm lint charts/agent-ops
helm template charts/agent-ops -f charts/agent-ops/values-ci.yaml
```

The image is tagged `agent-ops-runtime:ci` on the runner and discarded with the job. CI does not push it. Until `services/runtime/Dockerfile` exists, the workflow runs the in-process steps only. The image steps become required in the same workflow as soon as the Dockerfile lands.

`values-ci.yaml` is a committed file with the registry name, an immutable sample tag, `imagePullPolicy: IfNotPresent`, ClusterIP, and empty secret values. It is safe to render in public CI.

This job is the merge gate. It passes with no Actions secrets, including on pull requests from forks. Fork pull requests do not receive secrets.

### `eval` — live models, not a merge gate at first

Triggers: push to `main`, and `workflow_dispatch`. It does not run on fork pull requests.

```text
checkout
setup Python 3.12
python -m agent_ops.eval --provider live
docker build -f services/runtime/Dockerfile -t agent-ops-runtime:ci .
docker run -d --name runtime-ci -p 8080:8080
  -e OPENAI_API_KEY -e AZURE_OPENAI_API_KEY
  agent-ops-runtime:ci
python -m agent_ops.eval --provider live --target http://127.0.0.1:8080
upload both eval-report.json files
compare active cases to evals/baselines/
```

Live evals run twice: in-process, then against the image just built. A regression in either report fails the comparison. The image still is not pushed.

Secrets are repository Actions secrets: `OPENAI_API_KEY`, `AZURE_OPENAI_API_KEY`. The workflow maps them to the same env names the pod will use. Steps must not print the environment.

Concurrency: one live run per branch, cancel the previous run. The job fails when a baseline `active` case regresses. A missing secret skips that provider and does not fail the job while live eval is still optional. Once `reply` has a baseline, that provider's secret becomes required and a skip becomes a failure.

The live job writes a short summary to the Actions step summary: pass count, fail count, skip count, regressions. It does not deploy, comment secrets, or push images.

### What CI does not do

Deploy stays on the Mac, through `./ssh-ubuntu.sh`, against namespace `agent-ops`. A self-hosted runner that calls those scripts is a later phase, after the manual loop has been proven once. That runner would still be forbidden from namespace `ragline` and from port 8000.

## Testing

| Layer | Invoked by | Secrets | Cluster |
| --- | --- | --- | --- |
| Unit | `pytest` | no | no |
| Spec contract | `pytest` | no | no |
| Fixture eval, source | `agent_ops.eval --provider fake` | no | no |
| Fixture eval, image | eval inside the image, then `--target http://` at that image | no | no |
| Chart render | `helm lint`, `helm template` | no | no |
| Live eval, source | `agent_ops.eval --provider live` | Actions secrets or local env | no |
| Live eval, image | `--provider live --target http://` at the built image | same keys passed into the container | no |
| Image build | `docker build` in CI, or `./ssh-ubuntu.sh build runtime <tag>` on Ubuntu | no | Ubuntu Docker only for the laptop loop |
| Rollout eval | same HTTP suite through `kubectl port-forward` | local `helm.env` only | k3s namespace `agent-ops` |

Unit tests currently cover the fake turn, fixture evaluation behavior, runtime health, the HTTP handler, and chart safety defaults. Tool allowlist enforcement and live providers arrive in later phases. Tests do not call OpenAI or Azure.

Chart tests render the Deployment and assert:

- image is `localhost:5000/agent-ops-runtime:<tag>`
- `imagePullPolicy` is `IfNotPresent`
- Deployment name is `agent-ops-runtime` (this is the name `./ssh-ubuntu.sh rollout runtime` waits on)
- Service type is ClusterIP
- no host port and no node port 8000
- no Secret data in the committed values; secret keys are referenced from the gitignored overlay

Smoke, once the pod exists, is `kubectl port-forward` to `/healthz` and the fixture suite pointed at that forward. One `hello` turn is the minimum. `AGENT_OPS_SMOKE_PORT` stays empty while the Service is ClusterIP. The pod eval uses the release that was just rolled out, so a chart that mounts the wrong spec or drops the baked-in cases fails here even if the CI image passed.

## Deploy shape

When the runtime image exists, the local loop is:

```bash
./ssh-ubuntu.sh unlock
./ssh-ubuntu.sh push-src
./ssh-ubuntu.sh build runtime dev-<tag>
# on the Ubuntu host, against that tag: in-image fixture suite, then HTTP suite
./ssh-ubuntu.sh deploy dev-<tag>
./ssh-ubuntu.sh rollout runtime
# same HTTP suite through port-forward at the rolled-out pod
./ssh-ubuntu.sh smoke
```

The Mac runs `./ssh-ubuntu.sh` only. The `docker build` inside `build`, and the `docker run` evals of that image, execute on the Ubuntu host.

`build` and `deploy` take the same tag. `push-src` does not copy `.git`, so the tag is explicit. A rebuild uses a new tag (`dev-<tag>-r2`) because pull policy is `IfNotPresent`.

Target image name on the shared registry: `localhost:5000/agent-ops-runtime:<tag>`. The `agent-ops-` prefix keeps the repository distinct from RAGline images in `localhost:5000`; the build script and chart use the same name.

Helm release `agent-ops`, namespace `agent-ops`, chart `charts/agent-ops`. One replica. No PVC. Provider keys come from `helm.env` through `scripts/render-local-secret-values.sh` into `charts/agent-ops/values-local-secrets.yaml`, which stays gitignored.

## Secrets

| Place | Holds | Allowed contents |
| --- | --- | --- |
| Git | specs, cases, baselines, `values-ci.yaml`, `helm.env.template` | empty key names only |
| Actions secrets | live eval keys | `OPENAI_API_KEY`, `AZURE_OPENAI_API_KEY` |
| `helm.env` on the Mac | the same keys for the pod | gitignored |
| Cluster Secret | rendered from the overlay at install | namespace `agent-ops` only |

The public GitHub repo is why fixture evals must pass with zero secrets, and why live evals do not run for fork PRs.

## Remaining layout

```text
evals/baselines/
evals/scorers/             # or scorer functions inside the package
.github/workflows/eval.yml
```

`services/runtime` is the first allowlist entry: `AGENT_OPS_SERVICE_ALLOWLIST=runtime`.

## Phases

1. **Package and fake agent.** Spec loader, `hello`, turn function, pytest, fixture eval CLI. `test` workflow runs the in-process suite. No Docker, no cluster.
2. **Build under test.** Dockerfile. The `test` workflow builds the image and runs the fixture suite in it and against it. The Ubuntu loop does the same for the tag about to be deployed, then deploys, then runs that suite through port-forward. Chart templates, prefix-aligned image name, ClusterIP.
3. **Live eval.** `reply` spec, `eval` workflow, first committed baseline. Live suite runs in-process and against the CI image. Still no node port.
4. **One tool.** A single allowlisted tool and cases for allow and deny.
5. **External runtime.** Foundry (or another host) as another provider behind `turn`. Same cases.
6. **Optional self-hosted deploy.** A runner on the Mac that shells out to `./ssh-ubuntu.sh` for `agent-ops` only.

Each phase is done when its row in the testing table is green. Later phases do not block phase 1 or 2.
