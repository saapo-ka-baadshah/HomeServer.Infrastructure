# download image for kube module
resource "proxmox_download_file" "kube_module_img" {
  content_type = "import"
  datastore_id = "local"
  node_name    = var.default_node
  url          = var.img_download_url
  file_name    = "jammy-server-cloudimg-amd64.qcow2"
}

resource "proxmox_network_linux_bridge" "kube_bridge" {
  node_name = var.default_node
  name      = var.kube_bridge_name
  # Host-side address on the bridge: first usable IP of the management subnet.
  # This makes the Proxmox host the internal gateway for the K8s nodes so all
  # cluster communication stays on 10.200.0.0/24 (no home-router hop).
  address   = "${cidrhost(var.kube_mgmt_subnet, 1)}/${element(split("/", var.kube_mgmt_subnet), 1)}"
  comment   = "Dedicated Kubernetes management bridge"
  autostart = true
}

module "kube" {
  source   = "./modules/kube"
  for_each = var.kube_vms

  depends_on = [proxmox_network_linux_bridge.kube_bridge]

  name              = each.value.name
  description       = each.value.description
  resource_count    = each.value.resource_count
  import_file_id    = proxmox_download_file.kube_module_img.id
  node_name         = coalesce(each.value.node_name, var.default_node)
  vm_id             = each.value.vm_id
  template_vm_id    = each.value.template_vm_id
  cores             = each.value.cores
  memory            = each.value.memory
  disk_size         = each.value.disk_size
  datastore_id      = each.value.datastore_id
  meta_datastore_id = each.value.meta_datastore_id
  bridge            = each.value.bridge
  ip_address        = each.value.ip_address
  gateway           = each.value.gateway
  second_bridge     = each.value.second_bridge
  second_ip_address = each.value.second_ip_address
  username          = each.value.username
  ssh_keys          = each.value.ssh_keys
  tags              = each.value.tags
  hostname          = each.value.hostname
}
