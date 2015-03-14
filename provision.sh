#!/bin/bash

# fail immediately on error
set -e

echo "$0 $*" > ~/provision.log

# Variables passed in from terraform, see aws-vpc.tf, the "remote-exec" provisioner
AWS_KEY_ID="${1}"
AWS_ACCESS_KEY="${2}"
awsRegion="${3}"
awsVPCId="${4}"
awsBOSHSubnetId="${5}"
IPMask="${6}"
cfIP="${7}"
cfSubnet1="${8}"
cfSubnet1AZ="${9}"
cfSubnet2="${10}"
cfSubnet2AZ="${11}"
bastionAZ="${12}"
bastionID="${13}"
lbSubnet1="${14}"
cfSG="${15}"
cfAdminPasswd="${16}"
cfDomain="${17}"
cfBOSHWorkspaceVersion="${18}"
cfSize="${19}"

boshDirectorHost="${IPMask}.1.4"
cfReleaseVersion="203"
cfStemcell="light-bosh-stemcell-2778-aws-xen-ubuntu-trusty-go_agent.tgz"

release=$(cat /etc/*release | tr -d '\n')
case "${release}" in
  (*Ubuntu*|*Debian*)
    sudo apt-get update -yq
    sudo apt-get install -yq aptitude
    sudo aptitude -yq install build-essential vim-nox git unzip tree \
      libxslt-dev libxslt1.1 libxslt1-dev libxml2 libxml2-dev \
      libpq-dev libmysqlclient-dev libsqlite3-dev \
      g++ gcc make libc6-dev libreadline6-dev zlib1g-dev libssl-dev libyaml-dev \
      libsqlite3-dev sqlite3 autoconf libgdbm-dev libncurses5-dev automake \
      libtool bison pkg-config libffi-dev
    ;;
  (*Centos*|*RedHat*)
    sudo yum update -y
    sudo yum install -y epel-release
    sudo yum install -y git unzip xz tree rsync openssl openssl-devel \
    zlib zlib-devel libevent libevent-devel readline readline-devel cmake ntp \
    htop wget tmux gcc g++ autoconf pcre pcre-devel vim-enhanced gcc mysql-devel \
    postgresql-devel postgresql-libs sqlite-devel libxslt-devel libxml2-devel \
    yajl-ruby
    ;;
esac

cd $HOME

# Generate the key that will be used to ssh between the bastion and the
# microbosh machine
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa -C "bastion"

# Install BOSH CLI, bosh-bootstrap, spiff and other helpful plugins/tools

gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3

curl -sSL https://get.rvm.io | bash -s stable

~/.rvm/bin/rvm  --static install ruby-2.1.3

~/.rvm/bin/rvm alias create default 2.1.3

source ~/.rvm/environments/default

gem install bosh_cli bosh_cli_plugin_micro bosh_cli_plugin_aws bosh-bootstrap \
  bosh-workspace --no-ri --no-rdoc --quiet

# We use fog below, and bosh-bootstrap uses it as well
cat <<EOF > ~/.fog
:default:
  :aws_access_key_id: ${AWS_KEY_ID}
  :aws_secret_access_key: ${AWS_ACCESS_KEY}
  :region: ${awsRegion}
EOF

# This volume is created using terraform in aws-bosh.tf
sudo /sbin/mkfs.ext4 /dev/xvdc

sudo /sbin/e2label /dev/xvdc workspace

echo "LABEL=workspace ${HOME}/workspace ext4 defaults,discard 0 0" |
  sudo tee -a /etc/fstab

mkdir -p ${HOME}/workspace

sudo mount -a

sudo chown -R ubuntu:ubuntu "${HOME}/workspace"

mkdir -p "${HOME}/workspace/tmp"

# As long as we have a large volume to work with, we'll move /tmp over there
# You can always use a bigger /tmp
sudo mv /tmp /tmp.orig
sudo ln -s ${HOME}/workspace/tmp /tmp
sudo rsync -avq /tmp.orig/ ${HOME}/workspace/tmp/
sudo rm -fR /tmp.orig

# bosh-bootstrap handles provisioning the microbosh machine and installing bosh
# on it. This is very nice of bosh-bootstrap. Everyone make sure to thank bosh-bootstrap
mkdir -p {bin,workspace/deployments/microbosh,workspace/tools}
pushd workspace/deployments
pushd microbosh
cat <<EOF > settings.yml
---
bosh:
  name: bosh-${awsVPCId}
provider:
  name: aws
  credentials:
    provider: AWS
    aws_access_key_id: ${AWS_KEY_ID}
    aws_secret_access_key: ${AWS_ACCESS_KEY}
  region: ${awsRegion}
address:
  vpc_id: ${awsVPCId}
  subnet_id: ${awsBOSHSubnetId}
  ip: ${boshDirectorHost}
EOF

bosh bootstrap deploy

bosh -n target "https://${boshDirectorHost}:25555"

bosh login admin admin

popd

# There is a specific branch of cf-boshworkspace that we use for terraform.
# This may change in the future if we come up with a better way to handle 
# maintaining configs in a git repo
git clone --branch  ${cfBOSHWorkspaceVersion} \
  http://github.com/cloudfoundry-community/cf-boshworkspace

pushd cf-boshworkspace

mkdir -p ssh

# Pull out the UUID of the director - bosh_cli needs it in the deployment to
# know it's hitting the right microbosh instance
directorUUID=$(bosh status | awk '/UUID/{print $2}')

# If CF_DOMAIN is set to XIP, then use XIP.IO. Otherwise, use the variable
if [[ ${cfDomain} == "XIP" ]]
then cfDomain="${cfIP}.xip.io"
fi

curl -sOL https://github.com/cloudfoundry-incubator/spiff/releases/download/v1.0.3/spiff_linux_amd64.zip
unzip spiff_linux_amd64.zip
sudo mv ./spiff /usr/local/bin/spiff 
rm spiff_linux_amd64.zip

/bin/sed -i \
  -e "s/CF_SUBNET1_AZ/${cfSubnet1AZ}/g" \
  -e "s/CF_SUBNET2_AZ/${cfSubnet2AZ}/g" \
  -e "s/LB_SUBNET1_AZ/${cfSubnet1AZ}/g" \
  -e "s/CF_ELASTIC_IP/${cfIP}/g" \
  -e "s/CF_SUBNET1/${cfSubnet1}/g" \
  -e "s/CF_SUBNET2/${cfSubnet2}/g" \
  -e "s/LB_SUBNET1/${lbSubnet1}/g" \
  -e "s/DIRECTOR_UUID/${directorUUID}/g" \
  -e "s/CF_DOMAIN/${cfDomain}/g" \
  -e "s/CF_ADMIN_PASS/${cfAdminPasswd}/g" \
  -e "s/IPMASK/${IPMask}/g" \
  -e "s/CF_SG/${cfSG}/g" \
  -e "s/LB_SUBNET1_AZ/${cfSubnet1AZ}/g" \
  -e "s/release: [0-9][0-9][0-9]$/release: ${cfReleaseVersion}/" \
  deployments/cf-aws-tiny.yml

bosh upload release \
  "https://bosh.io/d/github.com/cloudfoundry/cf-release?v=${cfReleaseVersion}"

bosh deployment "cf-aws-${cfSize}"

# TODO: Debug prepare deployment
# bosh prepare deployment

# Note that until prepare deployment is debugged, need the next step:
bosh upload stemcell "https://d26ekeud912fhb.cloudfront.net/bosh-stemcell/aws/${cfStemcell}"
# Can this vvv be done with a veersion specified? eg ?v=2778
# bosh upload stemcell https://bosh.io/d/stemcells/bosh-aws-xen-ubuntu-trusty-go_agent
# Would prefer to switch to it if so.

# We locally commit the changes to the repo,
# so that errant git checkouts don't cause havok
git commit -am "commit of the updated local deployment manifests."

# Keep trying until there is a successful BOSH deploy.
while ! bosh -n deploy
do continue
done

# FIXME: enable this again when smoke_tests work
# bosh run errand smoke_tests
