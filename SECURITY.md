# Security posture

This document is the honest account of this cluster's security posture: what's implemented, what it actually protects against, what it doesn't, and what's required before this cluster should ever be exposed to the public internet. It's written to be read start to finish before making that decision, not skimmed for reassurance.

**No system connected to the public internet is unhackable.** Nothing in this document claims otherwise. What's here is real, layered defense-in-depth — prevention where possible, detection where prevention isn't absolute — cross-referenced against [CISA/NSA's Kubernetes Hardening Guidance](https://www.cisa.gov/resources-tools/resources/kubernetes-hardening-guidance) and NIST 800-53 control families.

## ⚠️ Before you consider public exposure at all

1. **This cluster currently has an active, unresolved incident** — see the top of [CLAUDE.md](CLAUDE.md). Intermittent connectivity failures between the cluster and vCenter, unconfirmed root cause, storage corruption history. Putting this cluster on the public internet before that's closed adds real availability risk independent of anything below. Don't.
2. **Nobody is watching the detection tooling yet.** Falco and Trivy-Operator are both installed and running, but by default their output goes nowhere anyone will see it (Falco logs to its own pod's stdout; Trivy-Operator writes `VulnerabilityReport`/`ConfigAuditReport` custom resources that nothing alerts on). Detection tooling nobody reviews is not detection — it's a false sense of security. Wire at least one of these to somewhere a human or on-call system actually looks (see "What's not done" below) before relying on them.
3. **Kyverno's policies are in Audit mode, not Enforce.** They're currently visibility-only — see "Rolling out enforcement" below.

## What's implemented

### Transport security
- **In-cluster registry now serves TLS**, not plaintext HTTP. Certificate chain is a locally-generated internal CA (`tls.tf`) — the CA's public cert is distributed to every node so `containerd` trusts it; the CA's private key never leaves Terraform state. This secures node↔registry traffic specifically. **It is not a substitute for a publicly-trusted certificate** for anything actually reachable from outside this network — use cert-manager with an ACME (Let's Encrypt) issuer for that once there's a real domain name, since every browser/client already trusts Let's Encrypt without needing this internal CA distributed to them.
- **etcd secrets-encryption-at-rest** (`secrets-encryption: true`) — Kubernetes `Secret` objects are encrypted (AES-CBC) before landing in etcd.
- **Ingress TLS enforced** (`ssl-redirect: true`) with HSTS, once a real certificate is wired up for it.

### Admission control & policy (Kyverno)
Four baseline policies mapped to Kubernetes Pod Security Standards, all currently in **Audit** mode (see rollout section):
- `disallow-privileged-containers` — blocks `privileged: true` outside `kube-system`/`vmware-system-csi`/`metallb-system` (those namespaces run kube-vip, the CNI, MetalLB's speaker, and the CSI node plugin — all of which legitimately need it).
- `require-run-as-non-root` — same exemption scope.
- `disallow-latest-tag` — every container image must specify an explicit, non-`latest` tag, cluster-wide, no exemptions.
- `require-resource-limits` — every container must declare CPU/memory limits, so a single runaway workload can't starve the node it's on.

### Vulnerability scanning (Trivy-Operator)
Continuously scans running workloads' images and cluster config, writing `VulnerabilityReport` and `ConfigAuditReport` CRs. **Nothing currently consumes these automatically** — see "What's not done."

### Runtime threat detection (Falco)
Syscall-level detection via the modern eBPF driver (no kernel module build required on this template's 5.15+ kernel). Catches things admission control and image scanning can't: a shell spawned inside a container post-compromise, unexpected outbound connections, writes to sensitive host paths. **Output currently goes to the Falco pods' own logs only** — see "What's not done."

### Network segmentation
- The `registry` namespace has a deny-all-egress `NetworkPolicy` (ingress is deliberately left open — see the comment in `templates/registry/registry.yaml.tpl` for why a podSelector-based ingress restriction isn't safe to apply to NodePort-sourced traffic without real traffic analysis first).
- **Deliberately not applied to `kube-system`, `vmware-system-csi`, or `metallb-system`.** These namespaces have complex, interdependent east-west traffic (DNS, CNI, kube-proxy, the CSI control loop) that this pass didn't have live traffic data to safely map. Hand-rolling a default-deny policy here from documentation alone risks silently breaking core cluster function — including NetworkPolicy enforcement itself, since that depends on the CNI working. If you want this hardened, start with `Audit`-equivalent visibility (e.g. Cilium's Hubble, or a temporary permissive log-only policy) before writing any `Enforce`/deny rule for these namespaces.
- Each tenant namespace (see below) gets default-deny + intra-tenant-allow + DNS-allow out of the box, following the same pattern already proven in this cluster's `observe-dev` app namespace (see CLAUDE.md's `minio-init` NetworkPolicy incident for the concrete lesson that motivated this).

### Multi-tenancy (`var.tenants` in `tenants.tf`)
Logical isolation by default (namespace + RBAC + ResourceQuota + LimitRange + NetworkPolicy) — the same model most production multi-tenant Kubernetes platforms (GKE, EKS) actually use. Each tenant's `tenant-admin` Role deliberately **excludes** edit/delete on `ResourceQuota`, `LimitRange`, `NetworkPolicy`, `Role`, and `RoleBinding` in their own namespace — a tenant admin can run anything inside their namespace, but cannot loosen the isolation boundary around it or escalate their own privileges.

**Physical isolation is opt-in per tenant** via `dedicated_node_names`: naming specific existing worker nodes taints/labels them for that tenant alone, and a generated Kyverno *mutation* policy auto-injects the matching `nodeSelector`/toleration into every pod created in that tenant's namespace — enforced automatically, not just documented as a convention the tenant admin has to remember. This repurposes existing worker capacity; it does not provision new dedicated VMs.

`var.tenants` defaults to `{}` — none of this changes the live cluster's behavior until a tenant is actually declared.

### Authentication hook (not a deployed identity provider)
`var.oidc_issuer_url`/`oidc_client_id`/`oidc_username_claim`/`oidc_groups_claim` wire the API server to authenticate real users via OIDC. **This repo does not deploy an identity provider for you** — point it at an existing corporate IdP (Okta/Azure AD/Google Workspace all speak OIDC directly), or stand up [Dex](https://github.com/dexidp/dex) (CNCF, open source, pluggable backends including LDAP/GitHub/SAML/static users) if you want something self-contained. Without this, `var.tenants`' `admin_subjects` are RBAC *authorization* rules with no real *authentication* behind them — anyone with the shared cluster-admin kubeconfig bypasses all of it, same as before this pass.

### CI/CD & supply chain
- `tfsec` runs on every push/PR, zero findings as of this pass.
- GitHub Actions workflow scoped to `permissions: contents: read` (least privilege, no implicit write access to the repo).
- Every credential-bearing file this repo's provisioners push to a node is now `chmod 600` on arrival and removed after use — see CLAUDE.md's Security & compliance section for the full list of what changed there.

### Ingress hardening
`templates/ingress/waf-config.yaml` (applied via `null_resource.harden_ingress`): ModSecurity + OWASP Core Rule Set, connection/request rate limiting (`limit-connections`, `limit-rps`), forced HTTPS redirect, and defense-in-depth response headers (`X-Frame-Options`, `X-Content-Type-Options`, HSTS). **Not yet confirmed**: whether RKE2's specific ingress-nginx image build has `libmodsecurity` compiled in — check the controller pod's logs after this applies for a ModSecurity startup error before assuming it's active.

## What's NOT done (needs your decision or external action)

- **Real public CA certificates.** Nothing here is Let's Encrypt-ready until you have an actual domain name pointed at this cluster's ingress. Once you do: install cert-manager with an ACME `ClusterIssuer` (HTTP-01 or DNS-01 challenge) — a small, well-documented addition to this same install pattern, not done here because there's no domain to issue for yet.
- **DDoS / volumetric attack protection.** No Kubernetes-level tool — not this repo's WAF, not Falco, nothing — can absorb a real volumetric DDoS against a single-homed cluster on a home/lab network. That requires an upstream provider (Cloudflare, AWS Shield, a colo's DDoS scrubbing service) sitting in front of this cluster's public IP. Be honest with yourself about whether this environment's network (a Synology-backed lab on a single flat `/24`, per CLAUDE.md) is where you want to find that out the hard way.
- **Alerting/SIEM pipeline.** Falco supports `falcosidekick` for routing detections to Slack, PagerDuty, a SIEM, etc. — not deployed here because it needs you to pick a destination. Trivy-Operator's reports need either a dashboard (its own optional `trivy-operator-polaris`/Starboard-style UI) or a scheduled review process. Neither tool is doing its job until one of these exists.
- **Secrets management beyond etcd encryption.** Registry/vCenter credentials are still rendered by Terraform and pushed as files — better than before this pass (see CLAUDE.md), but a real upgrade path is [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) (open source, GitOps-safe encrypted secrets) or Vault, neither of which is wired in here.
- **`NOPASSWD` sudo and `vsphere_allow_unverified_ssl`** — both still accepted-risk items with documented compensating controls in CLAUDE.md; unchanged by this pass because fixing either one for real requires an operational tradeoff (removing unattended provisioning capability, or getting vCenter a CA-trusted cert) that's outside what code alone can decide.
- **A penetration test / external security review.** Everything above is defense built from a threat model I constructed; it hasn't been validated by anyone trying to break it. Do that before trusting this with real user data.

## Rolling out Kyverno enforcement

All four baseline policies ship in `validationFailureAction: Audit` deliberately — this cluster has real running workloads (`observe-dev`'s Loki/Mimir/Tempo/Postgres/Grafana stack, the registry, MinIO) whose current compliance with these rules is unknown. Flipping straight to `Enforce` could block their next legitimate deployment without warning.

To roll out enforcement safely:
1. `kubectl get policyreport -A` / `kubectl get clusterpolicyreport` — review what's currently non-compliant and why.
2. Fix or explicitly exempt (via a `PolicyException`, not by weakening the rule) anything that's a real violation.
3. Edit the specific policy's `validationFailureAction` to `Enforce` in `templates/security/kyverno-baseline-policies.yaml`, one policy at a time, re-applying and watching for a period before moving to the next.

## What this cluster's current threat model covers, in plain terms

| Threat | Covered by | Confidence |
|---|---|---|
| Plaintext credentials on disk/in etcd | Secrets-encryption, file perm fixes, registry TLS | High |
| A compromised pod pivoting laterally | NetworkPolicy (partial — see scope note above), tenant isolation | Medium — real gaps in `kube-system` remain |
| A malicious/misconfigured workload being scheduled | Kyverno (once enforced) | Low until Enforce mode |
| A known-CVE image being deployed | Trivy-Operator | Medium — scans, but nothing pages anyone yet |
| An attacker who already has a shell in a container | Falco | Medium — detects, but nothing pages anyone yet |
| A user impersonating another tenant | Multi-tenant RBAC + NetworkPolicy | High, logical isolation; only as strong as authentication, which isn't deployed yet |
| Volumetric DDoS | Nothing in this repo | None — needs an edge provider |
| A zero-day in RKE2/Kubernetes itself | Nothing specific | None — stay current on `rke2_version` |
