---
authors:
  - "@TBD"
state: draft
links:
  - (originating GitHub issue pending)
---

# RFC NNNN - Standalone Supervisor Mode

## Summary

Add a `--standalone` flag to the OpenShell supervisor that validates static, gateway-free configuration at startup and provides clear error messages for incompatible flag combinations. This formalizes the supervisor's existing ability to run without a gateway into an explicit, documented operating mode for air-gapped, embedded, and compliance-driven environments.

The supervisor already degrades gracefully when `--sandbox-id` and `--openshell-endpoint` are omitted — gateway-dependent features (aggregators, polling, SSH relay, log push) are skipped via `Option`-gated code paths. Standalone mode wraps this implicit behavior in an explicit contract: validated upfront, documented with examples, and surfaced as a first-class deployment topology alongside the existing gateway-integrated mode.

## Motivation

The supervisor's file-based policy support (`--policy-rules`, `--policy-data`) enables gateway-free operation today, but the experience is poor:

1. **Discovery problem.** No documentation, flag, or error message tells users that gatewayless operation is possible. Users attempting air-gapped deployments either assume it cannot work or discover the right flag combination through trial and error.

2. **Silent misconfiguration.** Setting `--openshell-endpoint` alongside `--policy-rules` causes the supervisor to attempt gateway connections that will never succeed, filling logs with retry warnings while still enforcing local policy. Nothing prevents this at startup.

3. **Missing deployment guidance.** Automotive QM, edge, and compliance-driven environments need prescriptive deployment patterns (systemd units, Podman quadlets, secret injection) that are absent from the documentation.

4. **Unclear operational contract.** Operators cannot easily answer: "What features does my supervisor actually run?" The implicit `Option`-gating is an implementation detail, not an operational contract.

Adding `--standalone` costs roughly 50-100 lines of validation code and a documentation effort. The runtime enforcement stack (proxy, OPA, Landlock, seccomp, OCSF logging) requires zero changes — it already works without a gateway.

## Non-goals

- **Runtime behavior changes to the enforcement stack.** Standalone mode does not alter proxy, OPA, Landlock, seccomp, or OCSF logging — these already function without a gateway.
- **Dynamic policy updates in standalone mode.** Static, boot-time configuration is the design goal.
- **Alternative telemetry backends.** Standalone writes local OCSF log files; platform log forwarding (journald, Fluentd) handles aggregation.
- **A separate standalone binary.** This is a runtime flag, not a build variant.
- **A systemd service generator.** Users write their own quadlet/unit files. Example files are provided.
- **Agent-driven policy proposals.** RFC 0002's policy advisor workflow is incompatible with standalone mode by design (no gateway to mediate proposals).
- **Replacing gateway-integrated deployments.** Cloud and Kubernetes deployments continue using full gateway integration.

## Proposal

### The `--standalone` flag

Add a top-level boolean flag to the supervisor's clap `Args` struct:

```rust
/// Run without a gateway. Requires --policy-rules and --policy-data for
/// static policy. Disables SSH relay, aggregators, polling, and log push.
#[arg(long)]
standalone: bool,
```

The flag's only runtime effect is startup validation. It does not introduce new conditional branches in `lib.rs` or `run.rs` — the existing `Option`-gated code paths already handle the absence of `sandbox_id` and `openshell_endpoint`.

### Startup validation

When `--standalone` is set, validate before calling `run_sandbox()`:

| Condition | Error message |
|-----------|---------------|
| `--openshell-endpoint` is set | `--standalone cannot be used with --openshell-endpoint` |
| `--sandbox-id` is set | `--standalone cannot be used with --sandbox-id` |
| `--policy-rules` is missing | `--standalone requires --policy-rules for static policy` |
| `--policy-data` is missing | `--standalone requires --policy-data for static policy` |
| Policy files don't exist | `--policy-rules path does not exist: {path}` |
| Policy files fail parse | `--policy-data failed to parse: {err}` |

When validation passes, `run_sandbox()` is called with `sandbox_id: None` and `openshell_endpoint: None`, which activates the existing gatewayless code paths:

