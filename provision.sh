#!/bin/bash

# fail immediately on error
set -e

# echo "$0 $*" > ~/provision.log

fail() {
  echo "$*" >&2
  exit 1
}

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
CF_SG=${15}
CF_ADMIN_PASS=${16}
CF_DOMAIN=${17}
CF_BOSHWORKSPACE_VERSION=${18}
CF_SIZE=${19}
DOCKER_SUBNET=${20}
INSTALL_DOCKER=${21}
CF_RELEASE_VERSION=${22}
DEBUG=${23}
PRIVATE_DOMAINS=${24}
CF_SG_ALLOWS=${25}
CF_RUN_SUBDOMAIN=${26}
CF_APPS_SUBDOMAIN=${27}

INSTALL_LOGSEARCH=${28}
LS1_SUBNET=${29}
LS1_SUBNET_AZ=${30}

BACKBONE_Z1_COUNT=COUNT
API_Z1_COUNT=COUNT
SERVICES_Z1_COUNT=COUNT
HEALTH_Z1_COUNT=COUNT
RUNNER_Z1_COUNT=COUNT
BACKBONE_Z2_COUNT=COUNT
API_Z2_COUNT=COUNT
SERVICES_Z2_COUNT=COUNT
HEALTH_Z2_COUNT=COUNT
RUNNER_Z2_COUNT=COUNT

BACKBONE_POOL=POOL
DATA_POOL=POOL
PUBLIC_HAPROXY_POOL=POOL
PRIVATE_HAPROXY_POOL=POOL
API_POOL=POOL
SERVICES_POOL=POOL
HEALTH_POOL=POOL
RUNNER_POOL=POOL

SKIP_SSL_VALIDATION=false

boshDirectorHost="${IPMASK}.1.4"
logsearch_es_ip="${IPMASK}.7.6"
logsearch_syslog="${IPMASK}.7.7"

cd $HOME
(("$?" == "0")) ||
  fail "Could not find HOME folder, terminating install."


if [[ $DEBUG == "true" ]]; then
  set -x
fi

# Generate the key that will be used to ssh between the bastion and the
# microbosh machine
if [[ ! -f ~/.ssh/id_rsa ]]; then
  ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
fi

# Prepare the jumpbox to be able to install ruby and git-based bosh and cf repos

