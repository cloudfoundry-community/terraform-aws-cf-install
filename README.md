terraform-aws-cf-install [![Build Status](https://travis-ci.org/cloudfoundry-community/terraform-aws-cf-install.svg?branch=master)](https://travis-ci.org/cloudfoundry-community/terraform-aws-cf-install)
========================

THIS PROJECT IS NOT LONGER MAINTAINED. USE AT YOUR OWN RISK!

This is part of a project that aims to create a one click deploy of Cloud Foundry into an AWS VPC. This is (probably) the repo you want to use.

Architecture
------------

This terraform project will deploy one of the following networking and instances (pretty diagrams from [VisualOps IDE](https://ide.visualops.io)):

### CF AWS Tiny

![cf-aws-tiny.png](http://cl.ly/image/232j3o2A1X2o/cf-tiny-deployment.png)

### CF AWS Large

![cf-aws-large.png](http://i.imgur.com/2zeEqEm.png)

We rely on two other repositories to do the bulk of the work. The [terraform-aws-vpc](https://github.com/cloudfoundry-community/terraform-aws-vpc) repo creates the base VPC infrastructure, including a bastion subnet, the`microbosh` subnet, a NAT server, various route tables, and the VPC itself. Then the [terraform-aws-cf-net](https://github.com/cloudfoundry-community/terraform-aws-cf-net) repo creates a loadbalancer subnet, two runtime subnets, `cf` related security groups, and the elastic IP used by `cf`. This gives us the flexibility to use the`terraform-aws-cf-net` module multiple times, to have a staging and production cf within the same VPC, sharing a single microbosh instance.

Upstream Terraform issues
-------------------------

During the development of this project (including the modules above) we have discovered some terraform bugs, some things we've worked around, and some issues that would be nice to implement (removed once resolved).

- [![hashicorp/terraform/issues/776](https://github-shields.com/github/hashicorp/terraform/issues/776.svg)](https://github-shields.com/github/hashicorp/terraform/issues/776) - currently, both the released version of terraform and HEAD does not work with our configs. You must compile and use https://github.com/hashicorp/terraform/commit/fd6382fbafe0be8547eabbb279bbb6f095c87096 in order for this to work.
-	[![hashicorp/terraform/issues/745](https://github-shields.com/github/hashicorp/terraform/issues/745.svg)](https://github-shields.com/github/hashicorp/terraform/issues/745) - currently we can only bootstrap BOSH and Cloud Foundry inside the "resource" for creation of the bastian VM. We'd like to reuse the bastian VM and allow these terraform projects be more modular.

Upstream Cloud Foundry issues
-----------------------------

Issues/Pull Requests pending across Cloud Foundry projects:

-	[![cloudfoundry/cf-release/pull/592](https://github-shields.com/github/cloudfoundry/cf-release/pull/592.svg)](https://github-shields.com/github/cloudfoundry/cf-release/pull/592) - there is no need to pre-provision a blank VM to run errands

Deploy Cloud Foundry
--------------------

### Prerequisites

The one step that isn't automated is the creation of SSH keys. We are waiting for that feature to be [added to terraform](https://github.com/hashicorp/terraform/issues/28). An AWS SSH Key need to be created in desired region prior to running the following commands. Note the name of the key and the path to the pem/private key file for use further down.

You **must** being using at least terraform version 0.5.0.

```
$ terraform -v
Terraform v0.5.0
```

You can install terraform 0.5.0+ via [https://www.terraform.io/downloads.html]

Your chosen AWS Region must have sufficient quota to spin up **all** of the machines. While building various bits, the install process can use up to 13 VMs, settling down to use 7 machines long-term (more, if you want more runners).

Optionally for using the `Unattended Install` instruction, install git.

#### NOTE: Building the entire Cloud Foundry cluster will take a little over an hour! It hasn't hung (probably), it just takes a little while to do ALL THE THINGS.

### Easy install

```bash
mkdir terraform-aws-cf-install
cd terraform-aws-cf-install
terraform apply github.com/cloudfoundry-community/terraform-aws-cf-install
```

### Unattended install

```bash
git clone https://github.com/cloudfoundry-community/terraform-aws-cf-install
cd terraform-aws-cf-install
cp terraform.tfvars.example terraform.tfvars
```

Next, edit `terraform.tfvars` using your text editor and fill out the variables with your own values (AWS credentials, AWS region, etc).

Run the following to create the networking, subnets, security groups, ports and create a bastion server:

```bash
make plan
make apply
```

Once the bastion server is created, run the following to create a provision script with all the variables assigned, copy the script to the Bastion server then remotely execute the script.  This allows the script to be executed multiple times, as needed, without needing to destroy the Bastion server.

```bash
make provision
```

If the provision script fails, run `make provision` again from your laptop.  If you want someone to help you, a full copy of the provision script is also on the Bastion server at `/home/ubuntu/provision.sh`

After Initial Install
---------------------

At the end of the output of the terraform run, there will be a section called `Outputs` that will have at least `bastion_ip` and an IP address. If not, or if you cleared the terminal without noting it, you can log into the AWS console and look for an instance called 'bastion', with the `bastion` security group. Use the public IP associated with that instance, and ssh in as the ubuntu user, using the ssh key listed as `aws_key_path` in your configuration (if you used the Unattended Install).

```
ssh -i ~/.ssh/example.pem ubuntu@$(terraform output bastion_ip)
```

As an alternative there is a script provided for you which will execute ssh with all the necessary parameters.  From the root of the project folder run

```
make ssh
```

Once in, you can look in `workspace/deployments/cf-boshworkspace/` for the bosh deployment manifest and template files. Any further updates or changes to your microbosh or Cloud Foundry environment will be done manually using this machine as your work space. Terraform provisioning scripts are not intended for long-term updates or maintenance.

Cloud Foundry
-------------

To login to Cloud Foundry as an administrator:

```
cf login --skip-ssl-validation -a $(terraform output cf_api) -u admin -p $(terraform output cf_admin_pass)
```

You can also log into the cf api from the inception server itself, though you have to manually replace the calls to terraform from above with the actual values.

Cleanup / Tear down
-------------------

Terraform does not yet quite cleanup after itself. You can run `make destroy` to get quite a few of the resources you created, but you will probably have to manually track down some of the bits and manually remove them. Once you have done so, run `make clean` to remove the local cache and status files, allowing you to run everything again without errors.

Module Outputs
--------------

If you wish to use this module in conjunction with `terraform-aws-cf-net` to create more than one `cf` instance in a single VPC, that is fully supported. First, uncomment the `output` for the following variables in aws-cf-install.tf. They are suitable to be used as variable inputs to the `terraform-aws-cf-net` module:

```
aws_vpc_id
aws_internet_gateway_id
aws_route_table_public_id
aws_route_table_private_id
aws_subnet_bastion_availability_zone
```

### Configuration

Look in `variables.tf` to see all of the variables that can be set or overriden. The mandatory variables are:

```
source = "github.com/cloudfoundry-community/terraform-aws-cf-install" # Or your own source, if you fork the repo
aws_access_key = "${var.aws_access_key}" # Provided by Amazon
aws_secret_key = "${var.aws_secret_key}" # Provided by Amazon
aws_key_name = "${var.aws_key_name}" # The "name" of the ssh key to use in the AWS Console under EC2 -> Network & Security -> Key Pairs
aws_key_path = "${var.aws_key_path}" # Literal path to pem file on the computer running Terraform - /home/user/keys/exapmle.pem
network = "${var.network}" # The first two octects to use within the VPC, e.g. 10.0 or 10.55
```

### Example usage

Note that this does not actually create the second `cf` instance, that has to be done manually. You should be able to take the resources created by the `cf-staging` module, copy the cf-boshbootstrap directory on the bastion server, and search and replace with the new values. Also, you can set the `offset` value to whatever you want, from 1 to 24.

```
provider "aws" {
  access_key = "${var.aws_access_key}"
  secret_key = "${var.aws_secret_key}"
  region = "${var.aws_region}"
}

module "cf-install" {
  source = "github.com/cloudfoundry-community/terraform-aws-cf-install"
  network = "${var.network}"
  aws_key_name = "${var.aws_key_name}"
  aws_access_key = "${var.aws_access_key}"
  aws_secret_key = "${var.aws_secret_key}"
  aws_region = "${var.aws_region}"
  aws_key_path = "${var.aws_key_path}"
  cf_install = "prod.mycloudfoundry.domain"
}

module "cf-staging" {
  source = "github.com/cloudfoundry-community/terraform-aws-cf-net"
  network = "${var.network}"
  aws_key_name = "${var.aws_key_name}"
  aws_access_key = "${var.aws_access_key}"
  aws_secret_key = "${var.aws_secret_key}"
  aws_region = "${var.aws_region}"
  aws_key_path = "${var.aws_key_path}"
  aws_vpc_id = "${module.cf-install.aws_vpc_id}"
  aws_internet_gateway_id = "${module.cf-install.aws_internet_gateway_id}"
  aws_route_table_public_id = "${module.cf-install.aws_route_table_public_id}"
  aws_route_table_private_id = "${module.cf-install.aws_route_table_private_id}"
  aws_subnet_lb_availability_zone = "${module.cf-install.aws_subnet_bastion_availability_zone}"
  offset = "20"
  cf_install = "staging.mycloudfoundry.domain"
}
```

Installing Sample Docker Services
---------------------------------

If you would like sample services like PostgreSQL, MySQL, Rabbit MQ, Mongo, etcd, consul (and others) there is a github repo that you can clone on the Bastion server or there is a flag you can set in your `terraform.tfvars` for this project which will install these services after Cloud Foundry is installed.

To enable these services to be installed automatically, add the following line to `terraform.tfvars`:

```
install_docker_services = "true"
```

There is already a subnet defined in `aws-cf-install.tf` where this server will be created.
