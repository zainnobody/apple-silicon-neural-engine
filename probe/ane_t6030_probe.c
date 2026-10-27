// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Apple T6030 (M3 Pro) Neural Engine: probe-only power test.
 *
 * Stage 2 of the ane-linux plan. On T6030 the ANE has one real PMGR
 * power state, ane_sys; the ADT sub-domains (ANE_MPM, ANE_TD, ANE_BASE,
 * ANE_CPU) are virtual. The platform core attaches ane_sys and powers it
 * on before probe. The driver then runs runtime PM on and off cycles
 * through genpd and leaves the domain off. It never writes an engine or
 * PMGR register and never starts firmware. With peek=1 it reads one
 * register, the ASC wrapper CPU_CONTROL word, while the domain is on.
 */

#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>

/*
 * Engine-relative ASC wrapper CPU_CONTROL, RUN is bit 4. Same offset as
 * on T602x, where the DART also sits at engine +0x1800000 as on T6030.
 * Not yet checked on H15, so peek is off by default.
 */
#define ANE_T6030_ASC_CPU_CONTROL	0x1400044
#define ANE_T6030_ASC_CPU_RUN		BIT(4)

#define ANE_T6030_MAX_CYCLES		10

static bool peek;
module_param(peek, bool, 0444);
MODULE_PARM_DESC(peek, "Read ASC CPU_CONTROL once per cycle while powered (default 0)");

static unsigned int cycles = 1;
module_param(cycles, uint, 0444);
MODULE_PARM_DESC(cycles, "Power on and off cycles at probe, 1 to 10 (default 1)");

static unsigned int hold_ms = 100;
module_param(hold_ms, uint, 0444);
MODULE_PARM_DESC(hold_ms, "Time the domain stays on per cycle, in ms (default 100)");

static int ane_t6030_cycle(struct device *dev, void __iomem *engine,
			   unsigned int n)
{
	u32 ctl;
	int ret;

	ret = pm_runtime_resume_and_get(dev);
	if (ret) {
		dev_err(dev, "cycle %u: power on failed: %d\n", n, ret);
		return ret;
	}
	dev_info(dev, "cycle %u: ane_sys on\n", n);

	if (engine) {
		ctl = readl(engine + ANE_T6030_ASC_CPU_CONTROL);
		dev_info(dev, "cycle %u: ASC CPU_CONTROL = %#010x (RUN=%d)\n",
			 n, ctl, !!(ctl & ANE_T6030_ASC_CPU_RUN));
	}

	msleep(hold_ms);

	/* genpd powers ane_sys off synchronously when the last user suspends. */
	ret = pm_runtime_put_sync_suspend(dev);
	if (ret < 0) {
		dev_err(dev, "cycle %u: power off failed: %d\n", n, ret);
		return ret;
	}
	dev_info(dev, "cycle %u: ane_sys released\n", n);
	return 0;
}

static int ane_t6030_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	void __iomem *engine = NULL;
	unsigned int i;
	int ret;

	if (cycles < 1 || cycles > ANE_T6030_MAX_CYCLES)
		return dev_err_probe(dev, -EINVAL, "cycles must be 1 to %d\n",
				     ANE_T6030_MAX_CYCLES);

	if (!dev->pm_domain)
		return dev_err_probe(dev, -ENODEV, "no power domain attached\n");

	ret = devm_pm_runtime_enable(dev);
	if (ret)
		return ret;

	if (peek) {
		/* The soc node has nonposted-mmio, so this maps non-posted. */
		engine = devm_platform_ioremap_resource_byname(pdev, "engine");
		if (IS_ERR(engine))
			return dev_err_probe(dev, PTR_ERR(engine),
					     "engine window map failed\n");
	}

	for (i = 1; i <= cycles; i++) {
		ret = ane_t6030_cycle(dev, engine, i);
		if (ret)
			return ret;
	}

	dev_info(dev, "probe done: %u cycle(s), peek=%d, no engine or PMGR writes\n",
		 cycles, peek);
	return 0;
}

static const struct of_device_id ane_t6030_of_match[] = {
	{ .compatible = "apple,t6030-ane" },
	{ }
};
MODULE_DEVICE_TABLE(of, ane_t6030_of_match);

static struct platform_driver ane_t6030_driver = {
	.driver = {
		.name = "ane_t6030_probe",
		.of_match_table = ane_t6030_of_match,
		.suppress_bind_attrs = true,
	},
	.probe = ane_t6030_probe,
};
module_platform_driver(ane_t6030_driver);

MODULE_LICENSE("Dual MIT/GPL");
MODULE_DESCRIPTION("Apple Neural Engine (T6030/M3 Pro) probe-only power test");
