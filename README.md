# circuit-kubeadm

A Conn3x circuit that builds an upstream Kubernetes cluster with kubeadm: one or more control planes, and as many workers as you give it. It installs containerd and the Kubernetes packages from their official repositories, runs `kubeadm init` on the first control plane, applies a pod network, and joins every other node.

This is the work a Terraform-plus-Ansible setup usually splits in two: Terraform makes the VMs and writes an inventory, then a playbook runs kubeadm and copies the join command from one host to the others. Here the VMs and the cluster go in one configuration. The join token and the CA hash pass between nodes inside the plan, and nothing waits on a `sleep 60`.

## Usage

```hcl
module "kubeadm" {
  source = "github.com/conn3xorg/circuit-kubeadm?ref=v0.1.0"

  control_planes = { cp1 = "203.0.113.10" }
  workers = {
    w1 = "203.0.113.20"
    w2 = "203.0.113.21"
  }
  join_token           = var.join_token
  certificate_key      = var.certificate_key
  ssh_private_key_file = "~/.ssh/id_ed25519"
}

variable "join_token" {
  type      = string
  ephemeral = true
}

variable "certificate_key" {
  type      = string
  ephemeral = true
}
```

Make the two secrets once and keep them for the life of the cluster:

```sh
export TF_VAR_join_token=$(kubeadm token generate)
export TF_VAR_certificate_key=$(kubeadm certs certificate-key)
```

Without kubeadm at hand, any 6 and 16 characters from `a-z0-9` joined by a dot make a token, and `openssl rand -hex 32` makes a certificate key. Both are ephemeral, so they never go into state or a plan. On the hosts they live in files only root can read.

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

### A highly available control plane

Give three control planes, and put a load balancer or a virtual IP in front of their port 6443 as `control_plane_endpoint`:

```hcl
module "kubeadm" {
  source = "github.com/conn3xorg/circuit-kubeadm?ref=v0.1.0"

  control_planes = {
    cp1 = "10.0.0.10"
    cp2 = "10.0.0.11"
    cp3 = "10.0.0.12"
  }
  workers                = { for name, vm in proxmox_virtual_environment_vm.worker : name => vm.ipv4_addresses[1][0] }
  control_plane_endpoint = "10.0.0.5:6443"
  join_token             = var.join_token
  certificate_key        = var.certificate_key
}
```

Without `control_plane_endpoint`, the cluster uses the first control plane's address, and the others can't take over if it goes down.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry:

