# A control plane and a worker, in containers that up.sh started on ports
# 2221 and 2222. CI passes the control plane's container address as cp_ip.
variable "cp_ip" {
  type = string
}

variable "join_token" {
  type      = string
  ephemeral = true
  default   = "abcdef.0123456789abcdef"
}

variable "certificate_key" {
  type      = string
  ephemeral = true
  default   = "0000000000000000000000000000000000000000000000000000000000000000"
}

module "kubeadm" {
  source = "../.."

  control_planes          = { cp1 = { address = "127.0.0.1", port = 2221 } }
  workers                 = { w1 = { address = "127.0.0.1", port = 2222 } }
  control_plane_endpoint  = "${var.cp_ip}:6443"
  join_token              = var.join_token
  certificate_key         = var.certificate_key
  ssh_private_key_file    = "./id_ed25519"
  ssh_known_hosts_file    = "./known_hosts"
  ignore_preflight_errors = ["SystemVerification"]
}
