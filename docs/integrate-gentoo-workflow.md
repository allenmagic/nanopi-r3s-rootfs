# 将 Gentoo 流程整合到 build-rootfs.yml 的改动清单

## 现状

- `build-rootfs.yml`：通过 matrix 策略统一构建 void/devuan/debian/alpine
- `build-gentoo-rootfs.yml`：独立的 Gentoo 构建流程
- 两者结构高度一致，仅 3 处差异

## 改动内容

### 改动 1：distro 选项加入 gentoo

**文件**：`.github/workflows/build-rootfs.yml`

**位置 1（第 4 行，已应用）**：

```yaml
# 修改前
ALL_DISTROS: '["void","devuan","debian","alpine"]'

# 修改后
ALL_DISTROS: '["void","devuan","debian","alpine","gentoo"]'
```

**位置 2（第 15 行，待修改）**：

```yaml
# 修改前
options: [all, void, devuan, debian, alpine]

# 修改后
options: [all, void, devuan, debian, alpine, gentoo]
```

### 改动 2：依赖安装统一加上 gnupg

**文件**：`.github/workflows/build-rootfs.yml`  
**位置**：第 74–81 行（Install host build dependencies 步骤）

```yaml
# 修改前
sudo apt-get install -y --no-install-recommends \
  xz-utils zstd file binutils \
  curl ca-certificates wget \
  mmdebstrap debootstrap debian-archive-keyring \
  gpgv

# 修改后
sudo apt-get install -y --no-install-recommends \
  xz-utils zstd file binutils \
  curl ca-certificates wget \
  mmdebstrap debootstrap debian-archive-keyring \
  gpgv gnupg
```

> `gnupg` 提供 `gpg` 命令，Gentoo build.sh 用它验证 stage3 tarball 签名。与已有的 `gpgv` 不冲突，`gnupg` 是标准系统包，对其他 distro 无副作用。

## 不需要改动的地方（已自动兼容）

### Matrix / prepare 逻辑

`prepare` job 自动将 `ALL_DISTROS` 展开为 `distro × infra` 矩阵，加入 `gentoo` 后即自动生成 `gentoo × sing-box` / `gentoo × landscape` 组合。

`fail-fast: false` 已确保 Gentoo 构建超时或失败不影响其他 distro 的构建和 release。

### 构建步骤

```bash
chmod +x "distros/${DISTRO}/build.sh" || true
sudo -E bash -x "distros/${DISTRO}/build.sh"
```

`${DISTRO}` 解析为 `gentoo` 时等价于原 Gentoo workflow 的 `distros/gentoo/build.sh`。`|| true` 兼容可能缺少 build.sh 的 distro（如 alpine 早期）。

### 产物定位

```bash
f="$(ls -1 build/${DISTRO}/${DISTRO}-rootfs-minimal.tar.xz ...)"
# ${DISTRO}=gentoo → build/gentoo/gentoo-rootfs-minimal.tar.xz ✓
```

Gentoo build.sh 产物路径 `build/gentoo/gentoo-rootfs-minimal.tar.xz` 完全匹配现有 glob 模式。

### PACK 变量

`build-rootfs.yml` 硬编码 `PACK: "1"`，等价于原 Gentoo workflow 的 `pack: true`（默认值）。Gentoo build.sh 中 `PACK="${PACK:-0}"` 会读取该值并打包。

### Tag / Release

复用现有 `nanopi-r3s-rootfs-YYYYmmdd` 格式。Gentoo 产物会和其他 distro 产物一起出现在同一个 release 中，artifact 文件名自带 `gentoo-` 前缀可区分。

## 后续清理（暂不执行）

确认构建成功后，删除 `.github/workflows/build-gentoo-rootfs.yml`。