```hcl
workers = {
  for name, d in digitalocean_droplet.worker : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Getting a kubeconfig

`kubeadm init` writes the cluster admin's kubeconfig to `/etc/kubernetes/admin.conf` on the first control plane:

```sh
ssh root@203.0.113.10 cat /etc/kubernetes/admin.conf > ~/.kube/config
kubectl get nodes
```

### Choosing a pod network

The default `cni_manifest_url` is Flannel v0.28.10, which matches the default `pod_cidr`. For Calico, give its manifest and the pod network it expects. For Cilium, set `cni_manifest_url = null` and install it with its CLI or Helm chart once the control plane is up. The nodes show `NotReady` until a pod network runs.

## What it does

On every node, in order:

1. Makes sure the kernel has `br_netfilter`. Rocky Linux 10 and other EL10 images ship it in `kernel-modules-extra`, which they don't install, so on those hosts the circuit installs `kernel-modules-extra` for the running kernel with `dnf`.
2. Loads `overlay` and `br_netfilter` now and at boot, and sets `net.ipv4.ip_forward` and the two `net.bridge.bridge-nf-call-*` sysctls to `1`.
3. Adds Docker's repository and installs `containerd.io` from it, then writes `/etc/containerd/config.toml` with CRI on and the systemd cgroup driver, and starts containerd.
4. Adds the pkgs.k8s.io repository for `kubernetes_version` and installs `kubelet`, `kubeadm` and `kubectl`. The keys for both repositories are in [files](files).
5. Enables the kubelet, which kubeadm starts once it has a configuration.

Then, on the first control plane:

6. Writes `/etc/kubernetes/kubeadm.yaml`, with the node name, the endpoint, the pod and service networks, the systemd cgroup driver, and `failSwapOn: false` so hosts with swap work. It holds the token and the certificate key, so it's write-only.
7. Runs `kubeadm init` once, until `/etc/kubernetes/admin.conf` exists, and applies `cni_manifest_url`.
8. Creates the join token, valid for two hours, and uploads the control plane certificates for the other control planes.
9. Reads the hash of the cluster's CA, which the other nodes check the control plane against.

Then the other control planes join with `--control-plane`, and the workers join, each once, until `/etc/kubernetes/kubelet.conf` exists. Node names are the names you gave, such as `cp1` and `w1`.

Adding a node later works the same way. A change to the set of nodes creates a fresh token and uploads the certificates again before the new nodes join, since kubeadm deletes them after two hours.

Before the circuit runs, the `conn3x_host` data source reads each host's distribution over SSH. On Debian and Ubuntu it picks the apt suite for containerd from the release: Ubuntu 22.04, 24.04 and 26.04, and Debian 12 and 13. Another release fails the plan.

The circuit doesn't open firewall ports. Nodes need TCP 6443 to the control planes, TCP 10250 between all nodes, TCP 2379-2380 between control planes, and whatever the pod network uses, such as UDP 8472 for Flannel. Kubernetes's [ports and protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/) page lists them.

### Upgrading

Upgrading Kubernetes means draining nodes and running `kubeadm upgrade` on each in turn, which this circuit doesn't do yet. Raising `kubernetes_version` points the repositories at the new minor version, so do it as part of an upgrade you run by hand, following Kubernetes's [kubeadm upgrade guide](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/).

### Removing a node

Deleting a node from the map leaves it in the cluster. Drain it and run `kubectl delete node NAME` first, then `kubeadm reset` on the host.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `control_planes` | any | Required | Control plane nodes, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. Names become node names. The first name in sorted order runs `kubeadm init`. |
| `workers` | any | `{}` | Worker nodes, by name, in the same form. |
| `join_token` | string, ephemeral | Required | Bootstrap token, such as from `kubeadm token generate`. |
| `certificate_key` | string, ephemeral | Required | 64 hex characters, such as from `kubeadm certs certificate-key`. |
| `kubernetes_version` | string | `"1.37"` | Kubernetes minor version, from 1.31 on. Nodes get its newest patch release. |
| `control_plane_endpoint` | string | `null` | Address and port of the Kubernetes API, such as a load balancer. When null, the first control plane's address and port 6443. |
| `pod_cidr` | string | `"10.244.0.0/16"` | Pod network. |
| `service_cidr` | string | `"10.96.0.0/12"` | Service network. |
| `cni_manifest_url` | string | Flannel v0.28.10 | Pod network manifest to apply after `kubeadm init`, or null to install one yourself. |
| `ignore_preflight_errors` | list(string) | `[]` | kubeadm preflight checks to treat as warnings, such as `["SystemVerification"]`. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |

## Outputs

| Name | Description |
| --- | --- |
| `control_plane_endpoint` | Address and port of the Kubernetes API, such as `"203.0.113.10:6443"`. |

## Requirements

Requires Conn3x v0.6.4 or later and systemd on each host, with outbound HTTPS to download.docker.com, pkgs.k8s.io and registry.k8s.io. kubeadm needs 2 CPUs and 2 GB of memory on a control plane.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes and that the node is Ready, and joins a worker to a control plane from [test/cluster](test/cluster).

Also checked by hand on DigitalOcean: two control planes on Ubuntu 24.04 and Rocky Linux 10 with SELinux enforcing, a worker on Debian 13, and a second worker on Rocky Linux 9 added later, with Kubernetes 1.37.

## License

MPL-2.0. See [LICENSE](LICENSE). Kubernetes and containerd are Apache-2.0.
