# Facts give each host's distribution, which picks the package repositories.
data "conn3x_host" "facts" {
  for_each = local.nodes

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  nodes = merge(var.control_planes, var.workers)

  # The first control plane by name runs kubeadm init. The others join it.
  first    = coalesce(var.first_control_plane, sort(keys(var.control_planes))[0])
  endpoint = coalesce(var.control_plane_endpoint, "${try(var.control_planes[local.first].address, var.control_planes[local.first])}:6443")
  admin    = "--kubeconfig /etc/kubernetes/admin.conf"

  # containerd.io comes from Docker's repository, which has one per
  # distribution. apt needs the release's codename.
  docker_repo = { rocky = "rhel", almalinux = "rhel", rhel = "rhel", centos = "rhel", fedora = "fedora", ubuntu = "ubuntu", debian = "debian" }
  codename    = { "22.04" = "jammy", "24.04" = "noble", "26.04" = "resolute", "12" = "bookworm", "13" = "trixie" }
  k8s_repo    = "https://pkgs.k8s.io/core:/stable:/v${var.kubernetes_version}"

  repos = {
    for name, f in data.conn3x_host.facts : name => f.os_family == "redhat" ? {
      docker_url  = "https://download.docker.com/linux/${local.docker_repo[f.os_id]}/$releasever/$basearch/stable"
      docker_key  = file("${path.module}/files/docker-rpm.asc")
      docker_from = null
      k8s_url     = "${local.k8s_repo}/rpm/"
      k8s_from    = null
      } : {
      docker_url  = "https://download.docker.com/linux/${local.docker_repo[f.os_id]}"
      docker_key  = file("${path.module}/files/docker-deb.asc")
      docker_from = [local.codename[f.os_version]]
      k8s_url     = "${local.k8s_repo}/deb/"
      k8s_from    = ["/"]
    }
  }

  # Pod traffic to services needs br_netfilter. Rocky Linux 10 and other
  # EL10 images ship it in kernel-modules-extra, which they don't install.
  # A container can't load modules, so a module its host loaded counts.
  br_netfilter = {
    command = "command -v dnf >/dev/null || { echo 'br_netfilter is missing and this host has no dnf to install kernel-modules-extra' >&2; exit 1; }; dnf -y install \"kernel-modules-extra-$(uname -r)\""
    unless  = "test -d /sys/module/br_netfilter || modprobe -n br_netfilter"
  }

  init_config = <<-EOT
    apiVersion: kubeadm.k8s.io/v1beta4
    kind: InitConfiguration
    bootstrapTokens:
      - token: "${var.join_token}"
        ttl: 2h
    certificateKey: "${var.certificate_key}"
    nodeRegistration:
      name: "${local.first}"
    ---
    apiVersion: kubeadm.k8s.io/v1beta4
    kind: ClusterConfiguration
    controlPlaneEndpoint: "${local.endpoint}"
    networking:
      podSubnet: "${var.pod_cidr}"
      serviceSubnet: "${var.service_cidr}"
    ---
    apiVersion: kubelet.config.k8s.io/v1beta1
    kind: KubeletConfiguration
    cgroupDriver: systemd
    failSwapOn: false
  EOT

  # Adding a node issues a fresh join token and uploads the control plane
  # certificates again, since kubeadm deletes them after two hours.
  join_env = "/etc/kubernetes/conn3x-join.env"
  ca_hash  = trimspace(conn3x_command.kubeadm_first__ca_hash[local.first].stdout)
}