- **Provider credentials** (`lib.rs:227`): `if let (Some(id), Some(endpoint))` — skipped, returns empty maps.
- **Denial channel** (`lib.rs:331`): `if sandbox_id.is_some()` — skipped, returns `(None, None, None)`.
- **Activity channel** (`lib.rs:345`): `if sandbox_id.is_some()` — skipped, returns `(None, None, None)`.
- **Denial aggregator** (`lib.rs:463`): `if let (Some(rx), Some(endpoint))` — skipped, no flush task.
- **Activity aggregator** (`lib.rs:498`): `if let (Some(rx), Some(endpoint))` — skipped, no flush task.
- **Policy poll loop** (`lib.rs:530`): `if let (Some(id), Some(endpoint), Some(engine))` — skipped, no polling.
- **Log push layer** (`main.rs:494`): `if let (Some(sandbox_id), Some(endpoint))` — skipped, no gRPC log push.
- **SSH server** (`run.rs:222`): `if let Some(listen_path) = ssh_socket_path` — skipped when `--ssh-socket-path` is not provided (independent of `--standalone`, but documented as part of the standalone topology).
- **Supervisor session** (`run.rs:298`): `if let (Some(endpoint), Some(id), Some(socket))` — skipped, no relay.

The enforcement stack runs unchanged: proxy binds, OPA evaluates policy, Landlock restricts filesystem, seccomp filters syscalls, OCSF events write to local rolling log files.

### OCSF logging

No changes required. The OCSF logging stack is already local-first:

- `OcsfShorthandLayer` writes to stderr and a rolling file at `/var/log/openshell.*.log`.
- `OcsfJsonlLayer` writes structured events to `/var/log/openshell-ocsf.*.log` (daily rotation, 3 files max, gated by the `ocsf_json_enabled` setting flag).
- `LogPushLayer` (gateway gRPC push) is already conditional on `sandbox_id` + `openshell_endpoint` — it is `None` in standalone mode.

Operators use platform-native log forwarding (journald, bind-mounted volumes, Fluentd) to aggregate OCSF logs from standalone sandboxes.

### Inference routes

The `--inference-routes` flag (`main.rs:166`) already supports loading routes from a local YAML file. In standalone mode, inference routing works if `--inference-routes` is provided; otherwise `inference.local` traffic is denied by default. No changes needed.

### Features comparison

| Feature | Gateway mode | Standalone mode |
|---------|-------------|-----------------|
| Supervisor session (gRPC relay) | Active | Skipped (no endpoint) |
| SSH server | Active (if `--ssh-socket-path` set) | Typically skipped |
| Denial aggregator | Active (flushes to gateway) | Skipped (no sandbox_id) |
| Activity aggregator | Active (flushes to gateway) | Skipped (no sandbox_id) |
| Policy poll loop | Active (polls every 10s) | Skipped (no sandbox_id) |
| Log push (gRPC) | Active | Skipped (no endpoint) |
| Provider credentials (gRPC fetch) | Active | Skipped (env vars only) |
| Policy hot-reload | Supported | Not available (static) |
| Policy proposals (RFC 0002) | Supported | Not available |
| **Network enforcement (proxy + OPA)** | Active | **Active** |
| **Filesystem isolation (Landlock)** | Active | **Active** |
| **Process restrictions (seccomp)** | Active | **Active** |
| **OCSF logging (local files)** | Active | **Active** |

### systemd / Podman Quadlet deployment

Standalone sandboxes integrate naturally with systemd-managed container deployments. A Podman quadlet is a declarative `.container` file that `systemd-generator` converts to a standard `.service` unit at boot.

**Podman quadlet example** (`/etc/containers/systemd/openshell-agent.container`):