release=$(cat /etc/*release | tr -d '\n')
case "${release}" in
  (*Ubuntu*|*Debian*)
    sudo apt-get update -yq
    sudo apt-get install -yq aptitude
    sudo aptitude -yq install build-essential vim-nox git unzip tree perl \
      libxslt-dev libxslt1.1 libxslt1-dev libxml2 libxml2-dev \
      libpq-dev libmysqlclient-dev libsqlite3-dev \
      g++ gcc make libc6-dev libreadline6-dev zlib1g-dev libssl-dev libyaml-dev \
      libsqlite3-dev sqlite3 autoconf libgdbm-dev libncurses5-dev automake \
      libtool bison pkg-config libffi-dev cmake
    ;;
  (*Centos*|*RedHat*|*Amazon*)
    sudo yum update -y
    sudo yum install -y epel-release
    sudo yum install -y git unzip xz tree rsync openssl openssl-devel \
    zlib zlib-devel libevent libevent-devel readline readline-devel cmake ntp \
    htop wget tmux gcc g++ autoconf pcre pcre-devel vim-enhanced gcc mysql-devel \
    postgresql-devel postgresql-libs sqlite-devel libxslt-devel libxml2-devel \
    yajl-ruby cmake
    ;;
esac

# Install RVM

if [[ ! -d "$HOME/.rvm" ]]; then
  cd $HOME
  gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3
  curl -sSL https://get.rvm.io | bash -s stable
fi

cd $HOME

if [[ ! "$(ls -A $HOME/.rvm/environments)" ]]; then
  ~/.rvm/bin/rvm install ruby-2.2
fi

if [[ ! -d "$HOME/.rvm/environments/default" ]]; then
  ~/.rvm/bin/rvm alias create default 2.2
fi

source ~/.rvm/environments/default
source ~/.rvm/scripts/rvm

# Install BOSH CLI, bosh-bootstrap, spiff and other helpful plugins/tools
gem install fog-aws -v 0.9.2 --no-ri --no-rdoc --quiet
gem install bundler bosh-bootstrap bosh_cli --no-ri --no-rdoc --quiet

# Workaround 'illegal image file' bug in bosh-aws-cpi gem.
# Issue is already fixed in bosh-aws-cpi-release but no new gems are being published
if [[ ! -f "/usr/local/bin/stemcell-copy" ]]; then
    curl -sOL https://raw.githubusercontent.com/cloudfoundry-incubator/bosh-aws-cpi-release/138b4cac03197af61e252f0fc3611c0a5fb796e1/src/bosh_aws_cpi/scripts/stemcell-copy.sh
    sudo mv ./stemcell-copy.sh /usr/local/bin/stemcell-copy
    chmod +x /usr/local/bin/stemcell-copy
fi

# We use fog below, and bosh-bootstrap uses it as well
cat <<EOF > ~/.fog
:default:
  :aws_access_key_id: $AWS_KEY_ID
  :aws_secret_access_key: $AWS_ACCESS_KEY
  :region: $REGION
EOF

# This volume is created using terraform in aws-bosh.tf
if [[ ! -d "$HOME/workspace" ]]; then
  sudo /sbin/mkfs.ext4 /dev/xvdc
  sudo /sbin/e2label /dev/xvdc workspace
  echo 'LABEL=workspace /home/ubuntu/workspace ext4 defaults,discard 0 0' | sudo tee -a /etc/fstab
  mkdir -p /home/ubuntu/workspace
  sudo mount -a
  sudo chown -R ubuntu:ubuntu /home/ubuntu/workspace
fi

# As long as we have a large volume to work with, we'll move /tmp over there
# You can always use a bigger /tmp
if [[ ! -d "$HOME/workspace/tmp" ]]; then
  sudo rsync -avq /tmp/ /home/ubuntu/workspace/tmp/
fi

if ! [[ -L "/tmp" && -d "/tmp" ]]; then
  sudo rm -fR /tmp
  sudo ln -s /home/ubuntu/workspace/tmp /tmp
fi

# bosh-bootstrap handles provisioning the microbosh machine and installing bosh
# on it. This is very nice of bosh-bootstrap. Everyone make sure to thank bosh-bootstrap
mkdir -p {bin,workspace/deployments/microbosh,workspace/tools}
pushd workspace/deployments
pushd microbosh
create_settings_yml() {
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
  ip: ${boshDirectorHost}
EOF
}

if [[ ! -f "$HOME/workspace/deployments/microbosh/settings.yml" ]]; then
  create_settings_yml
fi

if [[ ! -d "$HOME/workspace/deployments/microbosh/deployments" ]]; then
  bosh bootstrap deploy
fi


rebuild_micro_bosh_easy() {
  echo "Retry deploying the micro bosh, attempting bosh bootstrap delete..."
  bosh bootstrap delete || rebuild_micro_bosh_hard
  bosh bootstrap deploy
  bosh -n target https://${boshDirectorHost}:25555
  bosh login admin admin
}

rebuild_micro_bosh_hard() {
  echo "Retry deploying the micro bosh, attempting bosh bootstrap delete..."
  rm -rf "$HOME/workspace/deployments/microbosh/deployments"
  rm -rf "$HOME/workspace/deployments/microbosh/ssh"
  create_settings_yml
}

# We've hardcoded the IP of the microbosh machine, because convenience
bosh -n target https://${boshDirectorHost}:25555
bosh login admin admin

if [[ ! "$?" == 0 ]]; then
  #wipe the ~/workspace/deployments/microbosh folder contents and try again
  echo "Retry deploying the micro bosh..."
fi
popd

# There is a specific branch of cf-boshworkspace that we use for terraform. This
# may change in the future if we come up with a better way to handle maintaining
# configs in a git repo
if [[ ! -d "$HOME/workspace/deployments/cf-boshworkspace" ]]; then
  git clone --branch  ${CF_BOSHWORKSPACE_VERSION} http://github.com/cloudfoundry-community/cf-boshworkspace
fi
pushd cf-boshworkspace
mkdir -p ssh
gem install bundler
bundle install

# Pull out the UUID of the director - bosh_cli needs it in the deployment to
# know it's hitting the right microbosh instance
DIRECTOR_UUID=$(bosh status --uuid)

# If CF_DOMAIN is set to XIP, then use XIP.IO. Otherwise, use the variable
if [[ $CF_DOMAIN == "XIP" ]]; then
  CF_DOMAIN="${CF_IP}.xip.io"
  SKIP_SSL_VALIDATION="true"
fi

echo "Install Traveling CF"
if [[ "$(cat $HOME/.bashrc | grep 'export PATH=$PATH:$HOME/bin/traveling-cf-admin')" == "" ]]; then
  curl -s https://raw.githubusercontent.com/cloudfoundry-community/traveling-cf-admin/master/scripts/installer | bash
  echo 'export PATH=$PATH:$HOME/bin/traveling-cf-admin' >> $HOME/.bashrc
  source $HOME/.bashrc
fi

if [[ ! -f "/usr/local/bin/spiff" ]]; then
  curl -sOL https://github.com/cloudfoundry-incubator/spiff/releases/download/v1.0.3/spiff_linux_amd64.zip
  unzip spiff_linux_amd64.zip
  sudo mv ./spiff /usr/local/bin/spiff
  rm spiff_linux_amd64.zip
fi

# If CF_RUN_SUBDOMAIN is set, then use it's value to replace the default subdomain. Otherwise (if empty), don't use a subdomain
if [[ -n "$CF_RUN_SUBDOMAIN" ]]; then
  CF_RUN_SUBDOMAIN_SED_EXPRESSION="s/run.CF_DOMAIN/${CF_RUN_SUBDOMAIN}.${CF_DOMAIN}/g"
else
  CF_RUN_SUBDOMAIN_SED_EXPRESSION="s/run.CF_DOMAIN/${CF_DOMAIN}/g"
fi

# If CF_APPS_SUBDOMAIN is set, then use it's value to replace the default subdomain. Otherwise (if empty), don't use a subdomain
if [[ -n "$CF_APPS_SUBDOMAIN" ]]; then
  CF_APPS_SUBDOMAIN_SED_EXPRESSION="s/apps.CF_DOMAIN/${CF_APPS_SUBDOMAIN}.${CF_DOMAIN}/g"
else
  CF_APPS_SUBDOMAIN_SED_EXPRESSION="s/apps.CF_DOMAIN/${CF_DOMAIN}/g"
fi

# This is some hackwork to get the configs right. Could be changed in the future
/bin/sed -i \
  -e "s/CF_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  -e "s/CF_SUBNET2_AZ/${CF_SUBNET2_AZ}/g" \
  -e "s/LB_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  -e "s/CF_ELASTIC_IP/${CF_IP}/g" \
  -e "s/CF_SUBNET1/${CF_SUBNET1}/g" \
  -e "s/CF_SUBNET2/${CF_SUBNET2}/g" \
  -e "s/LB_SUBNET1/${LB_SUBNET1}/g" \
  -e "s/DIRECTOR_UUID/${DIRECTOR_UUID}/g" \
  -e $CF_RUN_SUBDOMAIN_SED_EXPRESSION \
  -e $CF_APPS_SUBDOMAIN_SED_EXPRESSION \
  -e "s/CF_DOMAIN/${CF_DOMAIN}/g" \
  -e "s/CF_ADMIN_PASS/${CF_ADMIN_PASS}/g" \
  -e "s/IPMASK/${IPMASK}/g" \
  -e "s/CF_SG/${CF_SG}/g" \
  -e "s/LB_SUBNET1_AZ/${CF_SUBNET1_AZ}/g" \
  -e "s/version: \+[0-9]\+ \+# DEFAULT_CF_RELEASE_VERSION/version: ${CF_RELEASE_VERSION}/g" \
  -e "s/backbone_z1:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/backbone_z1:\1${BACKBONE_Z1_COUNT}\2/" \
  -e "s/api_z1:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/api_z1:\1${API_Z1_COUNT}\2/" \
  -e "s/services_z1:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/services_z1:\1${SERVICES_Z1_COUNT}\2/" \
  -e "s/health_z1:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/health_z1:\1${HEALTH_Z1_COUNT}\2/" \
  -e "s/runner_z1:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/runner_z1:\1${RUNNER_Z1_COUNT}\2/" \
  -e "s/backbone_z2:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/backbone_z2:\1${BACKBONE_Z2_COUNT}\2/" \
  -e "s/api_z2:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/api_z2:\1${API_Z2_COUNT}\2/" \
  -e "s/services_z2:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/services_z2:\1${SERVICES_Z2_COUNT}\2/" \
  -e "s/health_z2:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/health_z2:\1${HEALTH_Z2_COUNT}\2/" \
  -e "s/runner_z2:\( \+\)[0-9\.]\+\(.*# MARKER_FOR_PROVISION.*\)/runner_z2:\1${RUNNER_Z2_COUNT}\2/" \
  -e "s/backbone:\( \+\)[a-z\-\_A-Z0-1]\+\(.*# MARKER_FOR_POOL_PROVISION.*\)/backbone:\1${BACKBONE_POOL}\2/" \
  -e "s/data:\( \+\)[a-z\-\_A-Z0-1]\+\(.*# MARKER_FOR_POOL_PROVISION.*\)/data:\1${DATA_POOL}\2/" \
  -e "s/public_haproxy:\( \+\)[a-z\-\_A-Z0-1]\+\(.*# MARKER_FOR_POOL_PROVISION.*\)/public_haproxy:\1${PUBLIC_HAPROXY_POOL}\2/" \
  -e "s/private_haproxy:\( \+\)[a-z\-\_A-Z0-1]\+\(.*# MARKER_FOR_POOL_PROVISION.*\)/private_haproxy:\1${PRIVATE_HAPROXY_POOL}\2/" \
  -e "s/api:\( \+\)[a-z\-\_A-Z0-1]\+\(.*# MARKER_FOR_POOL_PROVISION.*\)/api:\1${API_POOL}\2/" \
  -e "s/services:\( \+\)[a-z\-\_A-Z0-1]\+\(.*# MARKER_FOR_POOL_PROVISION.*\)/services:\1${SERVICES_POOL}\2/" \
  -e "s/health:\( \+\)[a-z\-\_A-Z0-1]\+\(.*# MARKER_FOR_POOL_PROVISION.*\)/health:\1${HEALTH_POOL}\2/" \
  -e "s/runner:\( \+\)[a-z\-\_A-Z0-1]\+\(.*# MARKER_FOR_POOL_PROVISION.*\)/runner:\1${RUNNER_POOL}\2/" \
  deployments/cf-aws-${CF_SIZE}.yml

if [[ -n "$PRIVATE_DOMAINS" ]]; then
  for domain in $(echo $PRIVATE_DOMAINS | tr "," "\n"); do
    sed -i -e "s/^\(\s\+\)- PRIVATE_DOMAIN_PLACEHOLDER/\1- $domain\n\1- PRIVATE_DOMAIN_PLACEHOLDER/" deployments/cf-aws-${CF_SIZE}.yml
  done
  sed -i -e "s/^\s\+- PRIVATE_DOMAIN_PLACEHOLDER//" deployments/cf-aws-${CF_SIZE}.yml
else
  sed -i -e "s/^\(\s\+\)internal_only_domains:\$/\1internal_only_domains: []/" deployments/cf-aws-${CF_SIZE}.yml
  sed -i -e "s/^\s\+- PRIVATE_DOMAIN_PLACEHOLDER//" deployments/cf-aws-${CF_SIZE}.yml
fi

if [[ -n "$CF_SG_ALLOWS" ]]; then
  replacement_text=""
  for cidr in $(echo $CF_SG_ALLOWS | tr "," "\n"); do
    if [[ -n "$cidr" ]]; then
      replacement_text="${replacement_text}{\"protocol\":\"all\",\"destination\":\"${cidr}\"},"
    fi
  done
  if [[ -n "$replacement_text" ]]; then
    replacement_text=$(echo $replacement_text | sed 's/,$//')
    sed -i -e "s|^\(\s\+additional_security_group_rules:\s\+\).*|\1[$replacement_text]|" deployments/cf-aws-${CF_SIZE}.yml
  fi
fi

if [[ $INSTALL_LOGSEARCH == "true" ]]; then
    if [[ $(grep -v syslog deployments/cf-aws-${CF_SIZE}.yml)  ]]; then
        INSERT_AT=$(grep -n cf-networking.yml deployments/cf-aws-${CF_SIZE}.yml  | cut -d : -f 1)
        sed -i "${INSERT_AT}i\ \ - cf-syslog.yml" deployments/cf-aws-${CF_SIZE}.yml

        cat <<EOF >> deployments/cf-aws-${CF_SIZE}.yml

  syslog_daemon_config:
    address: ${logsearch_syslog}
    port: 5515
EOF
    fi
fi

bosh deployment cf-aws-${CF_SIZE}
bosh prepare deployment || bosh prepare deployment  #Seems to always fail on the first run...

# We locally commit the changes to the repo, so that errant git checkouts don't
# cause havok
currentGitUser="$(git config user.name || /bin/true )"
currentGitEmail="$(git config user.email || /bin/true )"
if [[ "${currentGitUser}" == "" || "${currentGitEmail}" == "" ]]; then
  git config --global user.email "${USER}@${HOSTNAME}"
  git config --global user.name "${USER}"
  echo "blarg"
fi

gitDiff="$(git diff)"
if [[ ! "${gitDiff}" == "" ]]; then
  git commit -am 'commit of the local deployment configs'
fi

# Keep trying until there is a successful BOSH deploy.
for i in {0..2}
do bosh -n deploy || true
done

# Run smoke tests disabled - running into intermittent failures
#bosh run errand smoke_tests_runner

# Now deploy docker services if requested
if [[ $INSTALL_DOCKER == "true" ]]; then

  cd ~/workspace/deployments
  if [[ ! -d "$HOME/workspace/deployments/docker-services-boshworkspace" ]]; then
    git clone https://github.com/cloudfoundry-community/docker-services-boshworkspace.git
  fi

  echo "Update the docker-aws-vpc.yml with cf-boshworkspace parameters"
  /home/ubuntu/workspace/deployments/docker-services-boshworkspace/shell/populate-docker-aws-vpc ${CF_SIZE}
  dockerDeploymentManifest="/home/ubuntu/workspace/deployments/docker-services-boshworkspace/deployments/docker-aws-vpc.yml"
  /bin/sed -i \
    -e "s/SUBNET_ID/${DOCKER_SUBNET}/g" \
    -e "s/DOCKER_SG/${CF_SG}/g" \
    "${dockerDeploymentManifest}"

  cd ~/workspace/deployments/docker-services-boshworkspace
  bundle install
  bosh deployment docker-aws-vpc
  bosh prepare deployment

  # Keep trying until there is a successful BOSH deploy.
  for i in {0..2}
  do bosh -n deploy
  done

fi

# Now deploy logsearch if requested
if [[ $INSTALL_LOGSEARCH == "true" ]]; then

    cd ~/workspace/deployments
    if [[ ! -d "$HOME/workspace/deployments/logsearch-boshworkspace" ]]; then
        git clone https://github.com/cloudfoundry-community/logsearch-boshworkspace.git
    fi

    cd logsearch-boshworkspace

    /bin/sed -i \
             -e "s/DIRECTOR_UUID/${DIRECTOR_UUID}/g" \
             -e "s/IPMASK/${IPMASK}/g" \
             -e "s/CF_DOMAIN/run.${CF_DOMAIN}/g" \
             -e "s/CF_ADMIN_PASS/${CF_ADMIN_PASS}/g" \
             -e "s/CLOUDFOUNDRY_SG/${CF_SG}/g" \
             -e "s/LS1_SUBNET_AZ/${LS1_SUBNET_AZ}/g" \
             -e "s/LS1_SUBNET/${LS1_SUBNET}/g" \
             -e "s/skip-ssl-validation: false/skip-ssl-validation: ${SKIP_SSL_VALIDATION}/g"\
             deployments/logsearch-aws-vpc.yml

    bundle install
    bosh deployment logsearch-aws-vpc
    bosh prepare deployment

    # Keep trying until there is a successful BOSH deploy.
    for i in {0..2}
    do bosh -n deploy
    done

    # Install kibana dashboard
    cat .releases/logsearch-for-cloudfoundry/target/kibana4-dashboards.json \
        | curl --data-binary @- http://${logsearch_es_ip}:9200/_bulk

    # Fix Tile Map visualization # http://git.io/vLYabb
    if [[ $(curl -s http://${logsearch_es_ip}:9200/_template/ | grep -v geo_pointt) ]]; then
        echo "installing default elasticsarch index template"
        curl -XPUT http://${logsearch_es_ip}:9200/_template/logstash -d \
             '{"template":"logstash-*","order":10,"settings":{"number_of_shards":4,"number_of_replicas":1,"index":{"query":{"default_field":"@message"},"store":{"compress":{"stored":true,"tv":true}}}},"mappings":{"_default_":{"_all":{"enabled":false},"_source":{"compress":true},"_ttl":{"enabled":true,"default":"2592000000"},"dynamic_templates":[{"string_template":{"match":"*","mapping":{"type":"string","index":"not_analyzed"},"match_mapping_type":"string"}}],"properties":{"@message":{"type":"string","index":"analyzed"},"@tags":{"type":"string","index":"not_analyzed"},"@timestamp":{"type":"date","index":"not_analyzed"},"@type":{"type":"string","index":"not_analyzed"},"message":{"type":"string","index":"analyzed"},"message_data":{"type":"object","properties":{"Message":{"type":"string","index":"analyzed"}}},"geoip":{"properties":{"location":{"type":"geo_point"}}}}}}}'

        echo "deleting all indexes since installed template only applies to new indexes"
        curl -XDELETE http://${logsearch_es_ip}:9200/logstash-*
    fi
fi

echo "Provision script completed..."
exit 0
