#!/bin/bash -xe
# send the script output to a different log file.
exec > >(tee /var/log/user-data.log|logger -t user-data ) 2>&1
echo BEGIN
date '+%Y-%m-%d %H:%M:%S'

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/aws/bin:/root/bin

yum update -y

# amazon linux uses this command to isntall extra packages (epel)
amazon-linux-extras install epel -y

# Amazon linux does not have pip installed by default.
string=$(uname -r)
if [[ $string == *"amzn"* ]]; then
  sudo yum install -y python-pip
fi

# upgrade pip to latest stable
sudo pip install -U pip
# upgrade awscli to latest stable
# upgrading pip from 9.0.3 to 10.0.1 changes the path from /usr/bin/pip to
# /usr/local/bin/pip and the line below throws this error
#     /var/lib/cloud/instance/scripts/part-001: line 10: /usr/bin/pip: No such file or directory
# So, I export the PATH in the beggining correctly but still tries to from the old location
# I couldn't see why in the outputs I'm going to hardcode it for now (01:10am)
 pip install -U awscli

echo "* hard nofile 64000" >> /etc/security/limits.conf
echo "* soft nofile 64000" >> /etc/security/limits.conf
echo "root hard nofile 64000" >> /etc/security/limits.conf
echo "root soft nofile 64000" >> /etc/security/limits.conf

cat <<EOF > /etc/yum.repos.d/mongodb-org-4.2.repo
[mongodb-org-4.2]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2013.03/mongodb-org/4.2/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-4.2.asc
EOF

sudo tee /etc/yum.repos.d/pritunl.repo << EOF
[pritunl]
name=Pritunl Repository
baseurl=https://repo.pritunl.com/stable/yum/amazonlinux/2/
gpgcheck=1
enabled=1
EOF

gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys 7568D9BB55FF9E5287D586017AE645C0CF8E292A
gpg --armor --export 7568D9BB55FF9E5287D586017AE645C0CF8E292A > key.tmp; sudo rpm --import key.tmp; rm -f key.tmp
sudo yum -y install pritunl mongodb-org
sudo systemctl start mongod pritunl
sleep 10
sudo systemctl enable mongod pritunl
sudo systemctl status mongod pritunl

cat <<EOF > /usr/sbin/mongobackup.sh
#!/bin/bash -e

set -o errexit  # exit on cmd failure
set -o nounset  # fail on use of unset vars
set -o pipefail # throw latest exit failure code in pipes
set -o xtrace   # print command traces before executing command.

export PATH="/usr/local/bin:\$PATH"
export BACKUP_TIME=\$(date +'%Y-%m-%d-%H-%M-%S')
export BACKUP_FILENAME="\$BACKUP_TIME-pritunl-db-backup.tar.gz"
export BACKUP_DEST="/tmp/\$BACKUP_TIME"
mkdir "\$BACKUP_DEST" && cd "\$BACKUP_DEST"
mongodump -d pritunl
tar zcf "\$BACKUP_FILENAME" dump
rm -rf dump
md5sum "\$BACKUP_FILENAME" > "\$BACKUP_FILENAME.md5"
aws s3 sync . s3://${s3_backup_bucket}/backups/
cd && rm -rf "\$BACKUP_DEST"
EOF
chmod 700 /usr/sbin/mongobackup.sh

cat <<EOF > /etc/cron.daily/pritunl-backup
#!/bin/bash -e
export PATH="/usr/local/sbin:/usr/local/bin:\$PATH"
mongobackup.sh && \
  curl -fsS --retry 3 \
  "https://hchk.io/\$( aws --region=${aws_region} --output=text \
                        ssm get-parameters \
                        --names ${healthchecks_io_key} \
                        --with-decryption \
                        --query 'Parameters[*].Value')"
EOF
chmod 755 /etc/cron.daily/pritunl-backup

cat <<EOF > /etc/logrotate.d/pritunl
/var/log/mongodb/*.log {
  daily
  missingok
  rotate 60
  compress
  delaycompress
  copytruncate
  notifempty
}
EOF

cat <<EOF > /home/ec2-user/.bashrc
# https://twitter.com/leventyalcin/status/852139188317278209
if [ -f /etc/bashrc ]; then
  . /etc/bashrc
fi
EOF

KEY=$(sudo pritunl setup-key)
aws ssm put-parameter --name "/${environment}/pritunl/pritunl-default-password" --value "\$KEY" --type "SecureString" --region "${aws_region}"
