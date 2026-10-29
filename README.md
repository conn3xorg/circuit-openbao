# circuit-openbao

A Conn3x circuit that runs [OpenBao](https://openbao.org), the Linux Foundation's open source fork of HashiCorp Vault, on your own hosts. You get the same secrets engines, auth methods and `bao` CLI as Vault's `vault`, under MPL-2.0, on a box you control.

It downloads a pinned OpenBao release, checks its SHA-256, and runs `bao server` under systemd as its own `openbao` user, with integrated storage (raft) as a single node in `/var/lib/openbao`. It writes `/etc/openbao/openbao.hcl` from a handful of inputs and restarts OpenBao when that changes. Out of the box it listens only on `127.0.0.1:8200`, over plain HTTP. Any other address needs a certificate, and the plan refuses one without it.

What it leaves to you, by default, is the moment that matters most: initialising OpenBao and holding its unseal keys. For a lab there's `initialize = true`, which does that for you and leaves the key on the host. Read [Initialising and unsealing](#initialising-and-unsealing) before you use it.

## Usage

```hcl
module "openbao" {
  source = "github.com/conn3xorg/circuit-openbao?ref=v0.1.0"

  hosts                = { bao1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

OpenBao is now running, uninitialised and sealed. On the host:

```sh
export BAO_ADDR=http://127.0.0.1:8200
bao operator init
```

That prints five unseal keys and a root token, once. Keep them somewhere other than this host. Then give it any three of the keys:

```sh
bao operator unseal   # three times, one key each
bao login             # with the root token
```

To reach OpenBao from other machines, give it a certificate. The files must already be on the host and readable by the `openbao` user, for example from [circuit-certbot](https://github.com/conn3xorg/circuit-certbot) or your own CA:

```hcl
module "openbao" {
  source = "github.com/conn3xorg/circuit-openbao?ref=v0.1.0"

  hosts                = { bao1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  listen_address = "0.0.0.0"
  tls_cert_file  = "/etc/openbao/tls/tls.crt"
  tls_key_file   = "/etc/openbao/tls/tls.key"
}
```

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry:

```hcl
hosts = {
  for name, d in digitalocean_droplet.bao : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

## Initialising and unsealing

OpenBao starts sealed every time, after a reboot and after every restart. Its data is encrypted with a key it can only rebuild from the unseal keys, so until someone hands those over it can't read anything. That's the point, and it's why this circuit keeps out of the way by default: with `initialize = false` it never touches the keys, and they never pass through Conn3x, its plan or its state.

### `initialize = true`: labs and homelabs only

> **Warning.** With `initialize = true`, the only unseal key and the root token are written in plain text to `/root/openbao-init.json` on the same host as the data they protect. Anyone who gets root on that host, or a copy of its disk or a backup of it, gets every secret in OpenBao. Use it for a lab, a homelab or CI. Don't use it for anything you'd mind losing control of.

On the first apply, the circuit runs this once:

```sh
bao operator init -key-shares=1 -key-threshold=1 -format=json
```

and writes the output to `/root/openbao-init.json`, mode `0600`. It holds one unseal key and the root token. The key and token stay on the host; Conn3x's plan and state record only that the command ran. If the file already exists, or OpenBao says it's already initialised, the circuit leaves it alone, so turning `initialize` on for a host you set up by hand changes nothing.

OpenBao still starts sealed. To unseal it after a reboot, run this and paste the key from `unseal_keys_b64` when it asks:

```sh
export BAO_ADDR=http://127.0.0.1:8200
cat /root/openbao-init.json
bao operator unseal
```

Then log in with the token from `root_token`, set up an auth method, and revoke the root token once you no longer need it.

Auto-unseal, with a cloud KMS, a transit engine on another OpenBao or a PKCS#11 device, is out of scope. You can add a `seal` stanza to a copy of the circuit if you need it.

## What it does

On each host, in order:

1. Installs `curl`, `tar` and `gzip` if they're missing.
2. Creates the `openbao` system user, with home `/var/lib/openbao` and no login shell. That directory, mode `0700`, holds the raft database.
3. Downloads `openbao_VERSION_linux_ARCH.tar.gz` from the GitHub release into `/opt/openbao/VERSION/` and unpacks the `bao` binary there. If the checksum doesn't match `checksums`, the apply fails and nothing is unpacked. The binary is static, so the same one runs on every distribution.
4. Links `/usr/local/bin/bao` to it, so the CLI is on the PATH.
5. Writes `/etc/openbao/openbao.hcl`, owned by `root:openbao` with mode `0640`, and `/etc/systemd/system/openbao.service`. A change to either restarts OpenBao, which seals it.
6. Starts OpenBao now and at boot, and waits until `/v1/sys/health` answers.
7. With `initialize = true`, initialises it once, as above.

The config sets `api_addr` and `cluster_addr` to `listen_address`, or to the host's own address when `listen_address` is `0.0.0.0` or `::`. The cluster port is the next one after `api_port`.

The unit is the one OpenBao ships in its `.deb` and `.rpm` packages, pointed at the unpacked binary: `ProtectSystem=full`, `ProtectHome=read-only`, `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`, a capability bounding set of `CAP_SYSLOG` and `MemorySwapMax=0`. If you're used to Vault's unit, you'll notice there's no `CAP_IPC_LOCK` or `LimitMEMLOCK`. OpenBao removed mlock in 2.0, so neither does anything; keeping its memory out of swap is what `MemorySwapMax=0` is for.

Before the circuit runs, the `conn3x_host` data source reads each host's architecture over SSH. `x86_64` and `aarch64` each get their own build; other architectures fail the plan.

### What it doesn't do

- It doesn't unseal OpenBao, ever. With the default it doesn't initialise it either.
- It doesn't make or renew certificates. Point `tls_cert_file` and `tls_key_file` at files something else keeps up to date. A renewed certificate needs a `systemctl reload openbao` to take effect.
- It doesn't join hosts into a raft cluster. Each host is a single node of its own.
- It doesn't open a firewall port. Open `api_port` with [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) or a step of your own.
- It doesn't configure secrets engines, auth methods or policies. Do that with `bao` once it's unsealed.
- It doesn't take backups. `bao operator raft snapshot save` takes one; copying it somewhere safe is up to you.
- Deleting the module leaves OpenBao installed and running, with its data.

### Upgrading

Set `openbao_version` and `checksums` together. The release's `checksums.txt` lists them, under `linux_amd64.tar.gz` and `linux_arm64.tar.gz`:

```hcl
module "openbao" {
  source = "github.com/conn3xorg/circuit-openbao?ref=v0.1.0"

  hosts           = { bao1 = "203.0.113.10" }
  openbao_version = "2.7.2"
  checksums = {
    x86_64  = "582b1f3c2fdc5afd443b2d57a225ef654de75adea609fdb66731fd582a9cbc96"
    aarch64 = "5b97bf816fa820e5e521abec1db19c6161fcca2f666cf4a84e335089c0e83edd"
  }
}
```

The new release unpacks beside the old one, the unit points at it, and OpenBao restarts on the same data, sealed. Unseal it again afterwards. The old directory stays until you remove it. Take a raft snapshot first, and read OpenBao's upgrade notes before a jump of more than one minor version.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. The name is the host's raft `node_id`. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `openbao_version` | string | `"2.7.2"` | OpenBao release to install, without the leading `v`. |
| `checksums` | map(string) | The 2.7.2 checksums | SHA-256 of the release tarball for `x86_64` and `aarch64`. |
| `listen_address` | string | `"127.0.0.1"` | Address the API listens on. Anything but a loopback address needs `tls_cert_file` and `tls_key_file`. `"0.0.0.0"` listens on every address. |
| `api_port` | number | `8200` | Port of the API and UI. Raft's cluster port is the next one. |
| `tls_cert_file` | string | `null` | Path on the host of the listener's certificate in PEM, with any intermediates after it. When null, the listener runs plain HTTP. |
| `tls_key_file` | string | `null` | Path on the host of the listener's private key in PEM. Set it together with `tls_cert_file`. |
| `ui` | bool | `true` | Serve the web UI at `/ui`. |
| `initialize` | bool | `false` | Initialise OpenBao on the first apply with a single unseal key, and write the key and root token to `/root/openbao-init.json`, mode `0600`. Labs and homelabs only; see above. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the configuration file, `/etc/openbao/openbao.hcl`. |
| `urls` | Each host's API URL by host name, as OpenBao advertises it in `api_addr`, such as `{ bao1 = "https://203.0.113.10:8200" }`. |

## Requirements

Requires Conn3x v0.6.5 or later, systemd on each host, and outbound HTTPS to github.com. In a container, systemd needs `CAP_SYS_ADMIN` to give OpenBao the private `/dev` its unit asks for; [examples/local](examples/local) adds it.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13, with OpenBao 2.7.2. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes and that the uninitialised server answers `/v1/sys/health` with `501`. It then applies again with `initialize = true`, unseals with the key from `/root/openbao-init.json`, enables a KV v2 engine and writes and reads a secret with the root token, restarts OpenBao, checks that it came back sealed, unseals it and reads the secret again, and checks that the plan is still clean. The same ran by hand on arm64, along with a switch to `listen_address = "0.0.0.0"` with a self-signed certificate on Fedora 45.

The same checks passed on an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, both with 1 vCPU and 1 GB of memory. After a reboot each came back sealed, unsealed with the key from the file, still had the secret, and the plan had no changes. On Rocky Linux OpenBao runs as `unconfined_service_t`, and the audit log had no denials. On the Ubuntu droplet, a switch to `listen_address = "0.0.0.0"` with a self-signed certificate answered from another machine over HTTPS, checked with `curl --cacert`.

## License

MPL-2.0. See [LICENSE](LICENSE). OpenBao itself is MPL-2.0.
