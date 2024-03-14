# sudemo
Ansible+Shell部署K8s，以下各部分脚本和剧本分开书写（便于理解），如有需要可以自行修改合并执行

# 一.可联网正常使用的虚拟机四台

| hostname                             | IP            |
| ------------------------------------ | ------------- |
| main(作为ansible和k8s主要操作的主机) | 192.168.2.130 |
| servera                              | 192.168.2.131 |
| serverb                              | 192.168.2.132 |
| serverc                              | 192.168.2.133 |

```
[root@main ~]# tail -4 /etc/hosts
192.168.2.130 main
192.168.2.131 servera
192.168.2.132 serverb
192.168.2.133 serverc
```

# 二.main主机部署ansible实现统一管理

## 1.下载ansible

```
[root@main ~]# yum install -y epel-release
[root@main ~]# ansible --version
ansible 2.9.27
  config file = /root/ansible.cfg
  configured module search path = [u'/root/.ansible/plugins/modules', u'/usr/share/ansible/plugins/modules']
  ansible python module location = /usr/lib/python2.7/site-packages/ansible
  executable location = /usr/bin/ansible
  python version = 2.7.5 (default, Nov 14 2023, 16:14:06) [GCC 4.8.5 20150623 (Red Hat 4.8.5-44)]
```

## 2.主机清单和配置文件

```
[root@main ~]# cat myhosts
[node]
servera
serverb
serverc
[root@main ~]# cat ansible.cfg 
[defaults]
inventory=/root/myhosts
remote_user=root
become_user=True
host_key_checking=False
ask_pass=False
gathering=smart
[privilege_escalation]
become=True
become_method=sudo
become_user=root
become_ask_pass=False
```

## 3.下发密钥进行管理

```
[root@main ~]# cat node-key.sh 
#!/bin/bash
hosts=("192.168.2.131" "192.168.2.132" "192.168.2.133")
for host in "${hosts[@]}"
do 
  ssh-copy-id root@$host
done

[root@main k8s]# ansible all -m ping
serverb | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python"
    }, 
    "changed": false, 
    "ping": "pong"
}
serverc | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python"
    }, 
    "changed": false, 
    "ping": "pong"
}
servera | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python"
    }, 
    "changed": false, 
    "ping": "pong"
}
```

# 三.node部署k8s基础准备

## 1.完善hosts文件，关闭firewalld，disabled掉selinux

```
#文件如下
[root@main k8s]# cat host-firewall-selinux.yaml 
---
- name: hosts-config          #拷贝文件到受管节点并追加（main节点的可以自己配）
  hosts: node
  tasks:
    - name: copy hostfile
      copy:
        src: /root/k8s/host-config
        dest: /root
    - name: add hostfile
      shell: cat /root/host-config >> /etc/hosts
 
- name: stop firewalld    #关防火墙
  hosts: node
  tasks:
    - name: stop it
      service:
        name: firewalld
        state: stopped

- name: change selinux   #disabled掉selinux并重启
  hosts: node
  tasks:
    - name: change it
      lineinfile:
        path: /etc/selinux/config
        regexp: '^SELINUX='
        line: SELINUX=disabled
    - name: restart hosts
      reboot: 


[root@main k8s]# ansible-playbook host-firewall-selinux.yaml 

PLAY [hosts-config] **************************************************************************************************************

TASK [Gathering Facts] ***********************************************************************************************************
ok: [serverb]
ok: [serverc]
ok: [servera]

TASK [copy hostfile] *************************************************************************************************************
ok: [serverb]
ok: [serverc]
ok: [servera]

TASK [add hostfile] **************************************************************************************************************
changed: [serverb]
changed: [serverc]
changed: [servera]

PLAY [stop firewalld] ************************************************************************************************************

TASK [stop it] *******************************************************************************************************************
ok: [servera]
ok: [serverc]
ok: [serverb]

PLAY [change selinux] ************************************************************************************************************

TASK [change it] *****************************************************************************************************************
ok: [servera]
ok: [serverb]
ok: [serverc]

TASK [restart hosts] *************************************************************************************************************
changed: [serverb]
changed: [serverc]
changed: [servera]

PLAY RECAP ***********************************************************************************************************************
servera                    : ok=6    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
serverb                    : ok=6    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
serverc                    : ok=6    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
```

## 2.时间同步、禁用交换分区、配置内核和ipvs