```ini
[Unit]
Description=OpenShell Standalone Agent Sandbox
After=network-online.target
Wants=network-online.target

[Container]
Image=quay.io/openshell/custom-sandbox:latest
Exec=--standalone \
  --policy-rules=/etc/openshell/policy.rego \
  --policy-data=/etc/openshell/policy-data.yaml \
  --sandbox=agent-1 \
  /usr/local/bin/agent-entrypoint
Volume=/etc/openshell:/etc/openshell:ro,z
Volume=/var/lib/agent:/workspace:rw,z
Volume=/var/log/openshell:/var/log:rw,z
Environment=ANTHROPIC_API_KEY_FILE=/run/secrets/anthropic-key
SecurityLabelType=container_runtime_t
AddCapability=NET_ADMIN

[Service]
Restart=on-failure
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

**Docker systemd unit** (for environments without Podman):

```ini
[Unit]
Description=OpenShell Standalone Agent
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker stop openshell-agent-1
ExecStartPre=-/usr/bin/docker rm openshell-agent-1
ExecStart=/usr/bin/docker run --rm --name openshell-agent-1 \
  --cap-add=NET_ADMIN \
  -v /etc/openshell:/etc/openshell:ro \
  -v /var/lib/agent:/workspace:rw \
  -v /var/log/openshell:/var/log:rw \
  -e ANTHROPIC_API_KEY_FILE=/run/secrets/anthropic-key \
  quay.io/openshell/custom-sandbox:latest \
  --standalone \
  --policy-rules=/etc/openshell/policy.rego \
  --policy-data=/etc/openshell/policy-data.yaml \
  --sandbox=agent-1 \
  /usr/local/bin/agent-entrypoint
ExecStop=/usr/bin/docker stop openshell-agent-1
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Key benefits of systemd integration:

- **Auditable** — unit files are version-controlled and immutable at runtime.
- **Platform-native** — standard `systemctl` commands; no custom orchestrator.
- **Resource enforcement** — systemd cgroups (`MemoryMax=`, `CPUQuota=`, `TasksMax=`).
- **Boot-time activation** — `WantedBy=multi-user.target` starts sandboxes automatically.
- **Secret injection** — `LoadCredential=` or bind-mounted `/run/secrets/`.

### Resource footprint

Standalone mode eliminates all background tasks except the proxy. Expected reductions (to be validated during implementation):

| Metric | Gateway mode | Standalone mode |
|--------|-------------|-----------------|
| Background tasks | 5-7 (aggregators, poll, log push, SSH) | 1 (proxy) |
| Outbound connections | 1-2 (gateway gRPC) | 0 |
| Log volume | High (denials + activity + telemetry push) | Low (enforcement events only) |

Memory reduction depends on the absence of gRPC client state, aggregator buffers, and SSH server — expected to be modest (tens of MB) but should be profiled.

## Implementation plan

The implementation is a single phase: flag validation in `main.rs`, documentation, and example configs. The enforcement stack requires no changes.

### Phase 1: Flag and validation (~1 day)

**`crates/openshell-sandbox/src/main.rs`:**

1. Add `standalone: bool` field to the `Args` struct.
2. Add a validation block after argument parsing, before `run_sandbox()`:
   - Reject `--standalone` combined with `--openshell-endpoint` or `--sandbox-id`.
   - Require `--policy-rules` and `--policy-data` when `--standalone` is set.
   - Validate that policy files exist and parse successfully.
   - Emit an `AppLifecycleBuilder` OCSF event on standalone startup.

No other source files require modification.

**Tests:**

- Unit test: validation rejects conflicting flags.
- Unit test: validation requires policy files.
- Integration test: standalone supervisor starts, enforces policy, writes OCSF logs, exits cleanly on SIGTERM.

### Phase 2: Documentation and examples (~1-2 days)

1. Add a standalone deployment guide to `docs/` covering the use case, flag usage, and systemd integration.
2. Update `architecture/sandbox.md` to describe standalone mode as a supported topology.
3. Create example files in `examples/standalone/`:
   - Podman quadlet (`.container` file)
   - Docker systemd unit (`.service` file)
   - Minimal policy files (`.rego` + `.yaml`)
4. Update `docs/reference/gateway-config.mdx` to mention standalone as an alternative when no gateway is needed.

### Phase 3: Validation and hardening (~1-2 days)

1. Profile memory and startup time with and without `--standalone` to validate resource claims.
2. Test in a simulated air-gapped environment (no outbound connectivity).
3. Verify OCSF log files are written correctly without the log push layer.

## Risks

### Dual-mode testing surface

**Risk:** Maintaining two documented topologies (gateway-integrated and standalone) increases the testing matrix.

