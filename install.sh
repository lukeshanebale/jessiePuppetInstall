# Normalise the location to be lower case (as puppet.conf doesnt like anything uppercase).

sys_loc=$(echo $system_location |tr '[:upper:]' '[:lower:]')

# Unset the proxy if required.
puppetproxy=false
case $sys_loc in
*)
location=$(echo pi.domainname.tld)
# else, use the proxy
puppetproxy=true
;;
esac

# Fix the hostname and domain in /etc/hosts (for Host Group mapping)
if [ ! "`grep \"puppet\" /etc/hosts`" ] ; then
sed -i "/`hostname`/d" /etc/hosts
sed -i "2i127.0.1.1\t`hostname`.$location\t`hostname`" /etc/hosts
sed -i "3i# Added during the puppet install" /etc/hosts
fi

# Create the CA
cat <<EOF >/tmp/ca.pem
-----BEGIN CERTIFICATE-----
Enter the CA contents here...
-----END CERTIFICATE-----
EOF

# Create the certificate
cat <<EOF >/tmp/build.pem
-----BEGIN CERTIFICATE-----
Enter the certificate contents here...
-----END CERTIFICATE-----
EOF

# Create the private key
cat <<EOF >/tmp/build.key
-----BEGIN RSA PRIVATE KEY-----
Enter the private key contents here...
-----END RSA PRIVATE KEY-----
EOF

# Create sources list
rm /etc/apt/sources.list
touch /etc/apt/sources.list
echo 'deb http://archive.debian.org/debian jessie main' >> /etc/apt/sources.list

# install base
apt-get -o Acquire::Check-Valid-Until=false update -y --force-yes
apt-get install -y --force-yes build-essential libssl-dev openssl

# install ruby
mkdir ruby
cd ruby
wget --no-check-certificate https://cache.ruby-lang.org/pub/ruby/2.3/ruby-2.3.0.tar.gz
tar xvfz ruby-2.3.0.tar.gz
cd ruby-2.3.0
./configure --prefix=/usr/local --with-openssl-dir=/usr/bin
make
make install
ruby -v
gem sources -r https://rubygems.org/
gem sources --add http://rubygems.org/ 

# puppet install
echo "Downloading the $release version from puppetlabs"
wget -q https://downloads.puppetlabs.com/puppet/puppet-4.10.11.gem -O /tmp/puppet-4.10.11.gem
echo "Installing puppet"
gem install /tmp/puppet-4.10.11.gem
echo "Updating package lists"
apt-get -qq update
apt-get install puppet-agent
echo "Create some links"
ln -sf /opt/puppetlabs/puppet/bin/facter /usr/local/sbin/facter
ln -sf /opt/puppetlabs/puppet/bin/hiera /usr/local/sbin/hiera
ln -sf /opt/puppetlabs/puppet/bin/mco /usr/local/sbin/mco
ln -sf /opt/puppetlabs/puppet/bin/puppet /usr/local/sbin/puppet


# Generate the hostname/fqdn correctly
# host=$(/opt/puppetlabs/bin/facter hostname| tr '[:upper:]' '[:lower:]').$location
host=$(/usr/local/bin/facter hostname| tr '[:upper:]' '[:lower:]').$location

# Query the Puppet CA to see if the host exists
curl -sk "https://puppetserver.tld:8140/puppet-ca/v1/certificate_status/$host" --cacert /tmp/ca.pem --cert /tmp/build.pem --key /tmp/build.key | grep -q $host

# If the exit code of grep is 0 (match found), revoke then delete the signed certificate from the Puppet CA
if [ $? = '0' ]; then
echo "Revoking Certificate: $host"
curl -s --header "Content-Type: application/json" -X PUT -d '{"desired_state":"revoked"}' "https://puppetserver.tld:8140/puppet-ca/v1/certificate_status/$host" --cacert /tmp/ca.pem --cert /tmp/build.pem --key /tmp/build.key
echo "Deleteing Certificate: $host"
curl -s --header "Content-Type: application/json" -X DELETE "https://puppetserver.tld:8140/puppet-ca/v1/certificate_status/$host" --cacert /tmp/ca.pem --cert /tmp/build.pem --key /tmp/build.key
else
echo "Certificate not found: $host"
fi

# Remove the certs as they are no longer needed
rm /tmp/ca.pem
rm /tmp/build.pem
rm /tmp/build.key

# Make the required puppetlabs directories 
mkdir /etc/puppetlabs
mkdir /etc/puppetlabs/puppet
touch /etc/puppetlabs/puppet/puppet.conf

# Populate puppet.conf with the required information 
echo '[agent]' >> /etc/puppetlabs/puppet/puppet.conf
echo certname = $HOSTNAME.pi.domainname.tld | awk '{print tolower($0)}' >> /etc/puppetlabs/puppet/puppet.conf
echo 'server = puppetserver.tld' >> /etc/puppetlabs/puppet/puppet.conf
echo 'runinterval = 3600' >> /etc/puppetlabs/puppet/puppet.conf
echo 'environment = production' >> /etc/puppetlabs/puppet/puppet.conf
echo 'http_proxy_host = proxyserver.tld' >> /etc/puppetlabs/puppet/puppet.conf
echo 'http_proxy_port = 3128' >> /etc/puppetlabs/puppet/puppet.conf
echo 'splay = true' >> /etc/puppetlabs/puppet/puppet.conf

# Enable the puppet service
puppet resource service puppet ensure=running enable=true

# Run puppet
puppet agent -t