```
[root@main k8s]# cat sysctl    #内核文件
vm.swappiness=0
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
[root@main k8s]# cat ipvs   #ipvs文件
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack


[root@main k8s]# cat basic.yaml    #剧本文件
---
- name: install soft
  hosts: node
  vars:
    package:
      - wget
      - tree
      - bash-completion
      - lrzsz
      - psmisc
      - net-tools
      - vim
      - chrony
      - ipset
      - ipvsadm
  tasks:
    - yum:
        name: "{{ package }}"
        state: latest

- name: config chronyd
  hosts: node
  tasks:
    - service:
        name: chronyd
        state: started
    - shell: sed -i -e '/^server/s/^/# /' -e '$ a\server ntp1.aliyun.com iburst' /etc/chrony.conf
    - service:
        name: chronyd
        state: restarted
    - shell: chronyc sources

- name: swapoff
  hosts: node
  tasks:
    - shell: swapoff -a && sed -i 's/.*swap.*/#&/' /etc/fstab

- name: sysctl
  hosts: node
  tasks:
    - copy:
        src: /root/k8s/sysctl
        dest: /root
    - shell: cat /root/sysctl > /etc/sysctl.conf && modprobe br_netfilter &&  modprobe overlay && sysctl -p

- name: ipvs
  hosts: node
  tasks:
    - copy:
        src: /root/k8s/ipvs
        dest: /root
    - shell: cat /root/ipvs > /etc/sysconfig/modules/ipvs.modules && chmod +x /etc/sysconfig/modules/ipvs.modules && /bin/bash /etc/sysconfig/modules/ipvs.modules
```

# 四.部署k8s

## 1.此处用到的文件

```
[root@main k8s]# cat k8s-image 
[kubernetes]
name=Kubernetes
baseurl=http://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=http://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
http://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg

[root@main k8s]# cat crictl 
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
```

## 2.具体剧本文件

```
[root@main k8s]# cat nodeconfig.yaml 
---
- name: install k8s
  hosts: node
  vars:
    package:
      - kubeadm
      - kubelet
      - kubectl
  tasks:
    - copy:
        src: /root/k8s/k8s-image
        dest: /etc/yum.repos.d/kubernetes.repo
    - yum: 
        name: "{{ package }}"
        state: latest
    - shell: echo  'KUBELET_EXTRA_ARGS="--cgroup-driver=systemd" \
                    KUBE_PROXY_MODE="ipvs"' /etc/sysconfig/kubelet
    - service:
        name: kubelet
        state: started

- name: install containerd
  hosts: node
  vars:
    package:
      - yum-utils
      - device-mapper-persistent-data
      - lvm2
  tasks:
    - yum:
        name: "{{ package }}"
        state: latest
    - shell: yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    - shell: sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+' /etc/yum.repos.d/docker-ce.repo
    - yum:
        name: containerd
        state: latest
    - shell: containerd config default | tee /etc/containerd/config.toml
    - shell: sed -i "s#SystemdCgroup\ \=\ false#SystemdCgroup\ \=\ true#g" /etc/containerd/config.toml
    - shell: sed -i "s#registry.k8s.io#registry.aliyuncs.com/google_containers#g" /etc/containerd/config.toml

- name: pull image
  hosts: node
  tasks:
    - copy:
        src: /root/k8s/crictl
        dest: /root
    - shell: cat /root/crictl > /etc/crictl.yaml
    - shell: systemctl daemon-reload
    - service:
        name: containerd
        state: started
```

# 五.main主机环境配置和集群初始化（放到后面做）

使用无脑简单shell脚本完成，篇幅长，建议下载下来仔细修改你所需要的内容

## 1.此处用到如下文件

```
[root@main k8s]# cat host-config 
192.168.2.130 main
192.168.2.131 servera
192.168.2.132 serverb
192.168.2.133 serverc

[root@main k8s]# cat sysctl 
vm.swappiness=0
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1

[root@main k8s]# cat ipvs 
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack

[root@main k8s]# cat k8s-image 
[kubernetes]
name=Kubernetes
baseurl=http://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=http://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
http://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg

[root@main k8s]# cat crictl 
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
```

## 2.脚本文件

