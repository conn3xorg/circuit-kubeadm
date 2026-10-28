variable "port" {
  type    = number
  default = 2222
}

# Throwaway values for a local cluster. Generate real ones with
# kubeadm token generate and kubeadm certs certificate-key.
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

  control_planes       = { cp1 = "127.0.0.1" }
  join_token           = var.join_token
  certificate_key      = var.certificate_key
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # A container has no kernel config for kubeadm to check.
  ignore_preflight_errors = ["SystemVerification"]
}
