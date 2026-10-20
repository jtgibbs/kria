// SPDX-License-Identifier: GPL-2.0
/*
 * physbuf: one physically contiguous DMA buffer for PL masters.
 *
 * At load time, allocates size_mb MiB from CMA with dma_alloc_coherent()
 * (mapped uncached on the CPU side, since the HP ports are not cache
 * coherent) and exposes it as /dev/physbuf:
 *   mmap(/dev/physbuf)                    CPU access to the buffer
 *   /sys/class/misc/physbuf/phys_addr     bus address to hand to the PL
 *   /sys/class/misc/physbuf/size          buffer size in bytes
 *
 *   sudo insmod physbuf.ko size_mb=64
 */
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/platform_device.h>

static unsigned int size_mb = 64;
module_param(size_mb, uint, 0444);
MODULE_PARM_DESC(size_mb, "buffer size in MiB");

static struct platform_device *pb_pdev;
static void *pb_vaddr;
static dma_addr_t pb_dma;
static size_t pb_size;

static int physbuf_mmap(struct file *file, struct vm_area_struct *vma)
{
	size_t len = vma->vm_end - vma->vm_start;

	if (vma->vm_pgoff || len > pb_size)
		return -EINVAL;
	return dma_mmap_coherent(&pb_pdev->dev, vma, pb_vaddr, pb_dma, len);
}

static const struct file_operations physbuf_fops = {
	.owner = THIS_MODULE,
	.mmap  = physbuf_mmap,
};

static ssize_t phys_addr_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "0x%llx\n", (unsigned long long)pb_dma);
}
static DEVICE_ATTR_RO(phys_addr);

static ssize_t size_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%zu\n", pb_size);
}
static DEVICE_ATTR_RO(size);

static struct attribute *physbuf_attrs[] = {
	&dev_attr_phys_addr.attr,
	&dev_attr_size.attr,
	NULL,
};
ATTRIBUTE_GROUPS(physbuf);

static struct miscdevice physbuf_misc = {
	.minor  = MISC_DYNAMIC_MINOR,
	.name   = "physbuf",
	.fops   = &physbuf_fops,
	.groups = physbuf_groups,
	.mode   = 0600,
};

static int __init physbuf_init(void)
{
	int ret;

	pb_size = (size_t)size_mb << 20;
	pb_pdev = platform_device_register_simple("physbuf", -1, NULL, 0);
	if (IS_ERR(pb_pdev))
		return PTR_ERR(pb_pdev);

	// A 31-bit mask is narrower than arm64's DMA zone and gets rejected, so
	// ask for 32 bits and check the 2 GiB limit (DDR low) after allocating.
	ret = dma_set_mask_and_coherent(&pb_pdev->dev, DMA_BIT_MASK(32));
	if (ret) {
		pr_err("physbuf: dma_set_mask_and_coherent failed: %d\n", ret);
		goto err_pdev;
	}

	pb_vaddr = dma_alloc_coherent(&pb_pdev->dev, pb_size, &pb_dma, GFP_KERNEL);
	if (!pb_vaddr) {
		pr_err("physbuf: can't allocate %zu bytes\n", pb_size);
		ret = -ENOMEM;
		goto err_pdev;
	}
	// The PL reaches DDR low (below 2 GiB) through the HP port address map.
	if (pb_dma + pb_size > 0x80000000ULL) {
		pr_err("physbuf: buffer at 0x%llx is above DDR low\n", (unsigned long long)pb_dma);
		ret = -ENOMEM;
		goto err_free;
	}

	ret = misc_register(&physbuf_misc);
	if (ret) {
		pr_err("physbuf: misc_register failed: %d\n", ret);
		goto err_free;
	}

	dev_info(&pb_pdev->dev, "%zu bytes at 0x%llx\n", pb_size, (unsigned long long)pb_dma);
	return 0;

err_free:
	dma_free_coherent(&pb_pdev->dev, pb_size, pb_vaddr, pb_dma);
err_pdev:
	platform_device_unregister(pb_pdev);
	return ret;
}

static void __exit physbuf_exit(void)
{
	misc_deregister(&physbuf_misc);
	dma_free_coherent(&pb_pdev->dev, pb_size, pb_vaddr, pb_dma);
	platform_device_unregister(pb_pdev);
}

module_init(physbuf_init);
module_exit(physbuf_exit);
MODULE_DESCRIPTION("Physically contiguous DMA buffer for PL masters");
MODULE_LICENSE("GPL");
