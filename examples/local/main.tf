variable "port" {
  type    = number
  default = 2222
}

# Leave it false to initialise OpenBao yourself. CI sets it with
# TF_VAR_initialize=true.
variable "initialize" {
  type    = bool
  default = false
}

module "openbao" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  initialize = var.initialize
}

output "urls" {
  value = module.openbao.urls
}