**Mitigation:** The enforcement stack is identical in both modes — only the management plane differs. Standalone-specific tests cover flag validation and the absence of gateway connections, not the enforcement paths. The `Option`-gated code paths that make standalone work are already exercised by existing unit tests (which run without a gateway).

**Residual risk:** Low. The validation logic is straightforward; the enforcement stack is unchanged.

### Credential management in air-gapped environments

**Risk:** Standalone mode relies on environment variables or platform-native secret injection for credentials, which may be less convenient than gateway-mediated credential resolution.

**Mitigation:** Document recommended patterns: systemd `LoadCredential=`, Podman secret mounts, bind-mounted `/run/secrets/`. Warn against hardcoded credentials in policy files.

**Residual risk:** Medium. This is an inherent trade-off for air-gapped environments, not a design flaw.

### Users expecting more than validation

**Risk:** Users may expect `--standalone` to enable new runtime capabilities (hot-reload, local dashboards, etc.) beyond what it actually provides.

**Mitigation:** Documentation clearly states that `--standalone` is a validation and deployment convenience, not a new runtime mode. Non-goals are explicit.

**Residual risk:** Low.

## Alternatives

### Do nothing — document existing flag combinations

Users can already achieve standalone operation by providing `--policy-rules` and `--policy-data` without `--sandbox-id` or `--openshell-endpoint`. Document this as the standalone deployment pattern.

**Why not:** The implicit behavior is fragile — nothing prevents users from accidentally setting `--openshell-endpoint` (e.g., from a leftover environment variable), causing silent gateway connection attempts. An explicit `--standalone` flag with mutual-exclusion validation catches this at startup. The flag also serves as a documentation anchor and a searchable term for users discovering the capability.

### Embedded lightweight gateway

Run a minimal local gateway alongside the supervisor to preserve the gateway-integrated code path.

**Why not:** Defeats the purpose of air-gapped, resource-constrained deployments. Adds binary size, process complexity, and a component that provides no value when policy is static.

### Separate standalone binary

Build a stripped-down binary without gateway client dependencies.

**Why not:** Doubles the build and release matrix for a ~50-line validation difference. A runtime flag is simpler to maintain, test, and document.

### Policy-only mode without supervisor

Provide the network policy enforcement stack without the full supervisor (no process isolation, no seccomp).

**Why not:** Loses filesystem isolation, process restrictions, and seccomp filtering. Not a complete security boundary.

## Prior art

- **containerd / CRI-O standalone modes** — container runtimes that operate with static config and no control plane, validating configuration at startup rather than fetching it dynamically.
- **OPA standalone evaluation** — the OPA engine loads policy from files without requiring a server, which is exactly how the supervisor's OPA integration already works via `--policy-rules`.
- **Istio sidecar static bootstrap** — Envoy can load xDS configuration from files instead of connecting to Pilot, similar to how standalone mode uses file-based policy instead of gateway-fetched policy.
- **Podman quadlets** — declarative container-as-service model for systemd, providing the deployment pattern this RFC recommends for standalone sandboxes.

## Open questions

### Should standalone mode support policy hot-reload from filesystem?

**Recommendation:** No. Start with immutable, boot-time policy. If demand emerges, a `--watch-policy` flag can be added as a separate feature without changing the standalone contract. Hot-reload introduces complexity (atomic swap, validation-on-reload, error recovery) that conflicts with the deterministic-behavior goal.

### Should standalone mode support `Type=notify` for systemd readiness signaling?

**Recommendation:** Defer. Initial implementation uses `Type=simple` (systemd considers the service ready when `ExecStart` runs). If operators need precise readiness gating, adding `sd_notify(3)` after policy load and proxy bind is straightforward but should be driven by concrete demand.

### Should `--standalone` imply `--ssh-socket-path` is not set?

**Recommendation:** No. The SSH server is independently gated on `--ssh-socket-path` and has no gateway dependency — it generates its own host key and listens on a Unix socket. An operator running standalone mode might still want local SSH access (e.g., `nsenter` + socket connect for debugging). Let the existing `Option` gating handle this orthogonally.
