provider "aws" {
	access_key = "${var.aws_access_key}"
	secret_key = "${var.aws_secret_key}"
	region = "${var.aws_region}"
}

module "vpc" {
  source = "github.com/cloudfoundry-community/terraform-aws-vpc"
  network = "${var.network}"
  aws_key_name = "${var.aws_key_name}"
  aws_access_key = "${var.aws_access_key}"
  aws_secret_key = "${var.aws_secret_key}"
  aws_region = "${var.aws_region}"
  aws_key_path = "${var.aws_key_path}"
}

output "aws_vpc_id" {
  value = "${module.vpc.aws_vpc_id}"
}

output "aws_internet_gateway_id" {
  value = "${module.vpc.aws_internet_gateway_id}"
}

output "aws_route_table_public_id" {
  value = "${module.vpc.aws_route_table_public_id}"
}

output "aws_route_table_private_id" {
  value = "${module.vpc.aws_route_table_private_id}"
}

output "aws_subnet_bastion" {
  value = "${module.vpc.bastion_subnet}"
}

output "aws_subnet_bastion_availability_zone" {
  value = "${module.vpc.aws_subnet_bastion_availability_zone}"
}

output "cf_admin_pass" {
  value = "${var.cf_admin_pass}"
}

output "aws_key_path" {
  value = "${var.aws_key_path}"
}

module "cf-net" {
  source = "github.com/cloudfoundry-community/terraform-aws-cf-net"
  network = "${var.network}"
  aws_key_name = "${var.aws_key_name}"
  aws_access_key = "${var.aws_access_key}"
  aws_secret_key = "${var.aws_secret_key}"
  aws_region = "${var.aws_region}"
  aws_key_path = "${var.aws_key_path}"
  aws_vpc_id = "${module.vpc.aws_vpc_id}"
  aws_internet_gateway_id = "${module.vpc.aws_internet_gateway_id}"
  aws_route_table_public_id = "${module.vpc.aws_route_table_public_id}"
  aws_route_table_private_id = "${module.vpc.aws_route_table_private_id}"
  aws_subnet_cfruntime-2a_availability_zone = "${lookup(var.cf1_az, var.aws_region)}"
  aws_subnet_cfruntime-2b_availability_zone = "${lookup(var.cf2_az, var.aws_region)}"
}

output "cf_api" {
	value = "api.run.${module.cf-net.aws_eip_cf_public_ip}.xip.io"
}

output "aws_subnet_docker_id" {
  value = "${module.cf-net.aws_subnet_docker_id}"
}

resource "aws_instance" "bastion" {
  ami = "${lookup(var.aws_ubuntu_ami, var.aws_region)}"
  instance_type = "m3.medium"
  key_name = "${var.aws_key_name}"
  associate_public_ip_address = true
  security_groups = ["${module.vpc.aws_security_group_bastion_id}"]
  subnet_id = "${module.vpc.bastion_subnet}"
  ebs_block_device {
    device_name = "xvdc"
    volume_size = "40"
  }

  tags {
   Name = "bastion"
  }

}

output "bastion_ip" {
  value = "${aws_instance.bastion.public_ip}"
}

output "cf_domain" {
  value = "${var.cf_domain}"
}

output "run_subdomain" {
  value = "${var.run_subdomain}"
}

output "apps_subdomain" {
  value = "${var.apps_subdomain}"
}

resource "aws_security_group_rule" "nat" {
	source_security_group_id = "${module.cf-net.aws_security_group_cf_id}"

	security_group_id = "${module.vpc.aws_security_group_nat_id}"
	from_port = -1
	to_port = -1
	protocol = "-1"
	type = "ingress"
}

output "aws_access_key" {
	value = "${var.aws_access_key}"
}

output "aws_secret_key" {
	value = "${var.aws_secret_key}"
}

output "aws_region" {
	value = "${var.aws_region}"
}

output "bosh_subnet" {
  value = "${module.vpc.aws_subnet_microbosh_id}"
}

