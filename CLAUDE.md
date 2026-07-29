# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Terraform that provisions a highly-available RKE2 (Rancher Kubernetes Engine 2) cluster on VMware vSphere: 3 control-plane nodes fronted by a `kube-vip` (ARP mode) virtual IP, plus N worker nodes. VMs are cloned from a pre-built cloud-init-enabled template and configured entirely through cloud-init (via the VMware GuestInfo datasource) — no vSphere guest customization specs are used.

## ⚠️ Known active issue: datastore-level storage corruption

A sweep of all 6 worker nodes' kernel logs (`sudo dmesg | grep -c 'aborted journal'`) found ext4 journal-abort events in the **hundreds to 1000+** on 5 of 6 nodes, affecting multiple unrelated PVC-backed workloads (the in-cluster registry, Loki replicas) on multiple different nodes at different times — including at least once with no VM reboot involved at all. That scale means this is an ongoing, active condition on the `LAB-LUN01` datastore (or its path to the ESXi hosts), not something any single Terraform operation caused, though VM-level reboots do appear to trigger *visible* symptoms by disrupting volumes that were already degrading underneath.

**Do not try to fix this by recreating individual PVCs** — that treats a symptom, not the cause, and was already tried twice on the registry's volume with the corruption recurring both times. This needs vSphere/storage-team investigation: datastore health, ESXi host storage-adapter logs, multipathing status. Until it's resolved, treat any CSI-backed workload's data as at-risk, and be extra cautious about node reboots on workers running stateful (non-replicated, or replicated-but-you-haven't-checked) workloads.

## Commands

```bash
terraform init
terraform fmt -recursive      # format all .tf files before committing
terraform validate
terraform plan
terraform apply
```

There is no test suite, linter config, or CI pipeline in this repo. `terraform validate` is the correctness check; `terraform plan` against real vCenter credentials is the only way to catch data-source lookup errors (bad datacenter/cluster/datastore/network/template names).

Before `apply`, copy `terraform.tfvars.example` to `terraform.tfvars` and fill in real values. vCenter credentials are **not** set via `terraform.tfvars` — export them instead, since the provider (`providers.tf`) reads them from the environment by default:

```bash
export VSPHERE_USER=administrator@vsphere.local
export VSPHERE_PASSWORD=...
export VSPHERE_SERVER=vcenter.example.com
```

After a successful apply, `terraform output kubeconfig_fetch_command` prints the command to pull a working kubeconfig off the primary control-plane node.

## Architecture

**Bootstrap ordering is the crux of this repo.** RKE2 HA requires the VIP to be live before the second and third control-plane nodes (and any workers) can join, and VM creation completing in vSphere does *not* mean cloud-init/RKE2 has finished inside the guest. [main.tf](main.tf) enforces the real ordering explicitly:

1. `module.control_plane_primary` — the only node created with `cluster-init` semantics (`is_primary = true` in its cloud-init render). It also ships the `kube-vip` DaemonSet manifest into `/var/lib/rancher/rke2/server/manifests/`, which RKE2 auto-applies once its own apiserver is up. Because `kube-vip` becomes a cluster-wide DaemonSet object, it only needs to be placed on this one node — RKE2 schedules it to all control-plane nodes once they join.
2. `null_resource.wait_for_primary` — SSHes into the primary node and blocks on `cloud-init status --wait`, then `rke2-server` being active, then the VIP itself answering `/readyz`. This is the synchronization point between "VM exists" and "cluster is actually joinable."
3. `module.control_plane_secondary` (for_each over indices `"1"`, `"2"`) and `module.workers` (for_each over worker indices) both `depends_on = [null_resource.wait_for_primary]` and join via `server: https://${control_plane_vip}:9345`.

Node identity (hostname, static IP, RKE2 role) is driven by list index, not by any dynamic discovery: `var.control_plane_ip_addresses` and `var.worker_ip_addresses` are positional, matched up with `local.control_plane_names` / `local.worker_names` in [locals.tf](locals.tf). Changing cluster size means resizing these lists (worker count) or is unsupported by design (control-plane count is hardcoded to 3 — see the `validation` block on `control_plane_ip_addresses` in [variables.tf](variables.tf)).

