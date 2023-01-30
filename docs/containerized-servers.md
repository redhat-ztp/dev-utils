# Containerized Registry and Repo Server Setup

## Environment Variables

Customize as needed:

```bash
OPTV_BASEDIR=/opt/optv
OPTV_REGUSER=optv
OPTV_REGPASSWD=mpk123
OPTV_REGPORT=5678
OPTV_HTPORT=8678

OPTV_HOST=myhost.mydomain
OPTV_HOST_SHORT=myhost

OPTV_REGISTRY_IMAGE=docker.io/library/registry:latest
OPTV_HTSERVER_IMAGE=docker.io/library/httpd
```

## Storage Setup

### Using Local Disk

```bash
wipefs -a /dev/sdc? /dev/sdc
sgdisk -Zo /dev/sdc
sgdisk /dev/sdc -n 1
sgdisk /dev/sdc -c 1:optv
mkfs.ext4 /dev/sdc1

mkdir ${OPTV_BASEDIR}
mount /dev/sdc1 ${OPTV_BASEDIR}

mkdir -p ${OPTV_BASEDIR}/registry/{auth,data} ${OPTV_BASEDIR}/certs
```

## Security Setup

Generate htpasswd file for registry authentication:

```bash
podman run --rm -i -t ${OPTV_HTSERVER_IMAGE} \
    htpasswd -n -bB ${OPTV_REGUSER} ${OPTV_REGPASSWD} > ${OPTV_BASEDIR}/registry/auth/htpasswd
```

Generate self-signed certificate:

```bash
openssl req -newkey rsa:4096 -nodes -sha256 -x509 -days 3650 \
    -keyout ${OPTV_BASEDIR}/certs/optv-${OPTV_HOST_SHORT}.key \
    -out ${OPTV_BASEDIR}/certs/optv-${OPTV_HOST_SHORT}.crt \
    -subj "/C=CA/ST=Ontario/O=OPTV/CN=${HOSTNAME}" \
    -addext "subjectAltName = DNS:${HOSTNAME}"
```

Copy self-signed certificate to your local host and install it:

```bash
scp ${OPTV_HOST}:/opt/optv/certs/optv-${OPTV_HOST_SHORT}.crt .
sudo cp optv-${OPTV_HOST_SHORT}.crt /etc/pki/ca-trust/source/anchors/
rm optv-${OPTV_HOST_SHORT}.crt

sudo update-ca-trust
trust list | grep -i -C 5 ${OPTV_HOST_SHORT}
```

## Launching Containerized Image Registry

Launch the registry container:

```bash
podman run --name optv-registry \
    -p ${OPTV_REGPORT}:5000 \
    -v ${OPTV_BASEDIR}/registry/data:/var/lib/registry:z \
    -v ${OPTV_BASEDIR}/registry/auth:/auth:z \
    -e "REGISTRY_AUTH=htpasswd" \
    -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    -v ${OPTV_BASEDIR}/certs:/certs:z \
    -e "REGISTRY_HTTP_TLS_CERTIFICATE=/certs/optv-${OPTV_HOST_SHORT}.crt" \
    -e "REGISTRY_HTTP_TLS_KEY=/certs/optv-${OPTV_HOST_SHORT}.key" \
    -e REGISTRY_COMPATIBILITY_SCHEMA1_ENABLED=true \
    -d \
    ${OPTV_REGISTRY_IMAGE}
```

From your local host, verify that the registry and authentication is working as expected:

```console
$ curl -u ${OPTV_REGUSER}:${OPTV_REGPASSWD} https://${OPTV_HOST}:${OPTV_REGPORT}/v2/_catalog
{"repositories":[]}
$ podman login -u ${OPTV_REGUSER} -p ${OPTV_REGPASSWD} ${OPTV_HOST}:${OPTV_REGPORT}
Login Succeeded!
```

You should now be able to push images into your registry.

## Launching Containerized httpd Server

```bash
# Copy config files from image
mkdir ${OPTV_BASEDIR}/htserver
podman run --rm \
    -v ${OPTV_BASEDIR}/htserver:/workdir:z \
    ${OPTV_HTSERVER_IMAGE} \
    cp -R /usr/local/apache2/conf /workdir

# Enable ssl/https
sed -i \
    -e 's/^#\(Include .*httpd-ssl.conf\)/\1/' \
    -e 's/^#\(LoadModule .*mod_ssl.so\)/\1/' \
    -e 's/^#\(LoadModule .*mod_socache_shmcb.so\)/\1/' \
    ${OPTV_BASEDIR}/htserver/conf/httpd.conf

# Add self-signed certificate
sed -i \
    -e "s#/usr/local/apache2/conf/server.crt#/certs/optv-${OPTV_HOST_SHORT}.crt#" \
    -e "s#/usr/local/apache2/conf/server.key#/certs/optv-${OPTV_HOST_SHORT}.key#" \
    ${OPTV_BASEDIR}/htserver/conf/extra/httpd-ssl.conf

# Update hostname
sed -i \
    -e "s/www.example.com/${HOSTNAME}/" \
    ${OPTV_BASEDIR}/htserver/conf/httpd.conf \
    ${OPTV_BASEDIR}/htserver/conf/extra/httpd-ssl.conf

# Copy index file from image for test purposes
podman run --rm \
    -v ${OPTV_BASEDIR}/htserver:/workdir:z \
    ${OPTV_HTSERVER_IMAGE} \
    cp -R /usr/local/apache2/htdocs /workdir

# Launch server container
podman run --name optv-htserver \
    -p ${OPTV_HTPORT}:443/tcp \
    -v ${OPTV_BASEDIR}/htserver/htdocs:/usr/local/apache2/htdocs:z \
    -v ${OPTV_BASEDIR}/htserver/conf:/usr/local/apache2/conf:z \
    -v ${OPTV_BASEDIR}/certs:/certs:z \
    -dt \
    ${OPTV_HTSERVER_IMAGE}

# Test server from your host
curl https://${OPTV_HOST}:${OPTV_HTPORT}/
```