output "ipmask" {
	value = "${var.network}"
}

output "cf_api_id" {
	value = "${module.cf-net.aws_eip_cf_public_ip}"
}

output "cf_subnet1" {
  value = "${module.cf-net.aws_subnet_cfruntime-2a_id}"
}

output "cf_subnet1_az" {
	value = "${module.cf-net.aws_subnet_cfruntime-2a_availability_zone}"
}

output "cf_subnet2" {
	value = "${module.cf-net.aws_subnet_cfruntime-2b_id}"
}

output "cf_subnet2_az" {
	value = "${module.cf-net.aws_subnet_cfruntime-2b_availability_zone}"
}

output "bastion_az" {
	value = "${aws_instance.bastion.availability_zone}"
}

output "bastion_id" {
	value = "${aws_instance.bastion.id}"
}

output "lb_subnet1" {
	value = "${module.cf-net.aws_subnet_lb_id}"
}

output "cf_sg" {
	value = "${module.cf-net.aws_security_group_cf_name}"
}

output "cf_sg_id" {
	value = "${module.cf-net.aws_security_group_cf_id}"
}

output "cf_boshworkspace_version" {
	value = "${var.cf_boshworkspace_version}"
}

output "cf_size" {
	value = "${var.cf_size}"
}

output "docker_subnet" {
	value = "${module.cf-net.aws_subnet_docker_id}"
}

output "install_docker_services" {
	value = "${var.install_docker_services}"
}

output "cf_release_version" {
	value = "${var.cf_release_version}"
}

output "debug" {
	value = "${var.debug}"
}

output "backbone_z1_count" { value = "${lookup(var.backbone_z1_count, var.deployment_size)}" }
output "api_z1_count"      { value = "${lookup(var.api_z1_count,      var.deployment_size)}" }
output "services_z1_count" { value = "${lookup(var.services_z1_count, var.deployment_size)}" }
output "health_z1_count"   { value = "${lookup(var.health_z1_count,   var.deployment_size)}" }
output "runner_z1_count"   { value = "${lookup(var.runner_z1_count,   var.deployment_size)}" }
output "backbone_z2_count" { value = "${lookup(var.backbone_z2_count, var.deployment_size)}" }
output "api_z2_count"      { value = "${lookup(var.api_z2_count,      var.deployment_size)}" }
output "services_z2_count" { value = "${lookup(var.services_z2_count, var.deployment_size)}" }
output "health_z2_count"   { value = "${lookup(var.health_z2_count,   var.deployment_size)}" }
output "runner_z2_count"   { value = "${lookup(var.runner_z2_count,   var.deployment_size)}" }

output "private_cf_domains" {
	value = "${var.private_cf_domains}"
}

output "additional_cf_sg_allows" {
  value = "${var.additional_cf_sg_allow_1},${var.additional_cf_sg_allow_2},${var.additional_cf_sg_allow_3},${var.additional_cf_sg_allow_4},${var.additional_cf_sg_allow_5},${module.cf-net.aws_cf_a_cidr},${module.cf-net.aws_cf_b_cidr},${module.cf-net.aws_lb_cidr},${module.cf-net.aws_docker_cidr},${module.cf-net.aws_eip_cf_public_ip}"
}

output "backbone_resource_pool"        { value = "${var.backbone_resource_pool}" }
output "data_resource_pool"            { value = "${var.data_resource_pool}" }
output "public_haproxy_resource_pool"  { value = "${var.public_haproxy_resource_pool}" }
output "private_haproxy_resource_pool" { value = "${var.private_haproxy_resource_pool}" }
output "api_resource_pool"             { value = "${var.api_resource_pool}" }
output "services_resource_pool"        { value = "${var.services_resource_pool}" }
output "health_resource_pool"          { value = "${var.health_resource_pool}" }
output "runner_resource_pool"          { value = "${var.runner_resource_pool}" }
