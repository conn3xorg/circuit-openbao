variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
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

variable "openbao_version" {
  type        = string
  default     = "2.7.2"
  description = "OpenBao release to install, without the leading v."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.openbao_version))
    error_message = "openbao_version must be a release number such as \"2.7.2\", without the leading v."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the linux_amd64 and linux_arm64 release tarballs, keyed x86_64 and aarch64, from the release's checksums.txt. Change these with openbao_version."
  default = {
    x86_64  = "582b1f3c2fdc5afd443b2d57a225ef654de75adea609fdb66731fd582a9cbc96"
    aarch64 = "5b97bf816fa820e5e521abec1db19c6161fcca2f666cf4a84e335089c0e83edd"
  }

  validation {
    condition     = alltrue([for a, c in var.checksums : contains(["x86_64", "aarch64"], a) && can(regex("^[0-9a-f]{64}$", c))])
    error_message = "checksums maps x86_64 or aarch64 to a SHA-256 in lowercase hex."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address the API listens on. The default keeps OpenBao to the host itself. Any address other than loopback needs tls_cert_file and tls_key_file."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IP address, such as \"127.0.0.1\" or \"0.0.0.0\"."
  }

  # Unseal keys and tokens cross this listener, so it carries them in plain
  # HTTP only where nothing but the host itself can reach it.
  validation {
    condition     = var.tls_cert_file != null || startswith(var.listen_address, "127.") || var.listen_address == "::1"
    error_message = "listen_address is not a loopback address, so OpenBao needs TLS: set tls_cert_file and tls_key_file."
  }
}

variable "api_port" {
  type        = number
  default     = 8200
  description = "Port of the API and UI. The cluster port, which raft uses, is the next one up."

  validation {
    condition     = var.api_port >= 1 && var.api_port <= 65534 && floor(var.api_port) == var.api_port
    error_message = "api_port must be a port number from 1 to 65534."
  }
}

variable "tls_cert_file" {
  type        = string
  default     = null
  description = "Path on the host of the listener's certificate, in PEM, with any intermediates after it. When null, the listener runs plain HTTP, which only a loopback listen_address allows. The openbao user must be able to read it."

  validation {
    condition     = (var.tls_cert_file == null) == (var.tls_key_file == null)
    error_message = "Set tls_cert_file and tls_key_file together, or neither."
  }

  validation {
    condition     = var.tls_cert_file == null || startswith(coalesce(var.tls_cert_file, "/"), "/") && !strcontains(coalesce(var.tls_cert_file, "/"), "\"")
    error_message = "tls_cert_file must be an absolute path."
  }
}

variable "tls_key_file" {
  type        = string
  default     = null
  description = "Path on the host of the listener's private key, in PEM. The openbao user must be able to read it."

  validation {
    condition     = var.tls_key_file == null || startswith(coalesce(var.tls_key_file, "/"), "/") && !strcontains(coalesce(var.tls_key_file, "/"), "\"")
    error_message = "tls_key_file must be an absolute path."
  }
}

variable "ui" {
  type        = bool
  default     = true
  description = "Serve the web UI on the API port, at /ui."
}

variable "initialize" {
  type        = bool
  default     = false
  description = "Initialise OpenBao on the first apply with one unseal key, and write the key and root token to /root/openbao-init.json, mode 0600. For labs and homelabs only: the key sits on the same disk as the data it protects. When false, run bao operator init yourself."
}
