#!/bin/bash

# fail immediately on error
set -e

# Variables passed in from terraform, see aws-vpc.tf, the "remote-exec" provisioner

OS_USERNAME=${1}
OS_API_KEY=${2}
OS_TENANT=${3}
OS_AUTH_URL=${4}
OS_REGION=${5}
CF_SUBNET1=${6}
IPMASK=${7}
CF_IP=${8}
CF_SIZE=${9}
CF_BOSHWORKSPACE_VERSION=${10}
CF_DOMAIN=${11}

# Prepare the jumpbox to be able to install ruby and git-based bosh and cf repos
cd $HOME

sudo apt-get update
sudo apt-get install -y git vim-nox unzip tree

# Generate the key that will be used to ssh between the bastion and the
# microbosh machine
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

# Install BOSH CLI, bosh-bootstrap, spiff and other helpful plugins/tools

set +e # ignore the errors from the bad HTML errors from downloading
curl -s https://raw.githubusercontent.com/cloudfoundry-community/traveling-bosh/master/scripts/installer | sudo bash
set -e
export PATH=$PATH:/usr/bin/traveling-bosh

# This volume is created using terraform in aws-bosh.tf
#sudo /sbin/mkfs.ext4 /dev/xvdc
#sudo /sbin/e2label /dev/xvdc workspace
#echo 'LABEL=workspace /home/ubuntu/workspace ext4 defaults,discard 0 0' | sudo tee -a /etc/fstab
#mkdir -p /home/ubuntu/workspace
#sudo mount -a
#sudo chown -R ubuntu:ubuntu /home/ubuntu/workspace

# As long as we have a large volume to work with, we'll move /tmp over there
# You can always use a bigger /tmp
#sudo rsync -avq /tmp/ /home/ubuntu/workspace/tmp/
#sudo rm -fR /tmp
#sudo ln -s /home/ubuntu/workspace/tmp /tmp

# bosh-bootstrap handles provisioning the microbosh machine and installing bosh
# on it. This is very nice of bosh-bootstrap. Everyone make sure to thank bosh-bootstrap
mkdir -p {bin,workspace/deployments/microbosh,workspace/tools}
pushd workspace/deployments
pushd microbosh
cat <<EOF > settings.yml
---
bosh:
  name: firstbosh
provider:
  name: openstack
  credentials:
    openstack_username: ${OS_USERNAME}
    openstack_api_key: ${OS_API_KEY}
    openstack_tenant: ${OS_TENANT}
    openstack_auth_url: ${OS_AUTH_URL}
    openstack_region: ${OS_REGION}
  options:
    boot_from_volume: false
address:
  subnet_id: ${CF_SUBNET1}
  ip: ${IPMASK}.2.4
EOF

bosh bootstrap deploy

# We've hardcoded the IP of the microbosh machine, because convenience
bosh -n target https://${IPMASK}.2.4:25555
bosh login admin admin
popd

# There is a specific branch of cf-boshworkspace that we use for terraform. This
# may change in the future if we come up with a better way to handle maintaining
# configs in a git repo
git clone --branch  ${CF_BOSHWORKSPACE_VERSION} http://github.com/cloudfoundry-community/cf-boshworkspace
pushd cf-boshworkspace
mkdir -p ssh

# Pull out the UUID of the director - bosh_cli needs it in the deployment to
# know it's hitting the right microbosh instance
DIRECTOR_UUID=$(bosh status | grep UUID | awk '{print $2}')

# If CF_DOMAIN is set to XIP, then use XIP.IO. Otherwise, use the variable
if [ $CF_DOMAIN == "XIP" ]; then
  CF_DOMAIN="${CF_IP}.xip.io"
fi


# This is some hackwork to get the configs right. Could be changed in the future
/bin/sed -i "s/CF_SUBNET1/${CF_SUBNET1}/g" deployments/cf-os-tiny.yml
/bin/sed -i "s|OS_AUTHURL|${OS_AUTH_URL}|g" deployments/cf-os-tiny.yml
/bin/sed -i "s/OS_TENANT/${OS_TENANT}/g" deployments/cf-os-tiny.yml
/bin/sed -i "s/OS_APIKEY/${OS_API_KEY}/g" deployments/cf-os-tiny.yml
/bin/sed -i "s/OS_USERNAME/${OS_USERNAME}/g" deployments/cf-os-tiny.yml
/bin/sed -i "s/OS_TENANT/${OS_TENANT}/g" deployments/cf-os-tiny.yml
/bin/sed -i "s/CF_ELASTIC_IP/${CF_IP}/g" deployments/cf-os-tiny.yml
/bin/sed -i "s/CF_DOMAIN/${CF_DOMAIN}/g" deployments/cf-os-tiny.yml
/bin/sed -i "s/DIRECTOR_UUID/${DIRECTOR_UUID}/g" deployments/cf-os-tiny.yml


# Upload the bosh release, set the deployment, and execute
bosh upload release https://community-shared-boshreleases.s3.amazonaws.com/boshrelease-cf-196.tgz
bosh deployment cf-os-${CF_SIZE}
bosh prepare deployment

# We locally commit the changes to the repo, so that errant git checkouts don't
# cause havok
#git commit -am 'commit of the local deployment configs'

# Speaking of hack-work, bosh deploy often fails the first or even second time, due to packet bats
# We run it three times (it's idempotent) so that you don't have to
bosh -n deploy
bosh -n deploy
bosh -n deploy

# FIXME: enable this again when smoke_tests work
# bosh run errand smoke_tests
