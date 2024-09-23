---
title: How to add/remove qemu device from script
category: operation
tags: [qemu, virt, test, dev-tips]
---

One example to add/remove scsi-hd for testing scsi LUN hotplug

# append the following to qemu command line
		-device scsi-hd,id=scsi-hd0,drive=scsi-hd0-dr0 \
		-drive file=$FILE,if=none,id=scsi-hd0-dr0,format=qcow2,cache=none \
		-mon chardev=monitor,mode=readline \
		-chardev socket,path=monitor,id=monitor,server,nowait,signal=off

# test script for adding/removing scsi-hd
	CNT=254
	LOOP=8
	for((j=1;j<=$LOOP;j++));do
		#add scsi-hd
		for((i=1;i<=$CNT;i++));do
			echo "drive_add 0 file=stg$i.qcow2,if=none,id=drive$i,format=qcow2,cache=none" | nc -U monitor
			echo "device_add scsi-hd,id=scsi-hd$i,drive=drive$i" | nc -U monitor
		done

		#remove scsi-hd
		for((i=1;i<=$CNT;i++));do
			echo "device_del scsi-hd$i" |nc -U monitor
		done
	sleep 1
	done
