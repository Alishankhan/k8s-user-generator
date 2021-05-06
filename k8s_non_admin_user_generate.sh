#!/usr/bin/env bash

# Copyright (C) Mohd Alishan Khan <alishankhan366@gmail.com>
# This file is part of K8s User Generator <https://github.com/Alishankhan/k8s-user-generator>.
#
# K8s User Generator is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# K8s User Generator is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with K8s User Generator.  If not, see <http://www.gnu.org/licenses/>.

user=$1
namespace=$2
user_csr=${user}.csr
user_csr_cnf=${user}_csr.cnf
user_csr_yaml=${user}_csr.yaml
user_key=${user}.key
user_crt=${user}.crt
if [ -z "${user}" ];
then
  echo "Username is required."
  exit 1
fi

if [ -z "${namespace}" ];
then
  echo "Namespace is required."
  exit 1
fi

cat >${user_csr_cnf}<<EOF

[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[ dn ]
CN = ${user}
O = dev[ v3_ext ]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth,clientAuth
EOF

openssl genrsa -out ${user_key} 4096
openssl req -config ./${user_csr_cnf} -new -key ${user_key} -nodes -out ${user_csr}

cat > ${user_csr_yaml}<<EOF
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: ${user}csr
spec:
  groups:
  - system:authenticated
  request: $(cat ./${user_csr} | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
  - client auth
EOF

cat > ${user}_role.yaml <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${user}-role
rules:
- apiGroups: ["*"]
  resources: ["pods", "logs", "services"]
  verbs: ["get", "create", "delete", "list", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: RoleBinding
metadata:
  name: ${user}-role-binding
roleRef:
  kind: Role
  name: ${user}-role
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: User
  name: ${user}
  namespace: ${namespace}

EOF

cat ${user_csr_yaml} | kubectl apply -f -
kubectl certificate approve "${user}csr"
kubectl get csr ${user}csr  -o jsonpath='{.status.certificate}'   | base64 --decode > ${user_crt}
kubectl apply -f ${user}_role.yaml --namespace=${namespace}

CLUSTER_NAME=$(kubectl config view --minify -o jsonpath={.current-context})
CLIENT_CERTIFICATE_DATA=$(kubectl get csr ${user}csr -o jsonpath='{.status.certificate}')
CLUSTER_CA=$(kubectl config view --raw -o json | jq -r '.clusters[0].cluster."certificate-authority-data"')
CLUSTER_ENDPOINT=$(kubectl config view --raw -o json | jq -r '.clusters[0].cluster.server')
echo $CLUSTER_CA


cat > ${user}_kubeconfig << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: ${CLUSTER_ENDPOINT}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: ${user}
    namespace: ${namespace}
  name: ${user}-${CLUSTER_NAME}
current-context: ${user}-${CLUSTER_NAME}
EOF

kubectl --kubeconfig ./${user}_kubeconfig config set-credentials ${user} \
  --client-key=$PWD/${user}.key \
  --client-certificate=$PWD/${user}.crt \
  --embed-certs=true

rm ${user_csr_yaml}
rm ${user_csr_cnf}
rm ${user_csr}
rm ${user_key}
rm ${user_crt}
