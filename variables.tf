variable "control_planes" {
  type        = any
  description = "Control plane nodes, by name: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts. Names become node names. The first name in sorted order runs kubeadm init."

  validation {
    condition     = length(var.control_planes) > 0
    error_message = "Give at least one control plane."
  }
}

variable "workers" {
  type        = any
  default     = {}
  description = "Worker nodes, by name, in the same form as control_planes. A name can't be both a control plane and a worker."

  validation {
    condition     = length(setintersection(keys(var.control_planes), keys(var.workers))) == 0
    error_message = "A name can't be both a control plane and a worker."
  }
}

variable "first_control_plane" {
  type        = string
  default     = null
  description = "Control plane that runs kubeadm init. When null, the first name in sorted order. Keep it the same for the life of the cluster: adding a control plane whose name sorts first would otherwise run kubeadm init on it."

  validation {
    condition     = var.first_control_plane == null || contains(keys(var.control_planes), coalesce(var.first_control_plane, "-"))
    error_message = "first_control_plane must be one of the names in control_planes."
  }
}

variable "join_token" {
  type        = string
  ephemeral   = true
  description = "Bootstrap token nodes join with, in kubeadm's form: 6 and 16 characters from a-z and 0-9, joined by a dot. kubeadm token generate makes one."

  validation {
    condition     = can(regex("^[a-z0-9]{6}\\.[a-z0-9]{16}$", var.join_token))
    error_message = "join_token must look like abcdef.0123456789abcdef."
  }
}

variable "certificate_key" {
  type        = string
  ephemeral   = true
  description = "Key that encrypts the control plane certificates kubeadm shares with joining control planes: 64 hex characters, such as from kubeadm certs certificate-key."

  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.certificate_key))
    error_message = "certificate_key must be 64 lowercase hex characters."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}


variable "kubernetes_version" {
  type        = string
  default     = "1.37"
  description = "Kubernetes minor version, such as \"1.37\". Nodes get the newest patch release of it from pkgs.k8s.io."

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version)) && tonumber(split(".", var.kubernetes_version)[1]) >= 31
    error_message = "kubernetes_version must be a minor version from 1.31 on, such as \"1.37\"."
  }
}

variable "control_plane_endpoint" {
  type        = string
  default     = null
  description = "Address and port of the Kubernetes API, such as a load balancer or a virtual IP. When null, the first control plane's address and port 6443."
}

variable "pod_cidr" {
  type        = string
  default     = "10.244.0.0/16"
  description = "Pod network. The default is the one Flannel expects."
}

variable "service_cidr" {
  type        = string
  default     = "10.96.0.0/12"
  description = "Service network."
}

variable "cni_manifest_url" {
  type        = string
  default     = "https://github.com/flannel-io/flannel/releases/download/v0.28.10/kube-flannel.yml"
  description = "Manifest of the pod network to apply after kubeadm init. Set null to install one yourself, as with Cilium's CLI or a Helm chart."

  validation {
    condition     = var.cni_manifest_url == null || can(regex("^https://[^'\\s]+$", coalesce(var.cni_manifest_url, "-")))
    error_message = "cni_manifest_url must be an https:// URL without quotes or spaces."
  }
}

variable "ignore_preflight_errors" {
  type        = list(string)
  default     = []
  description = "kubeadm preflight checks to treat as warnings, such as [\"SystemVerification\"]. Swap is always one, since the kubelet runs with failSwapOn false."
}
