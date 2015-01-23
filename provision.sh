#!/bin/bash

# fail immediately on error
set -e

# Variables passed in from terraform, see aws-vpc.tf, the "remote-exec" provisioner
AWS_KEY_ID=${1}
AWS_ACCESS_KEY=${2}
REGION=${3}
VPC=${4}
BOSH_SUBNET=${5}
IPMASK=${6}
CF_IP=${7}
CF_SUBNET1=${8}
CF_SUBNET1_AZ=${9}
CF_SUBNET2=${10}
CF_SUBNET2_AZ=${11}
BASTION_AZ=${12}
BASTION_ID=${13}
LB_SUBNET1=${14}
LB_SUBNET1_AZ=${15}
CF_SG=${16}
CF_ADMIN_PASS=${17}
CF_DOMAIN=${18}

# Prepare the jumpbox to be able to install ruby and git-based bosh and cf repos
cd $HOME

sudo apt-get update
sudo apt-get install -y git vim-nox unzip

# Generate the key that will be used to ssh between the bastion and the
# microbosh machine
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

# Install BOSH CLI, bosh-bootstrap, spiff and other helpful plugins/tools

set +e # ignore the errors from the bad HTML errors from downloading
curl -s https://raw.githubusercontent.com/cloudfoundry-community/traveling-bosh/master/scripts/installer | sudo bash
set -e
export PATH=$PATH:/usr/bin/traveling-bosh

# We use fog below, and bosh-bootstrap uses it as well
cat <<EOF > ~/.fog
:default:
  :aws_access_key_id: $AWS_KEY_ID
  :aws_secret_access_key: $AWS_ACCESS_KEY
  :region: $REGION
EOF

# This volume is created using terraform in aws-bosh.tf
sudo /sbin/mkfs.ext4 /dev/xvdc
sudo /sbin/e2label /dev/xvdc workspace
echo 'LABEL=workspace /home/ubuntu/workspace ext4 defaults,discard 0 0' | sudo tee -a /etc/fstab
mkdir -p /home/ubuntu/workspace
sudo mount -a
sudo chown -R ubuntu:ubuntu /home/ubuntu/workspace

# As long as we have a large volume to work with, we'll move /tmp over there
# You can always use a bigger /tmp
sudo rsync -avq /tmp/ /home/ubuntu/workspace/tmp/
sudo rm -fR /tmp
sudo ln -s /home/ubuntu/workspace/tmp /tmp

# bosh-bootstrap handles provisioning the microbosh machine and installing bosh
# on it. This is very nice of bosh-bootstrap. Everyone make sure to thank bosh-bootstrap
mkdir -p {bin,workspace/deployments/microbosh,workspace/tools}
pushd workspace/deployments
pushd microbosh
cat <<EOF > settings.yml
---
bosh:
  name: bosh-${VPC}
provider:
  name: aws
  credentials:
    provider: AWS
    aws_access_key_id: ${AWS_KEY_ID}
    aws_secret_access_key: ${AWS_ACCESS_KEY}
  region: ${REGION}
address:
  vpc_id: ${VPC}
  subnet_id: ${BOSH_SUBNET}
  ip: ${IPMASK}.1.4
EOF

bosh bootstrap deploy

# We've hardcoded the IP of the microbosh machine, because convenience
bosh -n target https://${IPMASK}.1.4:25555
bosh login admin admin
popd

# There is a specific branch of cf-boshworkspace that we use for terraform. This
# may change in the future if we come up with a better way to handle maintaining
# configs in a git repo
git clone http://github.com/cloudfoundry-community/cf-boshworkspace
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
/bin/sed -i "s/CF_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/CF_SUBNET2_AZ/${CF_SUBNET2_AZ}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/LB_SUBNET1_AZ/${LB_SUBNET1_AZ}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/CF_ELASTIC_IP/${CF_IP}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/CF_SUBNET1/${CF_SUBNET1}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/CF_SUBNET2/${CF_SUBNET2}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/LB_SUBNET1/${LB_SUBNET1}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/DIRECTOR_UUID/${DIRECTOR_UUID}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/CF_DOMAIN/${CF_DOMAIN}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/CF_ADMIN_PASS/${CF_ADMIN_PASS}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/IPMASK/${IPMASK}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/CF_SG/${CF_SG}/g" deployments/cf-aws-tiny.yml
/bin/sed -i "s/LB_SUBNET1_AZ/${LB_SUBNET1_AZ}/g" deployments/cf-aws-tiny.yml

# Upload the bosh release, set the deployment, and execute
bosh upload release https://community-shared-boshreleases.s3.amazonaws.com/boshrelease-cf-194.tgz
bosh deployment cf-aws-tiny
bosh prepare deployment

# We locally commit the changes to the repo, so that errant git checkouts don't
# cause havok
git commit -am 'commit of the local deployment configs'

# Speaking of hack-work, bosh deploy often fails the first or even second time, due to packet bats
# We run it three times (it's idempotent) so that you don't have to
bosh -n deploy
bosh -n deploy
bosh -n deploy

# FIXME: enable this again when smoke_tests work
# bosh run errand smoke_tests
