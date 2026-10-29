# Facts give each host's architecture, which picks the release tarball.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = contains(keys(var.checksums), self.arch)
      error_message = "Host ${each.key} is ${self.arch}. The circuit has OpenBao builds for ${join(" and ", keys(var.checksums))}."
    }
  }
}

locals {
  home      = "/var/lib/openbao"
  dir       = "/opt/openbao/${var.openbao_version}"
  binary    = "${local.dir}/bao"
  config    = "/etc/openbao/openbao.hcl"
  init_file = "/root/openbao-init.json"

  tls    = var.tls_cert_file != null
  scheme = local.tls ? "https" : "http"

  # Release tarballs name architectures the Go way.
  goarch  = { x86_64 = "amd64", aarch64 = "arm64" }
  tarball = { for name, f in data.conn3x_host.facts : name => "openbao_${var.openbao_version}_linux_${local.goarch[f.arch]}.tar.gz" }

  # Where the host itself reaches the API. 0.0.0.0 and :: listen on
  # loopback too.
  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.listen_address, strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address)
  local_url  = "${local.scheme}://${local.local_host}:${var.api_port}"

  # The circuit talks to OpenBao over loopback, which a certificate for the
  # host's own name doesn't cover, so its checks skip verification. Nothing
  # but the host itself is on the other end.
  curl = local.tls ? "curl -sk" : "curl -s"
  bao  = "BAO_ADDR=${local.local_url}${local.tls ? " BAO_SKIP_VERIFY=true" : ""} ${local.binary}"

  # The address other nodes and clients are told to use: the host's own
  # address when OpenBao listens on every address.
  addr_host = { for name, h in var.hosts : name => contains(["0.0.0.0", "::"], var.listen_address) ? try(h.address, h) : var.listen_address }
  addr      = { for name, a in local.addr_host : name => strcontains(a, ":") ? "[${a}]" : a }

  # JSON strings are HCL strings, so jsonencode quotes values safely.
  config_content = { for name, h in var.hosts : name => <<-EOT
    # Written by Conn3x. Changes here are overwritten on the next apply.
    ui           = ${var.ui}
    api_addr     = ${jsonencode("${local.scheme}://${local.addr[name]}:${var.api_port}")}
    cluster_addr = ${jsonencode("https://${local.addr[name]}:${var.api_port + 1}")}

    storage "raft" {
      path    = ${jsonencode(local.home)}
      node_id = ${jsonencode(name)}
    }

    listener "tcp" {
      address = ${jsonencode("${strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address}:${var.api_port}")}
    ${local.tls ? "  tls_cert_file = ${jsonencode(var.tls_cert_file)}\n  tls_key_file  = ${jsonencode(var.tls_key_file)}" : "  tls_disable = true"}
    }
  EOT
  }
}

circuit "openbao" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Minimal images can lack any of these.
  step "tools" {
    for_each = toset(["curl", "tar", "gzip"])
    package {
      name = item.value
    }
  }

  step "user" {
    user {
      name   = "openbao"
      system = true
      home   = local.home
      shell  = "/usr/sbin/nologin"
    }
  }

  # Raft keeps its database here, encrypted by the barrier.
  step "data_dir" {
    directory {
      path  = local.home
      owner = "openbao"
      group = "openbao"
      mode  = "0700"
    }
  }

  step "release_dir" {
    directory {
      path = local.dir
    }
  }

  # The same static binary runs on every distribution, so one tarball and
  # one checksum per architecture cover them all.
  step "download" {
    download {
      url    = "https://github.com/openbao/openbao/releases/download/v${var.openbao_version}/${local.tarball[each.key]}"
      sha256 = var.checksums[data.conn3x_host.facts[each.key].arch]
      dest   = "${local.dir}/${local.tarball[each.key]}"
    }
  }

  step "unpack" {
    archive {
      src     = "${local.dir}/${local.tarball[each.key]}"
      dest    = local.dir
      creates = local.binary
    }
  }

  # Puts the bao CLI on the PATH for running operator commands by hand.
  step "cli" {
    command {
      command = "ln -sfn ${local.binary} /usr/local/bin/bao"
      unless  = "[ \"$(readlink /usr/local/bin/bao)\" = ${local.binary} ]"
    }
  }

  step "config_dir" {
    directory {
      path  = "/etc/openbao"
      owner = "root"
      group = "openbao"
      mode  = "0750"
    }
  }

  step "config" {
    file {
      path    = local.config
      content = local.config_content[each.key]
      owner   = "root"
      group   = "openbao"
      mode    = "0640"
    }
  }

  # Upstream's unit from the .deb and .rpm, with the binary's path. OpenBao
  # dropped mlock in 2.0, so there's no CAP_IPC_LOCK or LimitMEMLOCK;
  # MemorySwapMax=0 keeps its memory out of swap instead.
  step "unit" {
    file {
      path    = "/etc/systemd/system/openbao.service"
      content = <<-EOT
        [Unit]
        Description=OpenBao secrets manager
        Documentation=https://openbao.org/docs/
        Requires=network-online.target
        After=network-online.target
        ConditionFileNotEmpty=${local.config}
        StartLimitIntervalSec=60
        StartLimitBurst=3

        [Service]
        Type=notify
        User=openbao
        Group=openbao
        ProtectSystem=full
        ProtectHome=read-only
        PrivateTmp=yes
        PrivateDevices=yes
        SecureBits=keep-caps
        CapabilityBoundingSet=CAP_SYSLOG
        NoNewPrivileges=yes
        ExecStart=${local.binary} server -config=${local.config}
        ExecReload=/bin/kill --signal HUP $MAINPID
        KillMode=process
        KillSignal=SIGINT
        Restart=on-failure
        RestartSec=5
        TimeoutStopSec=30
        MemorySwapMax=0

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # A restart seals OpenBao, so after a change to the config or unit it
  # needs unsealing again. It runs here rather than in a handler, which
  # would come after the steps below, so they find OpenBao running with
  # the new settings. On a first apply it's what starts it.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart openbao"
      triggers = {
        config = conn3x_file.openbao__config[each.key].revision
        unit   = conn3x_file.openbao__unit[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "openbao"
      state   = "started"
      enabled = true
    }
  }

  # /v1/sys/health answers with some status whether OpenBao is sealed,
  # unsealed or not initialised yet, so any answer means it's up.
  step "ready" {
    command {
      command = "for _ in $(seq 60); do ${local.curl} -o /dev/null ${local.local_url}/v1/sys/health && exit 0; sleep 1; done; exit 1"
      unless  = "${local.curl} -o /dev/null ${local.local_url}/v1/sys/health"
      triggers = {
        restart = conn3x_command.openbao__restart[each.key].revision
      }
    }
  }

  # Runs once. The unseal key and root token go to a root-only file on the
  # host and never into the plan or state. A host someone has already
  # initialised by hand is left alone.
  step "init" {
    for_each = var.initialize ? ["init"] : []
    command {
      command = "umask 077 && ${local.bao} operator init -key-shares=1 -key-threshold=1 -format=json > ${local.init_file}.new && mv ${local.init_file}.new ${local.init_file}"
      unless  = "[ -s ${local.init_file} ] || ${local.curl} ${local.local_url}/v1/sys/init | grep -q '\"initialized\":true'"
    }
  }
}
