proxmox_insecure = true
default_node     = "pve"

kube_vms = {
  kube-ctrl = {
    name              = "kube-ctrl"
    description       = "Kubernetes control plane managed by Terraform"
    resource_count    = 1
    template_vm_id    = 900
    vm_id             = 1001
    cores             = 3
    memory            = 5192
    disk_size         = 32
    bridge            = "vmbr1"
    ip_address        = "10.200.0.200/24"
    gateway           = "10.200.0.1"
    second_bridge     = "vmbr0"
    second_ip_address = "192.168.178.200/24"
    username          = "ubuntu"
    tags              = ["k8s", "terraform"]
    hostname          = "machine"
  }

  kube-worker-0 = {
    name              = "kube-worker-0"
    description       = "Kubernetes worker node 0 managed by Terraform"
    resource_count    = 1
    template_vm_id    = 900
    vm_id             = 1002
    cores             = 3
    memory            = 5192
    disk_size         = 32
    bridge            = "vmbr1"
    ip_address        = "10.200.0.201/24"
    gateway           = "10.200.0.1"
    second_bridge     = "vmbr0"
    second_ip_address = "192.168.178.201/24"
    username          = "ubuntu"
    tags              = ["k8s", "terraform"]
    hostname          = "machine"
  }
}
