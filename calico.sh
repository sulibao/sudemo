#!/bin/bash
yum install -y bash-completion
source /usr/share/bash-completion/bash_completion && source <(kubectl completion bash) && echo "source <(kubectl completion bash)" >> ~/.bashrc

wget --no-check-certificate https://projectcalico.docs.tigera.io/archive/v3.25/manifests/calico.yaml

sed -i '/value: "k8s,bgp"/a \            - name: IP_AUTODETECTION_METHOD\n              value: "interface=ens33"' calico.yaml

kubectl apply -f calico.yaml
