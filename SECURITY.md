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
`templates/ingress/waf-config.yaml` (applied via `null_resource.harden_ingress`): ModSecurity + OWASP Core Rule Set, connection/request rate limiting (`limit-connections`, `limit-rps`), forced HTTPS redirect, and defense-in-depth response headers (`X-Frame-Options`, `X-Content-Type-Options`, HSTS). **Confirmed working**: all 9 `rke2-ingress-nginx-controller` pods came up `1/1 Running` with zero restarts and no ModSecurity-related errors in their logs after this applied — RKE2's bundled ingress-nginx image does have `libmodsecurity` compiled in.

### Kubernetes Dashboard (not managed by this Terraform, but running on the cluster it provisions)
`null_resource.install_kubernetes_dashboard` in `main.tf` installs the Kubernetes Dashboard with `kong.proxy.type=LoadBalancer` (a stable MetalLB IP) and a `cluster-admin`-bound `admin-user` ServiceAccount (`templates/security/dashboard-admin-rbac.yaml`). This is a **deliberate, accepted tradeoff**, not an oversight: the dashboard's login page is reachable from anywhere on the flat `192.168.100.0/24` LAN, gated only by generating a short-lived token by hand (`kubectl create token admin-user --duration=24h`) — no long-lived token Secret is ever stored (confirmed: no `kubernetes.io/service-account-token`-type Secret exists in the `kubernetes-dashboard` namespace as of the 2026-08-28 sweep below). Same trusted-network posture as the in-cluster registry's TLS story — real for the trust boundary it assumes (this one LAN), not a substitute for the authentication/OIDC gap noted above if this ever needs to be reachable from anywhere less trusted.

### In-cluster self-hosted CI runners (not managed by this Terraform, found during the 2026-08-28 sweep below)
Two separate self-hosted GitHub Actions runners live on this cluster, each deployed by its own downstream repo (not this one): `gh-runner` namespace (`infrawatch-observe`, private repo, `RUNNER_SCOPE=repo`) and `github-runner` namespace (`ci-runner`, deploying `vmware-dashboard`). Both were audited and hardened as part of the 2026-08-28 sweep:
- **`vmware-dashboard` was public** at the time of the sweep, with a self-hosted runner registered against it — the classic "external PR gets code execution with this pod's cluster RBAC" exposure GitHub's own docs warn against. In practice the actual workflow (`k8s-deploy.yml`) only ever triggers the self-hosted `deploy` job on `push` to `master` (never `pull_request`), so an outside contributor's PR could not directly trigger it — but a public repo with a live-registered in-cluster runner and a real GitHub PAT Secret sitting behind it is still meaningfully riskier than it needs to be for a 0-star/0-fork personal project with no reason to stay public. **Fixed: repo flipped to private** (`gh repo edit --visibility private`).
- Neither runner namespace (`gh-runner`, `github-runner`) had **any** `NetworkPolicy` — both pods were fully open ingress+egress to the entire cluster. **Fixed**: both now deny all ingress (nothing needs to reach either pod) and scope egress to DNS, the in-cluster API server (443/6443), and broad internet HTTPS/HTTP (GitHub's endpoints and `dl.k8s.io` aren't a stable, enumerable IP range).
- `gh-runner`'s image was `myoung34/github-runner:latest` (mutable tag, `imagePullPolicy: Always` — every pod restart could silently pull different code) while its sibling `ci-runner` was already correctly pinned by digest. **Fixed**: pinned to the digest that was actually running and verified working. Its `gh-runner-cluster` ClusterRole also carried an unused `ingressclasses: get/list` grant (traced to a header comment being grep-matched instead of an actual invocation) — removed. `ci-runner`'s RBAC (`vmware-dashboard`'s `k8s/runner/rbac.yaml`) was already tightly scoped (per-namespace Role plus a single-`resourceName` ClusterRole) and needed no change.
- Both runners' `ACCESS_TOKEN`/`github-runner-pat` GitHub PATs are scoped credentials (fine-grained "Administration: Read and write" for `ci-runner`; a classic `repo`-scope PAT for `gh-runner`, against what is now a private repo) — neither was rotated as part of this sweep; do that separately if either token's blast radius is a concern.

## What's NOT done (needs your decision or external action)

- **Real public CA certificates.** Nothing here is Let's Encrypt-ready until you have an actual domain name pointed at this cluster's ingress. Once you do: install cert-manager with an ACME `ClusterIssuer` (HTTP-01 or DNS-01 challenge) — a small, well-documented addition to this same install pattern, not done here because there's no domain to issue for yet.
- **DDoS / volumetric attack protection.** No Kubernetes-level tool — not this repo's WAF, not Falco, nothing — can absorb a real volumetric DDoS against a single-homed cluster on a home/lab network. That requires an upstream provider (Cloudflare, AWS Shield, a colo's DDoS scrubbing service) sitting in front of this cluster's public IP. Be honest with yourself about whether this environment's network (a Synology-backed lab on a single flat `/24`, per CLAUDE.md) is where you want to find that out the hard way.
- **Alerting/SIEM pipeline.** Falco supports `falcosidekick` for routing detections to Slack, PagerDuty, a SIEM, etc. — not deployed here because it needs you to pick a destination. Trivy-Operator's reports need either a dashboard (its own optional `trivy-operator-polaris`/Starboard-style UI) or a scheduled review process. Neither tool is doing its job until one of these exists.
- **Secrets management beyond etcd encryption.** Registry/vCenter credentials are still rendered by Terraform and pushed as files — better than before this pass (see CLAUDE.md), but a real upgrade path is [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) (open source, GitOps-safe encrypted secrets) or Vault, neither of which is wired in here.
- **`NOPASSWD` sudo and `vsphere_allow_unverified_ssl`** — both still accepted-risk items with documented compensating controls in CLAUDE.md; unchanged by this pass because fixing either one for real requires an operational tradeoff (removing unattended provisioning capability, or getting vCenter a CA-trusted cert) that's outside what code alone can decide.
- **A penetration test / external security review.** Everything above is defense built from a threat model I constructed; it hasn't been validated by anyone trying to break it. Do that before trusting this with real user data.

## Rolling out Kyverno enforcement

All four baseline policies ship in `validationFailureAction: Audit` deliberately — this cluster has real running workloads (`observe-dev`'s Loki/Mimir/Tempo/Postgres/Grafana stack, the registry, MinIO) whose current compliance with these rules is unknown. Flipping straight to `Enforce` could block their next legitimate deployment without warning.

**As of the 2026-08-28 sweep, that compliance gap is large and confirmed, not hypothetical**: `kubectl get policyreport,clusterpolicyreport -A` showed **182 failing results** for `require-resource-limits`/`require-run-as-non-root` alone, spread across nearly every namespace — `cert-manager`, `kyverno` itself, `trivy-system`, `cnpg-system`, `registry`, `infrawatch`, `observe-dev`, `kubernetes-dashboard`, both CI runner namespaces. All audit-only, so nothing is currently blocked, but `Enforce` is not close to safe to flip cluster-wide today. One concrete instance was fixed this pass (the `observe-dev` CNPG `postgres` Cluster was missing a CPU limit — see its own repo's history), as was `gh-runner`'s missing CPU limit — but the other ~180 are still open and mostly belong to third-party/vendor charts this repo doesn't control the manifests for.

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
