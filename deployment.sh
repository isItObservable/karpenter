#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### Clustern name: name of your k8s cluster
### dttoken: Dynatrace api token with ingest metrics and otlp ingest scope
### dturl : url of your DT tenant wihtout any / at the end for example: https://dedede.live.dynatrace.com
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
echo "parsing arguments"
while [ $# -gt 0 ]; do
  case "$1" in
   --dtoperatortoken)
     DTOPERATORTOKEN="$2"
    shift 2
     ;;
   --dtingesttoken)
     DTTOKEN="$2"
    shift 2
     ;;
   --dturl)
     DTURL="$2"
    shift 2
     ;;
  --clustername)
    CLUSTERNAME="$2"
   shift 2
    ;;

   --karpenternamespace)
      KARPENTERNAMESPACE="$2"
      shift 2
      ;;

  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done
echo "Checking arguments"
if [ -z "$CLUSTERNAME" ]; then
  echo "Error: clustername not set!"
  exit 1
fi
if [ -z "$DTURL" ]; then
  echo "Error: Dt url not set!"
  exit 1
fi

if [ -z "$DTTOKEN" ]; then
  echo "Error: Data ingest api-token not set!"
  exit 1
fi


if [ -z "$DTOPERATORTOKEN" ]; then
  echo "Error: DT operator token not set!"
  exit 1
fi


if [ -z "$KARPENTERNAMESPACE" ]; then
 KARPENTERNAMESPACE="kube-system"
fi

CLUSTERID=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}');

#### Deploy the cert-manager
echo "Deploying Cert Manager ( for OpenTelemetry Operator)"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.0/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m
# Deploy the opentelemetry operator
sleep 10
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

#### Deploy keptn lifecycle Toolkit
echo "Deploying Keptn"

helm repo add klt https://charts.lifecycle.keptn.sh
helm repo update
helm upgrade --install keptn klt/klt -n keptn-lifecycle-toolkit-system --set metricsOperator.nodeSelector.type=operation --create-namespace --wait




echo "Deploying Istio"

istioctl install -f istio/istio-operator.yaml --skip-confirmation


sed -i '' "s,KARPENTER_NS_TO_REPLACE,$KARPENTERNAMESPACE," openTelemetry-demo/openTelemetry-manifest_statefulset.yaml

#### Deploy the Dynatrace Operator
#### Deploy the Dynatrace Operator
echo "Deploying DT Operator"



kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/latest/download/kubernetes.yaml
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/latest/download/kubernetes-csi.yaml
kubectl -n dynatrace wait pod --for=condition=ready --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook --timeout=300s

kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DTOPERATORTOKEN" --from-literal="dataIngestToken=$DTTOKEN"
sed -i '' "s,TENANTURL_TOREPLACE,$DTURL," dynatrace/dynakube.yaml
sed -i '' "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME,"  dynatrace/dynakube.yaml
sed -i '' "s,TENANTURL_TOREPLACE,$DTURL," keptn/metricProvider.yaml

kubectl apply -f dynatrace/dynakube.yaml -n dynatrace

# Deploy collector
echo "Deploying collector instances"

kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=dt_api_token="$DTTOKEN" --from-literal="clustername=$CLUSTERNAME"
kubectl apply -f openTelemetry-demo/rbac.yaml
kubectl apply -f openTelemetry-demo/openTelemetry-manifest_ds.yaml
kubectl apply -f openTelemetry-demo/openTelemetry-manifest_statefulset.yaml

#deploy demo application$
echo "Deploying Demo app"

kubectl create ns hipster-shop
kubectl label namespace hipster-shop istio-injection=enabled
kubectl label namespace hipster-shop oneagent=true
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=dt_api_token="$DTTOKEN" -n hipster-shop
kubectl apply -f hipstershop/k8s-manifest.yaml -n hipster-shop



#Deploy the otel-demo
kubectl create ns otel-demo

kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=dt_api_token="$DTTOKEN" -n otel-demo
kubectl label namespace otel-demo istio-injection=enabled
kubectl label namespace otel-demo oneagent=false
kubectl apply -f openTelemetry-demo/deployment.yaml -n otel-demo


#Deploy the HPA and metricProvider
kubectl apply -f keptn/metricProvider.yaml -n hipster-shop
kubectl apply -f keptn/metricProvider.yaml -n otel-demo
kubectl apply -f keptn/keptnmetric_oteldemo.yaml -n otel-demo
kubectl apply -f keptn/keptnmetric.yaml -n hipster-shop
kubectl apply -f keptn/hpa.yaml -n hipster-shop
kubectl apply -f keptn/hpa_oteldemo.yaml -n otel-demo

#Launch loadtests
kubectl apply -f openTelemetry-demo/loadtest_job.yaml -n otel-demo
kubectl apply -f hipstershop/loadtest_job.yaml -n hipster-shop