```
[root@main k8s]# cat main.sh 
#!/bin/bash
cat /root/k8s/host-config >> /etc/hosts && tail -4 /etc/hosts
echo  #hosts配置

systemctl disable firewalld && systemctl status firewalld | grep Active
echo   #防火墙

sed -i '/^SELINUX=/ c SELINUX=disabled' /etc/selinux/config 
yum install -y wget tree bash-completion lrzsz psmisc net-tools vim chrony ipset ipvsadm
swapoff -a && sed -i 's/.*swap.*/#&/' /etc/fstab && free -m
echo    #selinux、交换分区以及软件下载

cat /root/k8s/sysctl > /etc/sysctl.conf && modprobe br_netfilter &&  modprobe overlay && sysctl -p
echo   #内核

cat /root/k8s/ipvs > /etc/sysconfig/modules/ipvs.modules && chmod +x /etc/sysconfig/modules/ipvs.modules && /bin/bash /etc/sysconfig/modules/ipvs.modules && lsmod | grep -e ip_vs -e nf_conntrack_ipv4 
echo   #ipvs转发

cat /root/k8s/k8s-image > /etc/yum.repos.d/kubernetes.repo && yum install -y kubeadm kubelet kubectl && kubeadm version
echo   #下载k8s所需包

echo KUBELET_EXTRA_ARGS="--cgroup-driver=systemd" \
     KUBE_PROXY_MODE="ipvs" && systemctl start kubelet && systemctl enable kubelet
echo   #修改组

yum install -y yum-utils device-mapper-persistent-data lvm2 && yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo && sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+' /etc/yum.repos.d/docker-ce.repo
yum install -y containerd && containerd config default | tee /etc/containerd/config.toml && sed -i "s#SystemdCgroup\ \=\ false#SystemdCgroup\ \=\ true#g" /etc/containerd/config.toml && sed -i "s#registry.k8s.io#registry.aliyuncs.com/google_containers#g" /etc/containerd/config.toml && crictl --version
echo    #下载containerd

cat /root/k8s/crictl > /etc/crictl.yaml && systemctl daemon-reload && systemctl start containerd && systemctl enable containerd && crictl pull nginx && crictl images
echo

kubeadm config print init-defaults > /root/k8s/kubeadm.yml    #此处要仔细修改为你的环境
sed -i 's/advertiseAddress:.*/advertiseAddress: 192.168.2.130/g' /root/k8s/kubeadm.yml
sed -i 's/name:.*/name: main/g' /root/k8s/kubeadm.yml 
sed -i 's/imageRepository:.*/imageRepository: registry.aliyuncs.com\/google_containers/g' /root/k8s/kubeadm.yml 
sed -i 's/kubernetesVersion:.*/kubernetesVersion: 1.28.2/g' /root/k8s/kubeadm.yml
systemctl restart containerd

kubeadm config images pull --config /root/k8s/kubeadm.yml
crictl images
echo

kubeadm init --config=/root/k8s/kubeadm.yml --upload-certs --v=6 && export KUBECONFIG=/etc/kubernetes/admin.conf    #export此处为root用户时的做法，普通用户时需要修改为如下
  
  “mkdir -p $HOME/.kube
   sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config“
```

## 3.ansible命令行控制node加入集群

```
......     #执行完脚本后的页面
kubeadm join 192.168.2.130:6443 --token abcdef.0123456789abcdef \
	--discovery-token-ca-cert-hash sha256:4100be7411051d31e4a953d2450ad2a7b6802df204373f539ca4602d35cb38b8              
[root@main k8s]# ansible node -m shell -a "kubeadm join 192.168.2.130:6443 --token abcdef.0123456789abcdef \
> --discovery-token-ca-cert-hash sha256:4100be7411051d31e4a953d2450ad2a7b6802df204373f539ca4602d35cb38b8"
[root@main k8s]# kubectl get nodes
NAME      STATUS     ROLES           AGE   VERSION
main      NotReady   control-plane   71s   v1.28.2
servera   NotReady   <none>          22s   v1.28.2
serverb   NotReady   <none>          22s   v1.28.2
serverc   NotReady   <none>          22s   v1.28.2
```

# 六.部署calico网络插件

```
[root@main k8s]# cat calico.sh 
#!/bin/bash
yum install -y bash-completion
source /usr/share/bash-completion/bash_completion && source <(kubectl completion bash) && echo "source <(kubectl completion bash)" >> ~/.bashrc

wget --no-check-certificate https://projectcalico.docs.tigera.io/archive/v3.25/manifests/calico.yaml

sed -i '/value: "k8s,bgp"/a \            - name: IP_AUTODETECTION_METHOD\n              value: "interface=ens33"' calico.yaml

kubectl apply -f calico.yaml

[root@main k8s]# kubectl get pods -A
NAMESPACE     NAME                                       READY   STATUS    RESTARTS   AGE
kube-system   calico-kube-controllers-658d97c59c-b6rwh   1/1     Running   0          9m31s
kube-system   calico-node-czlml                          1/1     Running   0          9m31s
kube-system   calico-node-jh7bn                          1/1     Running   0          9m31s
kube-system   calico-node-kq966                          1/1     Running   0          9m31s
kube-system   calico-node-twjct                          1/1     Running   0          9m31s
kube-system   coredns-66f779496c-27vss                   1/1     Running   0          78m
kube-system   coredns-66f779496c-fn7fc                   1/1     Running   0          78m
kube-system   etcd-main                                  1/1     Running   2          78m
kube-system   kube-apiserver-main                        1/1     Running   2          78m
kube-system   kube-controller-manager-main               1/1     Running   2          78m
kube-system   kube-proxy-lfg2b                           1/1     Running   0          77m
kube-system   kube-proxy-rzmgs                           1/1     Running   0          77m
kube-system   kube-proxy-s2nzk                           1/1     Running   0          78m
kube-system   kube-proxy-tp5dn                           1/1     Running   0          77m
kube-system   kube-scheduler-main                        1/1     Running   2          78m
```

