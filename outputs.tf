output "config_file" {
  description = "Path of the configuration file the circuit writes on each host."
  value       = "/etc/openbao/openbao.hcl"
}

output "urls" {
  description = "Each host's API URL, by host name, as OpenBao advertises it in api_addr."
  value       = { for name, a in local.addr : name => "${local.scheme}://${a}:${var.api_port}" }
}
