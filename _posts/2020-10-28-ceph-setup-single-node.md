---
title: Setup ceph test environment on single node with F31 
category: operation
tags: [ceph, test, dev-tips]
---

Setup ceph test environment on single node with F31

# **Prepare environment**

1 create VM from Fedora 31 cloud image

2 enable root login by editing /etc/sshd_config:

	PermitRootLogin yes

then restart sshd service:
  
	#systemctl restart sshd.service 

3 disable firewall

	systemctl stop firewalld
	systemctl disable firewalld
	iptables -F

4 disable selinux

	#vi /etc/sysconfig/selinux
	...
	SELINUX=disabled
	...

5 reboot VM

# **Install ceph packages**

	#install ceph
	yum install -y ceph-common ceph-mon ceph-mgr ceph-mds ceph-osd ceph-radosgw rbd-nbd
	
	#install ceph-deploy via pip because F31 doesn't ship this package
	pip3 install ceph-deploy

# **Setup ceph**

	ND=$1	#hostname
	DISK=$2 #disk used for OSD
	
	#setup dns for this host
	IP=`ifconfig | grep -w inet | head -n 1 | awk '{print $2}'`
	echo "$IP $ND" > /etc/hosts
	
	#setup node
	hostnamectl set-hostname  $ND
	ceph-deploy new $ND
	echo "osd crush chooseleaf type = 0" >> ceph.conf
	echo "osd pool default size = 1" >> ceph.conf
	echo "osd journal size = 100" >> ceph.conf
	ceph-deploy mon create-initial
	ceph-deploy admin  $ND
	ceph-deploy mgr create  $ND
	ceph-deploy osd create --data $DISK $ND
	
	#create one pool
	ceph osd pool create datastore 64 64

# **References**

[centos7.5 ceph单机版安装](http://blog.leanote.com/post/dhzbh@163.com/centos7.5-ceph%E5%8D%95%E6%9C%BA%E7%89%88%E5%AE%89%E8%A3%85)

[ceph-deploy fix on Fedora 33](https://bugs.launchpad.net/ubuntu/+source/ceph-deploy/+bug/1864993)
