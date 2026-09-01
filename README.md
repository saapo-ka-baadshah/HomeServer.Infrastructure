# HomeServer Infrastructure

Infrastructure-as-Code for a home server using [Proxmox VE](https://www.proxmox.com/) and [Terraform](https://www.terraform.io/). Provisions virtual machines from a cloud-init template, intended to host a Kubernetes cluster.

## Architecture

- **Provider**: [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox) (`~> 0.11`)
- **Module**: [`modules/kube`](./modules/kube) — clones a cloud-init VM template and applies CPU, memory, disk, network, and user configuration
- **Orchestration**: [`main.tf`](./main.tf) loops over the `kube_vms` variable to create one VM per entry

Each VM is configured with:

- Full clone of an existing cloud-init template
- Host-type CPU with configurable cores
- Configurable memory and disk (with discard)
- VirtIO network device on a configurable bridge
- Static IP + gateway, or DHCP when no IP is given
- SSH keys and username injected via cloud-init

## Requirements

- Terraform `>= 1.5.0`
- Proxmox VE node with a prepared cloud-init template (see [Prerequisites](#prerequisites))

## Usage

### 1. Prerequisites

Create a Proxmox API token with permission to create VMs:

1. In the Proxmox web UI go to **Datacenter → Permissions → API Tokens**.
2. Add a token for a user in the format `user@realm!tokenid`.
3. Grant it the appropriate VM and pool permissions.

The token's user must also hold `VM.GuestAgent.Audit` (or `VM.GuestAgent.Unrestricted`) on the VMs. Because the module enables the QEMU guest agent, the provider queries agent-reported network interfaces after creating a VM — without this privilege Proxmox returns `HTTP 403 Permission check failed (/vms/<id>, VM.GuestAgent.Audit|VM.GuestAgent.Unrestricted)`. From the CLI:

```sh
pveum role modify <role> -privs "<existing privs>,VM.GuestAgent.Audit,VM.GuestAgent.Unrestricted"
pveum aclmod / -user <user@realm> -role <role>
pveum user permissions <user@realm>
```

If the token is privilege-separated (`--privsep 1`), grant the privilege to the token's own ACL as well. Grant it on `/` (or the pool covering the VMs) so it applies to newly created VMs too.

Prepare a cloud-init ready VM template (e.g. Ubuntu Cloud Image). Record its VM ID (e.g. `900`) and use it as `template_vm_id`.

#### SSH access (for cloud-init snippet uploads)

The `proxmox_virtual_environment_file` resource uploads cloud-init snippets over SSH from the machine running Terraform to the Proxmox node as `root`:

1. Enable the `snippets` content type on the `local` storage (Datacenter → Storage → local → Edit → Content → **Snippets**), or equivalent:
   ```sh
   mkdir -p /var/lib/vz/snippets
   pvesm set local --content backup,import,iso,vztmpl,snippets
   ```
2. Generate an SSH key on the machine that runs Terraform (for this repo: the self-hosted GitHub Actions runner) and authorize it for `root` on the host:
   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
   ssh-keyscan -H <proxmox-node-ip> >> ~/.ssh/known_hosts
   ```
   Then, as `root` on the host:
   ```sh
   mkdir -p /root/.ssh
   echo "<pubkey from ~/.ssh/id_ed25519.pub>" >> /root/.ssh/authorized_keys
   chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
   ```
3. Verify password-less login works from the Terraform machine:
   ```sh
   ssh root@<proxmox-node-ip> 'pvesm apiinfo'   # prints "APIVER ..." with no prompt
   ```

The GitHub Actions workflow loads `~/.ssh/id_ed25519` into ssh-agent on the runner and sets `proxmox_ssh_username = "root"`.

### 2. Configure variables

Copy the example and fill in your values:

```sh
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your Proxmox endpoint, API token, and desired VMs.

### 3. Initialize and apply

```sh
terraform init
terraform plan
terraform apply
```

## Development Setup
The development setup is designed around nvim and tmux usage.
We use the ruby gem called `tmuxinator`. 
This allows us to securely maintain a specific set of tmux windows and panes in the development environment.

### Installation for `tmuxinator`
```shell
gem install tmuxinator
rbenv rehash
```

### How to start the project with `tmuxinator`?
```shell
tmuxinator start
```

### How to stop the project with `tmuxinator`?
```shell
tmuxinator stop
```

## Variables

| Variable           | Type          | Default       | Description                                  |
| ------------------ | ------------- | ------------- | -------------------------------------------- |
| `proxmox_endpoint` | `string`      | —             | Proxmox API endpoint (e.g. `https://192.168.1.10:8006/`) |
| `proxmox_api_token` | `string`     | —             | API token in the form `user@realm!tokenid=secret` |
| `proxmox_insecure` | `bool`        | `true`        | Skip TLS verification (true for self-signed certs) |
| `proxmox_ssh_agent` | `bool`       | `true`        | Use the SSH agent for snippet/cloud-init uploads  |
| `proxmox_ssh_username` | `string`   | `"root"`      | SSH user on the node for snippet uploads          |
| `proxmox_ssh_private_key` | `string` | `null`       | SSH private key (PEM) for snippet uploads; overrides the agent's key |
| `default_node`     | `string`      | `"pve"`       | Default Proxmox node name                   |
| `kube_vms`         | `map(object)` | —             | Map of VMs to create (see below)            |

### `kube_vms` object attributes

| Attribute        | Type             | Default              | Description                              |
| ---------------- | ---------------- | -------------------- | ---------------------------------------- |
| `name`           | `string`         | —                    | VM name                                  |
| `node_name`      | `string`         | `default_node`       | Proxmox node to create the VM on         |
| `vm_id`          | `number`         | `null`               | Optional explicit VM ID                  |
| `template_vm_id` | `number`         | —                    | VM ID of the cloud-init template to clone |
| `cores`          | `number`         | `2`                  | Number of CPU cores                      |
| `memory`         | `number`         | `4096`               | Memory in MiB                            |
| `disk_size`      | `number`         | `32`                 | Disk size in GiB                         |
| `datastore_id`   | `string`         | `"local-lvm"`        | Datastore for the disk                   |
| `meta_datastore_id` | `string`       | `"local"`            | Datastore for cloud-init snippets (must support `snippets` content) |
| `bridge`         | `string`         | `"vmbr0"`            | Network bridge                           |
| `ip_address`     | `string`         | `null`               | Static IP (e.g. `10.0.10.51/24`) or `null` for DHCP |
| `gateway`        | `string`         | `null`               | Network gateway for static IP            |
| `second_bridge`  | `string`         | `null`               | Optional secondary bridge (e.g. `vmbr0` for internet) |
| `second_ip_address` | `string`      | `"dhcp"`             | IP for the secondary NIC; `dhcp` or `192.168.178.x/24` |
| `username`       | `string`         | `"ubuntu"`           | Default user created via cloud-init      |
| `ssh_keys`       | `list(string)`   | `[]`                 | SSH public keys to inject               |
| `tags`           | `list(string)`   | `["terraform"]`      | VM tags                                 |

## Example

```hcl
kube_vms = {
  web01 = {
    name           = "web-01"
    template_vm_id = 900
    cores          = 2
    memory         = 4096
    disk_size      = 40
    ip_address     = "10.0.10.51/24"
    gateway        = "10.0.10.1"
    username       = "ubuntu"
    ssh_keys       = ["ssh-ed25519 AAAA... your-key"]
    tags           = ["web", "terraform"]
  }

  db01 = {
    name           = "db-01"
    template_vm_id = 900
    cores          = 4
    memory         = 8192
    disk_size      = 80
    # No ip_address = DHCP
    username       = "ubuntu"
    ssh_keys       = ["ssh-ed25519 AAAA... your-key"]
    tags           = ["db", "terraform"]
  }
}
```

## Outputs

The `modules/kube` module exposes `vm_id`, `name`, and `node_name` for each provisioned VM.

## Notes

- `proxmox_insecure` defaults to `true` because home servers commonly use self-signed certificates. Only set it to `false` with a valid CA.
- `terraform.tfvars` is gitignored; only `terraform.tfvars.example` is committed.
- The `lifecycle.ignore_changes` block in the module is preconfigured so you can keep tweaking a VM in the Proxmox GUI without Terraform reverting it.
- `clone` is included in `lifecycle.ignore_changes` so an imported VM is adopted rather than re-cloned (the `clone` attribute is not returned by the Proxmox API, so without this Terraform would try to clone again over an existing VM).

### State

Terraform state is **local to the self-hosted runner** and is the single source of truth for existing resources. Without it every CI run starts from empty state and Terraform cannot know a VM already exists — this is what causes the `config file already exists` clone errors.

- The workflow stores state at `$HOME/tf-state/homeserver-infra.tfstate` on the runner and points the backend at it via:
  ```sh
  terraform init -input=false -reconfigure \
    -backend-config="path=$HOME/tf-state/homeserver-infra.tfstate"
  ```
- The workflow also imports any VM that exists on the Proxmox host but is missing from state (drift reconciliation) before planning.
- To work on the state from another machine, run `terraform init` with the same `-backend-config` against the same path, or apply via CI only. Never apply twice against different state files for the same hosts.
- If you delete state, existing VMs are orphaned again — re-run the import (or `terraform import module.kube["<name>"].proxmox_virtual_environment_vm.this[<n>] <node>/<vmid>`) before planning.

## Changelog

- Kubernetes version updates require a full `terraform destroy` before reapplying. Terraform does not track in-place Kubernetes version changes on existing VMs, so skipping destroy can leave the cluster running an older version while Terraform believes the update has been applied. Always run:

  ```sh
  terraform destroy
  terraform apply
  ```

  before bumping the Kubernetes version in your configuration.

## License

[Apache-2.0](./LICENSE)