circuit "kubeadm_node" {
  hosts = local.nodes

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "br_netfilter" {
    command {
      command = local.br_netfilter.command
      unless  = local.br_netfilter.unless
    }
  }

  # Minimal images such as Rocky Linux's ubi-init lack these directories.
  # Conn3x v0.6.4's sysctl step doesn't create its own.
  step "config_dirs" {
    for_each = toset(["/etc/modules-load.d", "/etc/sysctl.d"])
    directory {
      path = item.value
    }
  }

  step "modules_at_boot" {
    file {
      path    = "/etc/modules-load.d/kubernetes.conf"
      content = "overlay\nbr_netfilter\n"
    }
  }

  step "modules" {
    command {
      command = "modprobe -a overlay br_netfilter"
      unless  = "test -d /sys/module/overlay && test -d /sys/module/br_netfilter"
    }
  }

  step "sysctl" {
    for_each = {
      "net.ipv4.ip_forward"                 = "1"
      "net.bridge.bridge-nf-call-iptables"  = "1"
      "net.bridge.bridge-nf-call-ip6tables" = "1"
    }
    sysctl {
      name  = item.key
      value = item.value
    }
  }

  step "docker_repo" {
    repository {
      name       = "docker-ce"
      url        = local.repos[each.key].docker_url
      key        = local.repos[each.key].docker_key
      suites     = local.repos[each.key].docker_from
      components = ["stable"]
    }
  }

  step "containerd" {
    package {
      name = "containerd.io"
    }
  }

  # containerd.io ships with CRI turned off. This turns it on, with the
  # systemd cgroup driver the kubelet uses.
  step "containerd_config" {
    file {
      path    = "/etc/containerd/config.toml"
      content = <<-EOT
        version = 3

        [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
          SystemdCgroup = true
      EOT
    }
    notify = [handler.restart_containerd]
  }

  step "containerd_running" {
    service {
      name    = "containerd"
      state   = "started"
      enabled = true
    }
  }

  step "kubernetes_repo" {
    repository {
      name   = "kubernetes"
      url    = local.repos[each.key].k8s_url
      key    = file("${path.module}/files/kubernetes.asc")
      suites = local.repos[each.key].k8s_from
    }
  }

  step "kubernetes" {
    for_each = toset(["kubelet", "kubeadm", "kubectl"])
    package {
      name = item.value
    }
  }

  # kubeadm starts the kubelet once it has a configuration.
  step "kubelet" {
    service {
      name    = "kubelet"
      enabled = true
    }
  }

  handler "restart_containerd" {
    service {
      name = "containerd"
    }
  }
}

circuit "kubeadm_first" {
  hosts = { (local.first) = var.control_planes[local.first] }

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The CA hash below needs openssl, which minimal images can lack.
  step "openssl" {
    package {
      name = "openssl"
    }
    depends_on = [conn3x_service.kubeadm_node__kubelet]
  }

  # It holds the join token and the certificate key, so it's write-only.
  step "config" {
    file {
      path       = "/etc/kubernetes/kubeadm.yaml"
      content_wo = local.init_config
    }
  }

  step "join_secrets" {
    file {
      path       = local.join_env
      content_wo = "TOKEN=${var.join_token}\n"
    }
  }

  step "init" {
    command {
      command = "kubeadm init --config /etc/kubernetes/kubeadm.yaml --upload-certs --ignore-preflight-errors=${join(",", concat(["Swap"], var.ignore_preflight_errors))} >/dev/null"
      creates = "/etc/kubernetes/admin.conf"
    }
  }

  step "cni" {
    for_each = toset(compact([var.cni_manifest_url]))
    command {
      command  = "kubectl ${local.admin} apply -f '${item.value}'"
      triggers = { url = item.value }
    }
  }

  step "join_token" {
    command {
      command  = ". ${local.join_env} && { kubeadm token delete \"$TOKEN\" ${local.admin} >/dev/null 2>&1 || true; } && kubeadm token create \"$TOKEN\" --ttl 2h ${local.admin} >/dev/null && kubeadm init phase upload-certs --upload-certs --config /etc/kubernetes/kubeadm.yaml >/dev/null"
      triggers = { nodes = join(",", sort(keys(local.nodes))) }
    }
  }

  step "ca_hash" {
    command {
      command = "openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform der | sha256sum | cut -d' ' -f1"
    }
  }
}

circuit "kubeadm_control_planes" {
  hosts = { for name, h in var.control_planes : name => h if name != local.first }

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "join_config" {
    file {
      path       = "/etc/kubernetes/conn3x-join.yaml"
      content_wo = <<-EOT
        apiVersion: kubeadm.k8s.io/v1beta4
        kind: JoinConfiguration
        discovery:
          bootstrapToken:
            apiServerEndpoint: "${local.endpoint}"
            token: "${var.join_token}"
            caCertHashes: ["sha256:${local.ca_hash}"]
        nodeRegistration:
          name: "${each.key}"
        controlPlane:
          certificateKey: "${var.certificate_key}"
      EOT
    }
    depends_on = [conn3x_command.kubeadm_first__join_token]
  }

  step "join" {
    command {
      command = "kubeadm join --config /etc/kubernetes/conn3x-join.yaml --ignore-preflight-errors=${join(",", concat(["Swap"], var.ignore_preflight_errors))}"
      creates = "/etc/kubernetes/kubelet.conf"
    }
  }
}

circuit "kubeadm_workers" {
  hosts = var.workers

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "join_config" {
    file {
      path       = "/etc/kubernetes/conn3x-join.yaml"
      content_wo = <<-EOT
        apiVersion: kubeadm.k8s.io/v1beta4
        kind: JoinConfiguration
        discovery:
          bootstrapToken:
            apiServerEndpoint: "${local.endpoint}"
            token: "${var.join_token}"
            caCertHashes: ["sha256:${local.ca_hash}"]
        nodeRegistration:
          name: "${each.key}"
      EOT
    }
    depends_on = [conn3x_command.kubeadm_first__join_token]
  }

  step "join" {
    command {
      command = "kubeadm join --config /etc/kubernetes/conn3x-join.yaml --ignore-preflight-errors=${join(",", concat(["Swap"], var.ignore_preflight_errors))}"
      creates = "/etc/kubernetes/kubelet.conf"
    }
  }
}
