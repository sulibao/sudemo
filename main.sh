#!/bin/bash
cat /root/k8s/host-config >> /etc/hosts && tail -4 /etc/hosts
echo

systemctl disable firewalld && systemctl status firewalld | grep Active
echo

sed -i '/^SELINUX=/ c SELINUX=disabled' /etc/selinux/config 
yum install -y wget tree bash-completion lrzsz psmisc net-tools vim chrony ipset ipvsadm
swapoff -a && sed -i 's/.*swap.*/#&/' /etc/fstab && free -m
echo

cat /root/k8s/sysctl > /etc/sysctl.conf && modprobe br_netfilter &&  modprobe overlay && sysctl -p
echo

cat /root/k8s/ipvs > /etc/sysconfig/modules/ipvs.modules && chmod +x /etc/sysconfig/modules/ipvs.modules && /bin/bash /etc/sysconfig/modules/ipvs.modules && lsmod | grep -e ip_vs -e nf_conntrack_ipv4 
echo

cat /root/k8s/k8s-image > /etc/yum.repos.d/kubernetes.repo && yum install -y kubeadm kubelet kubectl && kubeadm version
echo

echo KUBELET_EXTRA_ARGS="--cgroup-driver=systemd" \
     KUBE_PROXY_MODE="ipvs" && systemctl start kubelet && systemctl enable kubelet
echo

yum install -y yum-utils device-mapper-persistent-data lvm2 && yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo && sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+' /etc/yum.repos.d/docker-ce.repo
yum install -y containerd && containerd config default | tee /etc/containerd/config.toml && sed -i "s#SystemdCgroup\ \=\ false#SystemdCgroup\ \=\ true#g" /etc/containerd/config.toml && sed -i "s#registry.k8s.io#registry.aliyuncs.com/google_containers#g" /etc/containerd/config.toml && crictl --version
echo

cat /root/k8s/crictl > /etc/crictl.yaml && systemctl daemon-reload && systemctl start containerd && systemctl enable containerd && crictl pull nginx && crictl images
echo

kubeadm config print init-defaults > /root/k8s/kubeadm.yml
sed -i 's/advertiseAddress:.*/advertiseAddress: 192.168.2.130/g' /root/k8s/kubeadm.yml
sed -i 's/name:.*/name: main/g' /root/k8s/kubeadm.yml 
sed -i 's/imageRepository:.*/imageRepository: registry.aliyuncs.com\/google_containers/g' /root/k8s/kubeadm.yml 
sed -i 's/kubernetesVersion:.*/kubernetesVersion: 1.28.2/g' /root/k8s/kubeadm.yml
systemctl restart containerd

kubeadm config images pull --config /root/k8s/kubeadm.yml
crictl images
echo

kubeadm init --config=/root/k8s/kubeadm.yml --upload-certs --v=6  && export KUBECONFIG=/etc/kubernetes/admin.conf

