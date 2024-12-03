# Is it Observable
<p align="center"><img src="/image/logo.png" width="40%" alt="Is It observable Logo" /></p>

## Episode : Karpenter
This repository contains the files utilized during the tutorial presented in the dedicated IsItObservable episode related to Karpenter.
<p align="center"><img src="/image/karpenter.png" width="40%" alt="karpenter Logo" /></p>

this tutorial will also utilize the OpenTelemetry Operator with:
* the OpenTelemetry Demo
* Hipster-shop
* Keptn metric server




## Prerequisite 
The following tools need to be install on your machine :
- jq
- kubectl
- git
- aws cli
- eksctl
- Helm


### 1.Create a EKS cluster
```shell
expot OWNER=<YOUR NAME>
export OWNERMAIL=<YOUR EMAIL>
export OWNERSUFFIX=<YOUR SUFFIX>
export KARPENTER_NAMESPACE="karpenter"
export KARPENTER_VERSION="1.0.8"
export K8S_VERSION="1.31"
export AWS_PARTITION="aws" 
export CLUSTER_NAME="${OWNERSUFFIX}-karpenter-webinar"
export AWS_DEFAULT_REGION="eu-west-3"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TEMPOUT="$(mktemp)"
export ARM_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-arm64/recommended/image_id --query Parameter.Value --output text)"
export AMD_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2/recommended/image_id --query Parameter.Value --output text)"
export GPU_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-gpu/recommended/image_id --query Parameter.Value --output text)"

curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml  > "${TEMPOUT}" \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"

eksctl create cluster -f - <<EOF
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}

iam:
  withOIDC: true
  podIdentityAssociations:
  - namespace: "${KARPENTER_NAMESPACE}"
    serviceAccountName: karpenter
    roleName: ${CLUSTER_NAME}-karpenter
    permissionPolicyARNs:
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}

iamIdentityMappings:
- arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes
  ## If you intend to run Windows workloads, the kube-proxy group should be specified.
  # For more information, see https://github.com/aws/karpenter/issues/5099.
  # - eks:kube-proxy-windows

managedNodeGroups:
- instanceType: m5.large
  amiFamily: AmazonLinux2
  name: ${CLUSTER_NAME}-ng
  desiredCapacity: 2
  minSize: 1
  maxSize: 10

addons:
- name: eks-pod-identity-agent
EOF

export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"
export KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"

echo "${CLUSTER_ENDPOINT} ${KARPENTER_IAM_ROLE_ARN}"
```
Once the cluster is deployed, let's deploy Karpenter: 
```shell
helm registry logout public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
--set "settings.clusterName=${CLUSTER_NAME}" \
--set "settings.interruptionQueue=${CLUSTER_NAME}" \
--set controller.resources.requests.cpu=1 \
--set controller.resources.requests.memory=1Gi \
--set controller.resources.limits.cpu=1 \
--set controller.resources.limits.memory=1Gi \
--wait
```

And last create our Karpenter NodePools:
```shell
sed -i '' "s,CLUSTER_NAME_TO_REPLACE,$CLUSTER_NAME," karpenter/node-pool.yaml
sed -i '' "s,ARM_AMI_ID_TO_REPLACE,$ARM_AMI_ID," karpenter/node-pool.yaml
sed -i '' "s,AMD_AMI_ID_TO_REPLACE,$AMD_AMI_ID," karpenter/node-pool.yaml
sed -i '' "s,OWNER_TO_REPLACE,$OWNER," karpenter/node-pool.yaml
sed -i '' "s,OWNER_EMAIL_TO_REPLACE,$OWNERMAIL," karpenter/node-pool.yaml
kubectl apply -f karpenter/node-pool.yaml

```


### 3.Clone Github repo
```shell
git clone https://github.com/Isitobservable/karpenter
cd karpenter
```
### 4. Deploy 

#### 1. Istio

1. Download Istioctl
```shell
curl -L https://istio.io/downloadIstio | sh -
```
This command download the latest version of istio ( in our case istio 1.18.2) compatible with our operating system.
2. Add istioctl to you PATH
```shell
cd istio-1.24.1
```
this directory contains samples with addons . We will refer to it later.
```shell
export PATH=$PWD/bin:$PATH
```
#### 2. Dynatrace 
##### 1. Dynatrace Tenant - start a trial
If you don't have any Dynatrace tenant , then i suggest to create a trial using the following link : [Dynatrace Trial](https://bit.ly/3KxWDvY)
Once you have your Tenant save the Dynatrace (including https) tenant URL in the variable `DT_TENANT_URL` (for example : https://dedededfrf.live.dynatrace.com)
```shell
DT_TENANT_URL=<YOUR TENANT URL>
```
##### 2. Create the Dynatrace API Tokens
The dynatrace operator will require to have several tokens:
* Token to deploy and configure the various components
* Token to ingest metrics and Traces


###### Operator Token
One for the operator having the following scope:
* Create ActiveGate tokens
* Read entities
* Read Settings
* Write Settings
* Access problem and event feed, metrics and topology
* Read configuration
* Write configuration
* Paas integration - installer downloader
<p align="center"><img src="/image/operator_token.png" width="40%" alt="operator token" /></p>

Save the value of the token . We will use it later to store in a k8S secret
```shell
API_TOKEN=<YOUR TOKEN VALUE>
```
###### Ingest data token
Create a Dynatrace token with the following scope:
* Ingest metrics (metrics.ingest)
* Ingest logs (logs.ingest)
* Ingest events (events.ingest)
* Ingest OpenTelemetry
* Read metrics
<p align="center"><img src="/image/data_ingest_token.png" width="40%" alt="data token" /></p>
Save the value of the token . We will use it later to store in a k8S secret

```shell
DATA_INGEST_TOKEN=<YOUR TOKEN VALUE>
```
#### 3. Run the deployment script
```shell
cd ..
chmod 777 deployment.sh
./deployment.sh  --clustername "${CLUSTER_NAME}" --dturl "${DT_TENANT_URL}" --dtingesttoken "${DATA_INGEST_TOKEN}" --dtoperatortoken "${API_TOKEN}"  --karpenternamespace "${KARPENTER_NAMESPACE}" 
```

## Tutorial Steps

### Karpenter Notebook

Let's deploy the notebook located : `dynatrace/notebook.json`

In dynatrace , Open The Notebook application and click on upload
<p align="center"><img src="/image/notebook.png" width="40%" alt="tetragon notebook" /></p>

This notebook is an example on how we could take advantage of log processing with tetragon events.

### Tetragon Dashboards

#### 1. Cluster Overview

Let's deploy the dashboard located : `dynatrace/Karpenter _cluster_view.json`

In dynatrace , Open The Dashboard application and click on upload
<p align="center"><img src="/image/cluster_dashboard.png" width="40%" alt="cluster dashboard" /></p>


#### 2. NodePool usage

Let's deploy the dashboard located : `dynatrace/karpenter_nodepool_dashboard.json`

In dynatrace , Open The Dashboard application and click on upload
<p align="center"><img src="/image/nodepool_dashboard.png" width="40%" alt="Nodepool dashboard" /></p>