**modules/vm** ([modules/vm/main.tf](modules/vm/main.tf)) is a thin, role-agnostic wrapper around `vsphere_virtual_machine` clone: it takes already-rendered `userdata`/`metadata` strings, base64-encodes them, and injects them via `extra_config["guestinfo.userdata"]` / `["guestinfo.metadata"]`. All three call sites in [main.tf](main.tf) (primary, secondary control-plane, workers) render cloud-init from the same two template families but with different variables — that's the only thing that differs between a control-plane and worker node at the Terraform level.

**Cloud-init templates** (`templates/cloud-init/*.tpl`) are plain `templatefile()` inputs, not Terraform-aware — Terraform interpolation happens once at render time in main.tf, and the `%{ if is_primary ~}` conditional in [control-plane-userdata.yaml.tpl](templates/cloud-init/control-plane-userdata.yaml.tpl) is what differentiates the primary node (gets the kube-vip manifest, omits `server:`) from secondary control-plane nodes (gets `server: https://<vip>:9345`, no kube-vip manifest). The kube-vip DaemonSet manifest itself ([templates/manifests/kube-vip.yaml.tpl](templates/manifests/kube-vip.yaml.tpl)) is rendered separately in [locals.tf](locals.tf) and passed into the control-plane template pre-base64-encoded, embedded via cloud-init's `encoding: b64` file directive — this sidesteps YAML-in-YAML indentation problems rather than trying to inline a multi-doc Kubernetes manifest inside a cloud-config `write_files` block.

**Cluster join secret** is a pre-shared `var.rke2_token` (generate with `openssl rand -hex 32`), not RKE2's auto-generated token — this avoids needing a remote-exec round trip to read the token off the primary node before other nodes can be configured, at the cost of the operator having to pick and distribute the token themselves.

## Prerequisites

Before the first `terraform apply` against a new vCenter, gather:

- **The template itself**: `var.template_name` must reference an existing vSphere VM template with cloud-init installed and the **VMware GuestInfo datasource** enabled (default on stock Ubuntu 22.04+ cloud images). This repo does not build that template — it assumes one already exists. If asked to build one, that's a separate concern (e.g. Packer), not something wired into this Terraform. The template's own virtual hardware version and vApp property state don't need to be fixed up by hand first — `modules/vm` explicitly sets `hardware_version = 20` and blanks the `vapp.properties` map on every clone regardless of what the template shipped with (see "Storage" and "Known rough edges" below) — but if a *different* template defines vApp property keys other than `password`/`public-keys`, that `vapp` block in [modules/vm/main.tf](modules/vm/main.tf) needs updating to list them, or they'll silently keep whatever the template baked in.
- **The real network subnet** for `var.vsphere_network` — see the "Don't trust a portgroup name" rough edge below. Don't fill in `control_plane_ip_addresses`/`worker_ip_addresses`/`control_plane_vip`/`network_gateway` from guesswork or the `terraform.tfvars.example` placeholders.
- **The datastore's `ds:///vmfs/volumes/<uuid>/` URL** for `var.vsphere_datastore_url` (used by the CSI StorageClass) — not exposed by the `vsphere_datastore` data source; look it up via the datastore's `summary.url` property (pyvmomi/govc against the same vCenter).
- **vCenter credentials in two places**: `VSPHERE_USER`/`VSPHERE_PASSWORD`/`VSPHERE_SERVER` as env vars for the provider itself, *and* `vsphere_user`/`vsphere_password`/`vsphere_server` in `terraform.tfvars` (same values) for the in-cluster vSphere CSI secret, which Terraform variables can't populate from the provider's own env-var fallback.
- **ESXi host hardware-version support** — confirm your hosts actually support the `hardware_version` value in `modules/vm/main.tf` (query `host.config.product` via pyvmomi/govc); vCenter's own version doesn't guarantee every host it manages supports the same range.

## Storage

