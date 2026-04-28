# 恢复手册（Recovery Runbook）

如果新刷的内核砖了，按下面顺序操作。

## L0：检查现在哪里

```bash
adb devices         # 看到 device 状态？回 system 了
fastboot devices    # 看到？在 bootloader
# 都看不到？设备完全无响应或 USB 掉了
```

## L1：装系统但行为异常

如果 adb 还能连：
```bash
adb reboot bootloader   # 进 bootloader
```

然后跳到 L2。

## L2：在 fastboot 里——回 stock

最常见的恢复场景。一条命令：

```bash
cd /home/ltlly/Code/kernel_research
fastboot flash boot_a workspace/stock-images/boot_a-original.img
fastboot reboot
```

等 60 秒应该 boot 回 stock LineageOS。

## L3：用我们准备好的脚本

```bash
cd /home/ltlly/Code/kernel_research
./scripts/recover.sh --reason "我自己说为啥"
```

会自动：
1. 等设备进 fastboot（如果在 adb 模式会先 reboot bootloader）
2. flash stock boot_a
3. set-active=a
4. fastboot reboot

## L4：完全无响应（USB 都掉了）

**长按电源键 15-30 秒**强制断电重启。

设备会回 system（运行 stock OR 我们之前 flash 的某个版本）或者 bootloader。

之后回到 L1/L2/L3。

## L5：连长按都救不回来（极端情况）

EDL（Emergency Download）—— 物理短接主板测试点 + USB。

需要：
- MiFlash 工具
- 官方原厂线刷包
- 短接技术

**这种情况这次工程没遇到过**——所有 brick 都靠长按 + L2 恢复。

---

## Stock 镜像验证

```bash
cd /home/ltlly/Code/kernel_research/workspace/stock-images
sha256sum -c SHA256SUMS
```

应该全部 OK。如果有一行 FAILED 说明备份坏了，**马上停下** —— 这是终极保险，不能丢。

## 当前 boot 状态查询

随时可以从 host 查询设备 boot 状态：

```bash
# 设备在 system
adb shell 'cat /proc/version | head -1'
# 输出包含 "(claude@research)" → 我们的 research kernel
# 输出包含 "(root@edf80b8d88c5)" → stock kernel

# 设备在 fastboot
fastboot getvar all 2>&1 | grep -iE "current-slot|secure|unlocked"
```

## 当前 vbmeta 状态

```bash
# stock vbmeta_a/b 应该都在 disable-verification 模式（我们 flash 过）
# 如果某次刷错复原成原始，可以再 flash:
fastboot --disable-verification flash vbmeta_a workspace/stock-images/vbmeta_a-original.img
fastboot --disable-verification flash vbmeta_b workspace/stock-images/vbmeta_b-original.img
```

---

## 关键约束（不要破坏）

1. **永远不要 set-active=b** — alioth 是 Virtual A/B，slot _b 不能独立启动
2. **永远保留 `workspace/stock-images/boot_a-original.img`** — chmod -w 已设置，但还是别动
3. **避免 fastboot boot 大于 ~50MB 的 boot.img** — alioth bootloader 会静默 fall back，不报错但不真正 RAM 启动
4. **bootloader 锁定状态不要碰** — 当前 unlocked + secure。再 lock 就回不来了
