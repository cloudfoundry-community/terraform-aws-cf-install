provider "openstack" {
  auth_url = "${var.auth_url}"
  tenant_name = "${var.tenant_name}"
  user_name = "${var.username}"
  password = "${var.password}"
}

resource "openstack_networking_network_v2" "internal_net" {
  region = "${var.region}"
  name = "internal-net"
  admin_state_up = "true"
  tenant_id = "${var.tenant_id}"
}

resource "openstack_networking_subnet_v2" "cf_subnet" {
  name = "cf-subnet"
  region = "${var.region}"
  network_id = "${openstack_networking_network_v2.internal_net.id}"
  cidr = "${var.network}.1.0/24"
  ip_version = 4
  tenant_id = "${var.tenant_id}"
  enable_dhcp = "true"
  dns_nameservers = ["8.8.4.4","8.8.8.8"]
}

resource "openstack_networking_router_v2" "router" {
  name = "router"
  region = "${var.region}"
  admin_state_up = "true"
  external_gateway = "${var.network_external_id}"
  tenant_id = "${var.tenant_id}"
}

resource "openstack_networking_router_interface_v2" "int-ext-interface" {
  region = "${var.region}"
  router_id = "${openstack_networking_router_v2.router.id}"
  subnet_id = "${openstack_networking_subnet_v2.cf_subnet.id}"

}
resource "openstack_compute_keypair_v2" "keypair" {
  name = "bastion-keypair-${var.tenant_name}"
  public_key = "${file(var.public_key_path)}"
  region = "${var.region}"
}

resource "openstack_compute_secgroup_v2" "bastion" {
  name = "bastion"
  description = "Bastion Security groups"
  region = "${var.region}"

  rule {
    ip_protocol = "tcp"
    from_port = "22"
    to_port = "22"
    cidr = "0.0.0.0/0"
  }

  rule {
    ip_protocol = "icmp"
    from_port = "-1"
    to_port = "-1"
    cidr = "0.0.0.0/0"
  }

}

resource "openstack_compute_secgroup_v2" "cf" {
  name = "cf"
  description = "Cloud Foundry Security groups"
  region = "${var.region}"

  rule {
    ip_protocol = "tcp"
    from_port = "22"
    to_port = "22"
    cidr = "0.0.0.0/0"
  }

  rule {
    ip_protocol = "tcp"
    from_port = "80"
    to_port = "80"
    cidr = "0.0.0.0/0"
  }

  rule {
    ip_protocol = "tcp"
    from_port = "443"
    to_port = "443"
    cidr = "0.0.0.0/0"
  }

  rule {
    ip_protocol = "tcp"
    from_port = "4443"
    to_port = "4443"
    cidr = "0.0.0.0/0"
  }

  rule {
    ip_protocol = "tcp"
    from_port = "4222"
    to_port = "25777"
    cidr = "0.0.0.0/0"
  }

  rule {
    ip_protocol = "icmp"
    from_port = "-1"
    to_port = "-1"
    cidr = "0.0.0.0/0"
  }

}

resource "openstack_networking_floatingip_v2" "cf_fp" {
  region = "${var.region}"
  pool = "${var.floating_ip_pool}"
}


resource "openstack_networking_floatingip_v2" "bastion_fp" {
  region = "${var.region}"
  pool = "${var.floating_ip_pool}"
}


resource "openstack_compute_instance_v2" "bastion" {
  name = "bastion"
  image_name = "${var.image_name}"
  flavor_name = "${var.flavor_name}"
  region = "${var.region}"
  key_pair = "${openstack_compute_keypair_v2.keypair.name}"
  security_groups = [ "${openstack_compute_secgroup_v2.bastion.name}" ]
  floating_ip = "${openstack_networking_floatingip_v2.bastion_fp.address}"

  network {
    uuid = "${openstack_networking_network_v2.internal_net.id}"
  }

  connection {
    user = "ubuntu"
    key_file = "${var.key_path}"
    host = "${openstack_networking_floatingip_v2.bastion_fp.address}"
  }

  provisioner "file" {
    source = "${path.module}/provision-os.sh"
    destination = "/home/ubuntu/provision-os.sh"
  }

  provisioner "remote-exec" {
    inline = [
        "chmod +x /home/ubuntu/provision-os.sh",
        "/home/ubuntu/provision-os.sh ${var.username} ${var.password} ${var.tenant_name} ${var.auth_url} ${var.region} ${openstack_networking_network_v2.internal_net.id} ${var.network} ${openstack_networking_floatingip_v2.cf_fp.address} ${var.cf_size} ${var.cf_boshworkspace_version} ${var.cf_domain}",
    ]
  }

}