RKE2 ships no default StorageClass or CSI provisioner. `null_resource.install_vsphere_csi` in [main.tf](main.tf) installs the [vSphere CSI driver](https://github.com/kubernetes-sigs/vsphere-csi-driver) after the full cluster is up: it SSHes to the primary control-plane node, applies the upstream namespace/RBAC/controller/node manifests plus a rendered `vsphere-config-secret` ([templates/csi/vsphere-config-secret.yaml.tpl](templates/csi/vsphere-config-secret.yaml.tpl), keyed off `var.vsphere_user`/`vsphere_password`/`vsphere_server` — hence those being duplicated into `terraform.tfvars` alongside the `VSPHERE_*` env vars the provider itself uses), then a `vsphere-csi` StorageClass targeting `var.vsphere_datastore_url` ([templates/csi/storageclass.yaml.tpl](templates/csi/storageclass.yaml.tpl)). It also demotes RKE2's bundled `local-path` StorageClass's default annotation, since two StorageClasses both marked default is ambiguous.

Two `modules/vm` settings exist specifically for CSI to work, both worth knowing if you ever change the source template:
- `enable_disk_uuid = true` — without it, the CSI node plugin can't reliably match a PV's backing VMDK to the node it's attached to.
- `hardware_version = 20` — vSphere CSI's disk-attach (CNS) operation requires virtual hardware **vmx-13 or newer**. If the template is stuck on an old hardware version (vmx-10 is what shipped here, from the vSphere 5.5 era), attaches fail with `DeviceUnsupportedForVmVersion` and a PVC-bound pod hangs in `ContainerCreating` indefinitely with no obvious error short of digging into the CSI controller's `csi-attacher` container logs. Pick a value your actual ESXi hosts support (`8.0.3` supports up to vmx-21; 20 leaves headroom without assuming the newest possible revision) — the vCenter version alone doesn't guarantee the *hosts* support the same range.
- `vsphere_datastore_url` is a `ds:///vmfs/volumes/<uuid>/` path, not the datastore's display name, and isn't exposed by the `vsphere_datastore` data source. Find it via the datastore's `summary.url` property (a short pyvmomi or govc script against the same vCenter).

## Registry

`null_resource.install_registry` deploys `registry:2` in-cluster (namespace `registry`, PVC on `vsphere-csi`, exposed as a `NodePort` Service) with htpasswd basic auth (`registry_username`/`registry_password`, hashed via Terraform's native `bcrypt()` — no external `htpasswd` tool needed). Nodes pull from it at `http://<control_plane_vip>:<registry_node_port>` (default port `30500`) — this works from any node because NodePort is exposed by kube-proxy cluster-wide, independent of which node currently holds the kube-vip VIP. `local.registry_address` in [locals.tf](locals.tf) is that address; `templates/registries.yaml.tpl` renders both the containerd mirror config that trusts it as plain HTTP (no TLS) and the `configs.auth` block so containerd authenticates automatically on every node — without it, pulls fail with `no basic auth credentials`. Still no TLS by design; see the "Known active issue" and Drawbacks sections for why this shouldn't be reachable from anywhere untrusted.

Getting an image *into* it: there's no `docker` CLI on the nodes. Use RKE2's bundled `ctr` against its containerd socket, e.g. from any node:
```bash
CTR='sudo /var/lib/rancher/rke2/bin/ctr -a /run/k3s/containerd/containerd.sock -n k8s.io'
$CTR image pull --platform linux/amd64 docker.io/library/someimage:tag
$CTR image tag docker.io/library/someimage:tag <registry_address>/someimage:tag
$CTR image push --plain-http --platform linux/amd64 <registry_address>/someimage:tag
```
`--platform linux/amd64` on both pull and push matters: pulling a multi-arch tag without it stores the full manifest list, and pushing that list fails with `content digest ... not found` because `ctr` never actually downloaded the other platforms' blobs.

Getting registries.yaml onto nodes that already existed when this config was added is **not** something a plain reboot can do — see the cloud-init rough edge below. `null_resource.configure_registry_mirror_workers`/`_cp0`/`_cp1`/`_cp2` push the file over SSH and restart the RKE2 service directly instead (CP nodes one at a time, same quorum reasoning as everywhere else in this file). This is harmless to leave running on every apply, including against brand-new nodes that already got the file via cloud-init.

**Real incident(s)**: the registry's PVC hit ext4 journal corruption (`Aborting journal`, `input/output error` on reads) **three separate times** across this repo's history — first from repeated back-to-back `kubectl apply`/pod-recreate cycles while first standing it up, then twice more from unrelated node reboots during later rollouts, with the third occurrence happening with *no* intervening reboot at all. Each time the fix was the same (delete + recreate the PVC and Deployment; there was never real data worth recovering), but by the third occurrence it was clear this isn't specific to the registry or to reboots — see "Known active issue" at the top of this file. If this workload starts holding real data, don't casually re-`apply` its Deployment while a previous rollout might still be settling — a `Recreate`-strategy Deployment detaches/reattaches its volume on every pod recreation — but also don't assume fixing that eliminates the risk.

Expect `terraform plan` to periodically show a `disk { label = "orphaned_disk_N" -> "<remove, keep disk>" }` change on whichever node happens to be running the registry (or any other CSI-backed workload) at the time — that's Terraform noticing the CNS-attached VMDK it doesn't manage and normalizing its own bookkeeping label. It's a relabel only (the notation explicitly keeps the disk); applying it is safe and doesn't touch the volume's contents.

## Enterprise hardening

A few production-readiness gaps were closed after the initial build, all additive and independently verified against the live cluster:

- **`vsphere_compute_cluster_vm_anti_affinity_rule.control_plane`** (`mandatory = true`) keeps the 3 control-plane VMs on 3 different ESXi hosts. Without this, DRS is free to stack all 3 etcd members on one host, silently defeating the entire point of "3-node HA" — a single host failure would then take out the whole control plane. Requires at least 3 hosts in the target cluster to be satisfiable; `mandatory = true` will block host maintenance-mode entry if too few hosts remain to honor it.
- **`etcd_snapshot_schedule_cron`/`etcd_snapshot_retention`** enable RKE2's built-in etcd snapshotting (local disk only — see the variable descriptions in [variables.tf](variables.tf) for why this isn't real off-node DR by itself).
- **`reserve_memory`/`cpu_share_level`** on `modules/vm`, set for control-plane nodes only: a full memory reservation (no ballooning/swapping) plus high CPU shares, guarding etcd's latency-sensitive disk I/O against noisy-neighbor contention on shared hosts. A hard MHz `cpu_reservation` was deliberately avoided since it isn't portable across heterogeneous hosts.
- **`vsphere_tag_category.managed_by`/`vsphere_tag.terraform_managed`** mark every VM this repo creates at the vCenter level, applied via `modules/vm`'s `tag_ids` variable — visible in the vSphere client independent of anything in Terraform state.
- **`.github/workflows/terraform.yml`** runs `fmt -check` and `validate` on every push/PR. No vCenter credentials involved (`init -backend=false`), so it's safe to run against a public repo/fork without provisioning any secrets.
- **Registry basic auth** (`registry_username`/`registry_password`) — see the Registry section below.

**Rollout lesson**: `null_resource`s that push config over SSH (`configure_registry_mirror_*`) need an explicit `triggers` block hashing the content they push. Without one, changing what the referenced `local` value renders to (e.g. adding auth to `registries_config_yaml`) does **not** cause Terraform to re-run the provisioners against nodes the resource already succeeded on — `null_resource` has no other way to detect that the rendered file changed underneath it, and a stale push silently ships an outdated config to already-provisioned nodes indefinitely.

## Known rough edges to be aware of when editing

- `network_interface_name` (default `ens192`) is a guess at the guest NIC name for VMXNET3 adapters on Linux; it must match whatever the actual template produces, and isn't derived from anything Terraform can see.
- `wait_for_primary`'s remote-exec provisioner requires SSH connectivity from wherever `terraform apply` runs to the control-plane VIP subnet, and a private key at `var.ssh_private_key_path` matching `var.ssh_public_key`. Provisioners are inherently best-effort in Terraform (no state tracking, reruns on taint) — if bootstrap ordering ever needs to be more robust, that's the seam to reconsider.
- `rke2_version` is passed straight to `get.rke2.io`'s `INSTALL_RKE2_VERSION`; there's no validation that the value is a real RKE2 release.
- `wait_for_primary`'s readiness check tests raw TCP reachability on the RKE2 supervisor port (9345) rather than parsing `/readyz`'s HTTP response — RKE2 disables anonymous auth by default, so an unauthenticated `curl .../readyz` always 401s and a naive `grep -q ok` loops forever even on a healthy cluster.
- **A plain reboot never re-delivers a changed `write_files`/`runcmd` entry to a node that's already booted once.** Cloud-init's per-instance stage (which is what write_files and runcmd both run under) is gated by a marker file cloud-init leaves on disk, keyed off `instance-id` — it runs exactly once per instance-id per disk, not on every boot. So editing `templates/cloud-init/*.tpl` to add something new, then reconfiguring `extra_config.guestinfo.userdata` on an *existing* VM, produces a real, harmless reboot that changes nothing: the file never gets written, because cloud-init sees the same instance-id + an existing marker and skips the whole stage. This is exactly why [main.tf](main.tf) has separate `configure_registry_mirror_*` null_resources that push `registries.yaml` directly over SSH rather than relying on cloud-init to pick it up — that's the only way to reach nodes that predate the config change. New template edits only take effect automatically for genuinely fresh clones (a brand-new disk has no marker regardless of instance-id).
- **Never let `vsphere_virtual_machine.extra_config` update in place on a control-plane node that has already started RKE2.** If cloud-init reruns against a disk that already has etcd data on it (e.g. because only the `guestinfo.metadata`/`guestinfo.userdata` changed and Terraform did an in-place update rather than a replace), RKE2 comes back up with etcd still remembering its *old* IP/member identity and refuses to start — "this server is a not a member of the etcd cluster. Found ... expect: ...", looping forever. The fix is `terraform apply -replace=<that resource address>` to force a genuinely fresh clone, not just re-editing config and re-applying.
- The source template (built from Ubuntu's official cloud-image OVA) carries vApp properties in its OVF, so `modules/vm/main.tf` includes a `cdrom { client_device = true }` block purely to satisfy vSphere's "this VM requires a client CDROM device to deliver vApp properties" clone-time check — even though this module ignores vApp properties entirely and drives cloud-init via `extra_config`/GuestInfo instead.
- When a new control-plane node joins etcd, RKE2 triggers a resync of the control-plane static pods (kube-apiserver, etc.) cluster-wide to roll out updated certs/SANs. This produces a normal, self-healing minute-or-two window where already-`Ready` control-plane nodes flap through `activating`/connection-refused before settling — don't mistake it for a failure.
- `vsphere_virtual_machine` requires the target VM folder (`var.vsphere_folder`) to already exist — it will not create one implicitly. `main.tf` manages it explicitly via `resource "vsphere_folder" "vm_folder"` for exactly this reason.
- Don't trust a portgroup name or any placeholder IP scheme (including the ones in `terraform.tfvars.example`) to reflect the real subnet — verify against the actual vSphere network before setting static IPs. A fast, low-risk way to confirm: temporarily boot one node with a DHCP-only `metadata` (network config `dhcp4: true` instead of static addressing) via `-replace`+`-target` on that one resource, read back whatever address VMware Tools reports in `guest_ip_addresses` (visible via `terraform state show`, no SSH needed), then revert. Picking "currently free" static IPs from a ping sweep alone isn't enough either — anything inside the DHCP pool's range can be reassigned later; get the pool boundaries excluded/reserved on the router/DHCP server for whatever static range you land on.
- If the source template carries baked-in vApp properties from however it was originally built (check with a pyvmomi/govc script reading `config.vAppConfig.property` on a live VM — `terraform plan` will also surface it as unmanaged drift the first time a `vapp` block-less config is refreshed against such a VM), don't assume they're inert just because this module drives provisioning via `extra_config`/GuestInfo instead. Declare an explicit `vapp { properties = {...} }` block blanking every populated key rather than leaving it to chance.
- Any `vsphere_virtual_machine` attribute change that forces a real hardware reconfigure (`hardware_version`, `enable_disk_uuid`, `vapp`, ...) can have **side effects the plan didn't predict**: on this cluster, upgrading `hardware_version` silently reset `num_cores_per_socket` and `tools_upgrade_policy` on every node it touched, which only showed up as new drift on the *next* `terraform plan` (not the one that made the original change). After any such reconfigure, re-run `terraform plan` once more before considering the rollout done — don't assume a clean apply means a clean end state.
- The default 5-minute `wait_for_guest_net_timeout` can be too short after a hardware-version upgrade, since the guest's first boot on new virtual hardware is slower than a normal reboot; `modules/vm` sets it to 10 minutes. A `terraform apply` timing out here does not necessarily mean anything is wrong — check the VM's actual power/tools/IP state via pyvmomi before assuming failure, since the underlying vSphere task frequently completes fine after Terraform's own wait gives up.
- Any reconfigure applied to a running node (not just the initial clone) needs the same care as the etcd-corruption rough edge above re: **rollout order** — apply to workers first, then control-plane nodes one at a time (never in parallel), so etcd never loses quorum. `-target` on a resource also pulls in its Terraform *dependencies* (ancestors), not just the resource itself — e.g. targeting any `module.workers[n]` will also reconfigure `module.control_plane_primary`, since workers depend on `null_resource.wait_for_primary` which depends on it. Don't assume an apply only touched what you named; check `terraform state show` on anything upstream too.
