# Local example

Applies circuit-openbao to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

```sh
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` OpenBao is running but not initialised yet, so its health check answers `501`:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 curl -s -o /dev/null -w '%{http_code}\n' localhost:8200/v1/sys/health
```

To have the circuit initialise it, as CI does, apply with `initialize` on. The unseal key and root token land in `/root/openbao-init.json` in the container:

```sh
conn3x apply -var initialize=true
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 cat /root/openbao-init.json
```

Then unseal it inside the container with `BAO_ADDR=http://127.0.0.1:8200 bao operator unseal`.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses. The container gets `CAP_SYS_ADMIN`, which systemd needs to set up the private `/dev` in OpenBao's unit.

`./down.sh` removes the container, its volumes, the key and the state.
