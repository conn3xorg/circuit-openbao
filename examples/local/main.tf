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

# Auto-unseal and self-initialisation. CI sets these with TF_VAR_seal,
# TF_VAR_self_init and TF_VAR_environment, against a second OpenBao in
# dev mode as the unsealer.
variable "seal" {
  type    = any
  default = null
}

variable "self_init" {
  type    = any
  default = null
}

variable "environment" {
  type      = map(string)
  default   = null
  ephemeral = true
  sensitive = true
}

module "openbao" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  initialize  = var.initialize
  seal        = var.seal
  self_init   = var.self_init
  environment = var.environment
}

output "urls" {
  value = module.openbao.urls
}
